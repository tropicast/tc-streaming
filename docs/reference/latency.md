# Latency

How far behind the DJ's microphone a listener hears the station, and how long
a switch between live and AutoDJ takes to reach their ear. Target: under
1.5 s (#83). Measured by `tests/latency.sh` (#84) in CI, through Caddy, with
budgets that fail the job.

## Measured

`main` before #83, one node in Docker, listeners on loopback:

| Delay (s) | MP3 128 kbps | Opus 64 kbps | Budget |
|---|---|---|---|
| Listener start to first audio | 0.4 | 0.6 | 2 |
| Microphone to ear, at connect | 4.3 | 5.5 | 8 |
| Microphone to ear, steady | 4.3 | 5.5 | 8 |
| Microphone to listener, on the wire | 0.25 | 1.0 | - |
| Live to AutoDJ (DJ stops to AutoDJ heard) | 4.3 | 5.5 | 9 |
| AutoDJ to live (DJ starts to DJ heard) | 4.4 | 5.5–6.6 | 9 |
| Microphone to ear, after the DJ returns | 4.2 | 5.5–6.5 | 8 |
| AutoDJ warm-up (library published to first byte) | 27 | | 45 |

Budgets leave 1–3 s for slower CI runners. On Opus, a stall while the DJ
reconnects stays in the delay for the rest of the session: a player with no
buffer never catches up.

AutoDJ warm-up: 22.6 s from publishing a 30-track library to the
supervisor's `station 42: started` (mostly its 30 s poll), then 4.2 s to
the first byte on the mount.

What it shows:

- Both switches take as long as the steady delay. The handoff itself is
  immediate (`tests/autodj.sh`, [playout](playout.md#handoff)). The listener
  first plays out the backlog of the source they were on.
- That backlog is Icecast's burst (`<burst-size>` 64 KiB: 4 s at 128 kbps).
  A new listener gets it at once, then stays that far behind. Only 0.25 s
  (MP3) and 1 s (Opus) come from the encoder and the network.
- Opus's extra second on the wire is the Ogg muxer's default page of 1 s
  (the source uses the desktop app's encoder flags).
- In production, a player's own buffer adds to these numbers (2–5 s for a
  browser's `<audio>`). That gives the 7–8 s reported in #83.

## Method

- **Source.** `tests/latency_source.py` writes PCM in real time and logs the
  wall clock time of the first sample. Second *j* plays
  600 + 100 × (*j* mod 16) Hz. So each second of audio says when it left the
  microphone, within a 16 s cycle. FFmpeg encodes it with the desktop app's
  flags (tc-station `FfmpegExecutable.Arguments`). `tests/raw_source.py`
  publishes it through the ingest host. AutoDJ plays 440 Hz.
- **Listener.** `curl -N` through the listen host, piped to
  `tests/latency_listener.py`, which logs when each read arrived.
- **Player.** `tests/latency.py` splits the recording into MP3 frames or
  Ogg pages (lengths from the Opus packets' TOC bytes, not granule
  positions, which jump at a chained stream). Each frame plays once its last
  byte has arrived and the previous frame has finished. That is a player
  with no buffer of its own: the best any player can do with the bytes it
  gets.
- **Delays.** The decoded audio is labelled every 50 ms by frequency. Each
  change of second is matched to the time it left the microphone ("heard"
  delay) and to when its bytes arrived ("wire" delay). A switch is measured
  from the end (or start) of the DJ's session to the first AutoDJ (or live)
  audio heard.
- **Warm-up.** The playout service runs with its default poll (30 s). The
  test publishes a station with 30 tracks to the stub control plane, then
  waits for the first byte on the live mount, which is served by the AutoDJ
  fallback.

Run it with `tests/latency.sh` (about 90 s). `KEEP=1` keeps the Compose
project and the recordings. The `LATENCY_MAX_*` variables override the
budgets. Lower the defaults in the script when a sub-issue of #83 lands, and
update this table.

## Not covered

- Players' own buffers: the numbers are for a player with none. The public
  player is tc-dashboard#136.
- The desktop app's capture and its PCM queue (tc-station#74): the source
  starts at the encoder.
- Network jitter and a real uplink: everything runs on one host.
