# ADR 0001: Keep the Icecast fallback for live/AutoDJ switches

- Status: proposed
- Date: 2026-10-17
- Issue: #87 (spike, part of #83)

## Context

A station with AutoDJ has two sources: the DJ on `live.<fmt>` and the
playout service on the hidden `autodj.<fmt>` (#62, #63). Icecast moves
listeners between them with `fallback-mount` and `fallback-override`, with
no re-encode. Before #83, a switch took 4–7 s to reach the listener.

The alternative: one Liquidsoap process per AutoDJ station receives the DJ
on `input.harbor`, plays `fallback(track_sensitive=false, [live, autodj])`
with a short crossfade, and publishes one continuous stream to the public
mount.

#83 made this spike conditional: go only if the other sub-issues cannot get
under 1.5 s on their own.

## What the other sub-issues reached

`tests/latency.sh` ([Latency](../reference/latency.md)), local runs, with a
player that has no buffer of its own:

| Delay (s) | MP3 128 kbps | Opus 64 kbps |
|---|---|---|
| Microphone to ear, steady | 0.6–0.7 | 0.5–0.6 |
| Live to AutoDJ heard | 0.7–0.8 | 0.5–0.6 |
| AutoDJ to live heard | 0.6–0.8 | 0.6–1.7 |
| A DJ's dead connection to AutoDJ heard | 3.7–4.0 | 3.8–4.5 |

- **Why the switch was slow.** It was never the move itself. The listener
  first played out the old source's backlog: a 64 KiB burst they kept for
  the whole session. #85's 0.5 s burst fixed that.
- **What is left: Opus back to live.** The DJ's connect (TLS, source auth, a
  new chained Ogg stream) can leave the listener without audio for up to
  1 s.
- **Dead connections.** They take as long as `<source-timeout>` (3 s).
  Liquidsoap would need its own timeout for a silent harbor input.
- **The browser player.** tc-dashboard#136 keeps it within about 0.7 s of
  the stream.

## What Liquidsoap would change

- **Switch.** It would be seamless, with a crossfade. The same Ogg stream
  and the same MP3 frame format continue, so players see no chained stream
  and no format change mid-stream (`docs/reference/playout.md`, *When live
  and AutoDJ formats differ*). This is its real advantage.
- **Steady delay: likely higher, not lower.**
  - `input.harbor` buffers the DJ to ride out uplink jitter (`buffer`,
    default 12 s, `max`).
  - Liquidsoap adds its frame clock and a second encoder's delay.
  - Cutting the buffer to ~0.5 s moves the DJ's network jitter from the
    listener's player into Liquidsoap. There a late packet means silence
    or a fallback for every listener at once.
- **Quality.** The live show is decoded and encoded again: a second
  generation at 64 or 128 kbps. Today Icecast passes the DJ's stream
  through untouched.
- **CPU.**
  - The outputs already run for every AutoDJ station: 6–9 % of a core
    each ([load test](../load-test.md#autodj-playout)).
  - Decoding the live input adds about 3 % per station while it is live.
  - Stations without AutoDJ keep the direct Icecast path, so this is
    affordable.
- **Failure modes.**
  - A Liquidsoap crash or restart (deploy, out of memory, a bad track)
    would take a *live show* off air, not only AutoDJ.
  - Today a playout crash never touches a DJ.
- **Source auth (#7).**
  - Harbor's `auth` callback would have to call the control plane's
    `stream_auth` per connection, with the same plan checks (format, bitrate).
  - Caddy's layer4 ingest route would need to reach harbor ports for
    AutoDJ stations and Icecast for the others: two ingest paths to keep in
    step.

## Decision

**No-go for now.** Keep the Icecast fallback.

- Every switch is under 1.5 s on the wire except Opus back to live
  (0.6–1.7 s). The steady delay is about 0.6 s.
- The Liquidsoap path would likely raise the steady delay. It would put
  live shows behind a process that can fail, re-encode them, and need a
  second source-auth integration.

Revisit if one of these becomes a requirement:

- crossfades between AutoDJ and the DJ (a product feature, not latency);
- no chained Ogg streams, if a browser or player that matters breaks on them
  (the public player plays MP3 through MSE since tc-dashboard#136);
- Opus back to live consistently under 1 s. Try first the cheaper path:
  make the DJ's first pages reach Icecast sooner (the desktop app connects,
  then starts FFmpeg; tc-station#74).
