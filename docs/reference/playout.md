# AutoDJ playout

The `playout` service (issue #63, Compose profile `autodj`) plays each AutoDJ
station's playlist when no DJ is live. It publishes to the station's hidden
`/stations/{id}/autodj.{fmt}` mounts; Icecast moves listeners there when the
live source drops and back when it returns ([fallback mounts](icecast.md#station-limits), #62).

```text
control plane (tc-dashboard#107) --GET /playout--> supervisor --one process per station--> liquidsoap
object storage (presigned URLs) --tracks--> cache                                            |
                                                         icecast:8000/stations/{id}/autodj.{fmt} <--+
```

## Handoff

Measured by `tests/autodj.sh` through Caddy (#64): one listener connection
per format, a DJ who drops, comes back and drops again.

| | MP3 128 kbps | Opus 64 kbps |
|---|---|---|
| Live to AutoDJ: longest time without new bytes | 0.2 s | 0.5 s |
| AutoDJ to live: longest time without new bytes | 0.2 s | 2.8 s |
| Listener reconnects | none | none |

- The stall is measured from the moment the DJ's source stops (or its client
  starts again), on the wire, so a player with a few seconds of buffer plays
  on without a gap. Back to live includes the DJ's own connect time (TLS,
  source auth, and for Ogg the encoder's first pages), which is why Opus is
  slower there; the move itself is immediate.
- Ogg Opus: each switch starts a new chained Ogg stream on the same
  connection (new serial number and headers). ffmpeg decodes it in the
  test; browser players are not covered by it.

### When live and AutoDJ formats differ

Icecast does not re-encode: on a switch the listener gets the other source's
frames as they are. With a live MP3 source at 64 kbps / 48 kHz and AutoDJ at
128 kbps / 44.1 kHz, one connection carried both kinds of frames and ffmpeg
decoded it with a few errors at the switches. A bitrate change alone is
harmless for MP3 players (it looks like VBR); a sample-rate change mid-stream
is not: some players resample wrongly, glitch or stop. So the control plane
must send AutoDJ `outputs` that match the station's live profile, codec,
sample rate and channels at least (tc-dashboard#106 pins the profile). Ogg
Opus is always 48 kHz and each chained stream carries its own headers, so
only the bitrate and channels can differ there; keep them equal too.

## Image

`playout/Dockerfile`: `savonet/liquidsoap:v2.4.6`, pinned by digest, plus
Python 3 for the supervisor (`playout/supervisor.py`, standard library only).
It runs as the image's `liquidsoap` user with a read-only root filesystem, no
capabilities, a tmpfs for state (`/run/playout`) and a volume for the track
cache (`/var/cache/playout`). It is capped at 1.5 CPUs and 2 GB
(`PLAYOUT_CPUS`, `PLAYOUT_MEMORY`) and 1,024 processes and threads, and has
half the CPU weight of the other containers (`cpu_shares: 512`, cgroup v2
`cpu.weight` 59 against 100), so on a busy node Icecast and Caddy get the CPU
first; about 8 stations fit per node
([load test](../load-test.md#autodj-playout)).
Outputs use FFmpeg's libmp3lame and libopus (`%ffmpeg`), half the CPU of
Liquidsoap's native encoders. It has no published port: it only connects out,
to Icecast on the internal Docker network and to the control plane.

## Supervisor

- Polls `PLAYOUT_URL` every `PLAYOUT_POLL_SECONDS` (30) with `If-None-Match`;
  an unchanged state (`304`) costs nothing.
- Downloads each track once into the cache, named by its sha256. A track
  whose size is above `PLAYOUT_MAX_TRACK_MB` (200), whose sha256 does not
  match, or whose content is not MP3, Ogg, FLAC, WAV or M4A is skipped and
  logged. The type comes from the file's content, never from the URL.
  Tracks no station uses any more are deleted.
- Runs one Liquidsoap process per station, so stations never affect each
  other:

  | Change | Effect |
  |---|---|
  | Tracks or their order | The station's `m3u` is rewritten; Liquidsoap reloads it. No restart, listeners stay. |
  | Outputs, `shuffle` or the password | That station restarts: its AutoDJ listeners reconnect. |
  | Station added | Its process starts. Others untouched. |
  | Station removed, or none of its tracks is playable | Its process stops. Others untouched. |
  | Endpoint unreachable, `401`, `5xx` or invalid answer | Logged once; every station keeps playing what it has. |
  | Liquidsoap exits | Restarted after 5, 10, 30, then 60 s. |

- A station without any playable track is not started: its live mount then
  has no fallback, rather than holding listeners on silence.
- Liquidsoap logs to stdout (`docker compose logs playout`), one line per
  supervisor event prefixed `[playout]`.
- Healthcheck: the supervisor loop wrote its heartbeat less than 2 minutes
  ago (or two poll intervals). It is written between track downloads too,
  so a long first sync does not fail the deploy's `--wait`.

## Playout endpoint contract

The control plane implements it (tc-dashboard#107).

**Request:** `GET {PLAYOUT_URL}` with HTTP Basic auth (`PLAYOUT_USER`,
`PLAYOUT_PASSWORD`), `Accept: application/json` and, after the first answer,
`If-None-Match: <ETag>`. Serve it on the private network only.

**Answer:** `200` with an `ETag`, `304` when unchanged, `401` for wrong node
credentials. Body at most 8 MiB:

```json
{
  "stations": {
    "42": {
      "password": "<the station's AutoDJ credential>",
      "shuffle": true,
      "outputs": [
        { "format": "mp3", "bitrate_kbps": 128, "sample_rate": 44100, "channels": 2 },
        { "format": "opus", "bitrate_kbps": 64, "sample_rate": 48000, "channels": 2 }
      ],
      "tracks": [
        {
          "id": "trk_8f2c",
          "sha256": "<lowercase hex of the file>",
          "url": "https://<bucket>/...?X-Amz-Signature=...",
          "title": "Title",
          "artist": "Artist"
        }
      ]
    }
  }
}
```

- `stations`: every station with AutoDJ enabled and assigned to this node.
  A station missing from the answer is stopped. Keys follow the station id
  rule of `stations.json` (`[A-Za-z0-9-]{1,64}`).
- `password`: the station's AutoDJ credential. The playout service sends it
  to Icecast with user = station id, on the AutoDJ mounts only; source auth
  checks it ([contract](../source-auth.md)).
- `outputs`: one per format the station publishes, matching its live profile
  (codec, bitrate, sample rate, channels) so the switch is seamless. `mp3`:
  32–320 kbps at 32000, 44100 or 48000 Hz. `opus`: 6–256 kbps at 48000 Hz.
  `channels`: 1 or 2. Each format needs the station's `"autodj": true` in
  `stations.json`, which renders the mounts.
- `tracks`: in playlist order (`shuffle` false) or shuffled per pass.
  `id`: `[A-Za-z0-9_-]{1,64}`. `url`: fetched with a plain `GET`, no
  credentials; give it a lifetime of at least a few minutes, because a large
  first sync downloads tracks one after another. A changed URL for the same
  sha256 does not download again. `title` and `artist` (optional) become the
  stream metadata; control characters are removed and each is cut to 256
  characters.
- The whole answer is rejected (and the running state kept) if any field is
  invalid; the log names the field, never a secret.

## Settings

| Variable | Default | |
|---|---|---|
| `PLAYOUT_URL` | none | Control plane endpoint, `http(s)://`, no credentials in it |
| `PLAYOUT_USER` | `playout` (deploy workflow) | Node user for the endpoint |
| `PLAYOUT_PASSWORD` | none | Node password for the endpoint (secret) |
| `PLAYOUT_POLL_SECONDS` | `30` | Poll interval |
| `PLAYOUT_MAX_TRACK_MB` | `200` | Largest track accepted |
| `PLAYOUT_ICECAST_HOST`, `PLAYOUT_ICECAST_PORT` | `icecast`, `8000` | Icecast on the internal network |
| `PLAYOUT_CPUS`, `PLAYOUT_MEMORY` | `1.5`, `2g` | Compose limits of the service (deploy variables) |

## Secrets

- `PLAYOUT_PASSWORD` and the station passwords live only in the supervisor's
  memory and each Liquidsoap process's environment. The generated scripts
  and playlists under `/run/playout` hold no secret.
- Presigned track URLs are never logged: failures name the track id.
- `tests/playout.sh` fails if a credential or track URL appears in the
  playout, stub or Icecast logs.

## Tests

`tests/playout.sh` runs Icecast, the auth stub, a stub playout endpoint
(`tests/playout_stub.py`, overlay `tests/playout.compose.yaml`) and the
playout image. It checks MP3, Opus and mono outputs reach a listener on an
idle live mount, a bad sha256 and a wrong credential are refused, adding and
removing stations and a new playlist leave a playing station alone, an
unreachable endpoint keeps stations playing, and no secret is logged.
