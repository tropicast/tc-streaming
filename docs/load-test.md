# Load and soak test of the MVP node

Issue #12. Node `tc-stream-1` (Hetzner CX33: 4 vCPU, 8 GB, `fsn1`), release
`9c1ae97`, tested in production on 2026-10-06 with the test station 42.

## Method

- **Load generator**: `tools/loadtest` (Go). One HTTP/1.1 connection per
  listener, like separate players, through the public Caddy gateway
  (`https://listen.tropicastradio.com`). Reports active listeners,
  throughput, drops, refusals and time to first byte.
- **Where**: `tc-runner-1`, same Hetzner location, so the network between
  them is not the bottleneck.
- **Sources**: two `ffmpeg` publishers for station 42 through the ingest
  gateway: MP3 128 kbps and Ogg Opus 64 kbps (stereo, 48 kHz), from pink
  noise so the encoders use a realistic bitrate.
- **Node metrics**: `tests/load/sample-node.sh` every 10 s (60 s in the
  soak): CPU, available memory, network out, and `docker stats` for Icecast
  and Caddy. Grafana Cloud recorded the same period.
- **Station cap** raised to 1,500 for the test with
  `deploy.sh apply-stations` (no restart), and restored afterwards.

## Ramp test: 1,400 listeners

700 Opus + 700 MP3 listeners, started evenly over 5 minutes, then held
for 10 minutes.

| Stream | Listeners | Drops | Refused | Errors | Time to first audio p50 / p95 |
|---|---|---|---|---|---|
| Opus 64 kbps | 700 | 0 | 0 | 0 | 527 ms / 999 ms |
| MP3 128 kbps | 700 | 0 | 0 | 0 | 335 ms / 383 ms |

Node during the 10-minute hold (44 samples):

| Measure | Average | Max |
|---|---|---|
| CPU busy (whole node) | 13.8% | 14.6% |
| Network out | 155.8 Mbit/s | 158.4 Mbit/s |
| Memory available | 6.6 GB of 7.7 GB | |
| Icecast CPU / memory | 10.8% / 14.5 MB, flat | 14.5% |
| Caddy CPU / memory | 38.6% / 316 → 351 MB | 49.8% |

Payload the listeners received during the hold: Opus 32.0 Mbit/s
(about **46 kbps per listener**: Opus VBR stays under its 64 kbps target),
MP3 89.6 Mbit/s (128 kbps per listener).

### Egress per listener-hour

| Stream | Audio payload | Billed egress at the node at 1,400 listeners (×1.28, see below) |
|---|---|---|
| Opus 64 kbps (VBR, ~46 kbps) | **20.9 MB** | **~27 MB** |
| MP3 128 kbps | **57.9 MB** | **~74 MB** |

The node sent 155.8 Mbit/s for 121.6 Mbit/s of audio payload: **28%
overhead** (TCP/IP headers, TLS records, HTTP chunking). A local test
through the same gateway measured 11.6%, so part of the gap is unexplained;
it is tracked as a follow-up. Plan with the node-level figure.

## Conclusions and limits

- **CPU and memory are not the limit.** At 1,400 listeners the node used
  under 15% CPU; Caddy (TLS) is the main consumer, Icecast stays at about
  11% and 15 MB.
- **The monthly quota is the limit.** 20 TB at the measured billed egress
  is about:
  - Opus: 20 TB / 27 MB ≈ **740,000 listener-hours** a month, an average of
    **~1,000 concurrent listeners** around the clock;
  - MP3 128 kbps: 20 TB / 74 MB ≈ 270,000 listener-hours, **~370
    concurrent** on average.
  Opus as the default listener format (#9) gives each node about 2.7×
  the audience for the same traffic.
- **Icecast limits stay as they are** (`<clients>` 1500, `<sources>` 50):
  1,400 listeners were tested with no drops, and peaks above that are
  untested. The network was tested up to 158 Mbit/s; the CX33's ceiling is
  not known.
- **Time to first audio** is about 0.35 s for MP3 and up to 1 s for Opus
  (Ogg pages are larger), both fine for radio.

## Soak test: 24 hours

150 Opus + 150 MP3 listeners from 2026-10-06 22:02 to 2026-10-07 22:04 UTC
(2 min ramp, 24 h hold), node sampled every 60 s (1,406 samples).
**Result: pass.**

| Stream | Listeners | Connects | Drops | Refused | Errors | Payload per listener-hour | Time to first audio p50 / p95 |
|---|---|---|---|---|---|---|---|
| Opus 64 kbps | 150 | 150 | 0 | 0 | 0 | 20.6 MB | 721 ms / 1.0 s |
| MP3 128 kbps | 150 | 150 | 0 | 0 | 0 | 57.6 MB | 328 ms / 374 ms |

Every listener kept its first connection for 24 hours: no drops and no
reconnects. Throughput was flat across all 287 reports (Opus 6.8–6.9,
MP3 19.2 Mbit/s).

| Node measure | Average | Max | Trend over 24 h |
|---|---|---|---|
| CPU busy | 3.8% | 5.6% | flat |
| Network out | 28.3 Mbit/s | 28.9 Mbit/s | flat |
| Memory available | 6,671 MB | | 6,675 → 6,671 MB |
| Icecast memory | 14.7 MB | 19.5 MB | 14.6 → 14.7 MB (no leak) |
| Caddy memory | 281 MB | 284 MB | 281.5 → 281.1 MB (no leak) |
| Icecast / Caddy CPU | 2.9% / 9.6% | 9.3% / 18.3% | flat |

No container restarted. The soak used about **306 GB** of egress (1.5% of
the monthly quota).

The `demo` station was added during the soak with a deploy that changed no
image: the soak listeners did not notice it.

### Overhead depends on load

At 300 listeners the node sent 28.3 Mbit/s for 26.1 Mbit/s of payload:
**~8.5% overhead**, against 28% at 1,400 listeners. The per-listener-hour
billed egress at moderate load is therefore closer to the payload figures
(Opus ~22 MB, MP3 ~63 MB) than to the ramp-test figures. #37 investigates
why the overhead grows with load; until then plan with the higher figures.

## Reproduce

```sh
cd tools/loadtest && CGO_ENABLED=0 GOOS=linux go build -o loadtest .
./loadtest -url https://listen.<domain>/stations/<id>/live.opus -listeners 700 \
           -url https://listen.<domain>/stations/<id>/live.mp3 -listeners 700 \
           -ramp 5m -hold 10m -every 30s
ssh ops@<node> 'bash -s 10' < tests/load/sample-node.sh > node.csv   # in parallel
```

Raise the station's cap first (`deploy.sh apply-stations`), run from a
machine with enough bandwidth (the CI runner works), and restore the cap
afterwards. Each 1,000 listeners at MP3 128 kbps cost about 74 GB of the
node's quota per hour.
