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
through the same gateway measured 11.6%. See *Egress overhead (#37)* below
for the cause. Plan with the node-level figure.

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

## Egress overhead (#37)

### Framing: about 10%, and the same at every load

Local stack (Caddy 2.11.6, Icecast 2.5, release `7765041`), pink-noise
sources (MP3 128 kbps, Opus 64 kbps), `tools/loadtest` through Caddy. The
TCP counters come from Caddy's network namespace (`/proc/net/snmp`).
Overhead = bytes Caddy sent on the wire (headers counted per TCP segment)
÷ audio bytes the listeners received − 1.

| Listeners (half Opus, half MP3) | Payload per TCP segment | Retransmits | Overhead |
|---|---|---|---|
| 100 | 753 B | 4 | 10.7% |
| 300 | 751 B | 38 | 10.7% |
| 1,400 | 751 B | 299 | 10.8% |

| Format only (300 listeners) | Payload per TCP segment | Overhead |
|---|---|---|
| Opus 64 kbps | 928 B | 8.5% |
| MP3 128 kbps | 698 B | 11.6% |

Icecast writes each listener's audio in small blocks, and Caddy forwards
each block at once. Each block becomes one HTTP chunk (~7 B), one TLS
record (22 B) and one TCP segment (66 B of Ethernet, IP and TCP headers),
about 95 B per 750 B of audio. This overhead does not depend on the number
of listeners.

### Caddy `flush_interval` has no effect

Caddy ignores `flush_interval` for responses without `Content-Length`
and flushes every write at once (`flushInterval()` in
`modules/caddyhttp/reverseproxy/streaming.go`, v2.11.6). Icecast streams
never send a length. Measured with 300 listeners:

| `flush_interval` | Payload per TCP segment | Overhead | Time to first audio p50, Opus / MP3 |
|---|---|---|---|
| `-1` (current) | 751 B | 10.8% | 535 / 217 ms |
| `100ms` | 751 B | 10.8% | 549 / 220 ms |
| `250ms` | 750 B | 10.8% | 526 / 203 ms |

The setting stays `-1`, which documents what Caddy does anyway. The
earlier attempt to change it also had no effect, for the same reason.
Larger writes would need a change in Icecast or a buffering proxy, and
would cut at most ~5 points.

### Load-dependent part: the network path

In production the overhead went from ~8.5% at 300 listeners to 28% at
1,400. The local stack shows no such growth: segment size, framing and
retransmits stay flat up to 1,400 listeners. The extra ~17 points come from
the path between the node and the load generator (`tc-runner-1`).
Retransmits are the likely cause, because they are sent bytes that the
listener counts only once.

`tests/load/sample-node.sh` now records packets per second, TCP segments
per second and retransmits per second from the Caddy container. Next
production load test: compare `retrans_ps` with `out_segs_ps` at 300 and
at 1,400 listeners.

Until that test runs, plan with:

| Use | Factor over audio payload |
|---|---|
| Framing only (normal load, many networks) | **1.10** (Opus 1.09, MP3 1.12); 1.15 since the 2026-10-18 re-test, see below |
| Worst case measured (1,400 listeners from one host) | 1.28 |

Real listeners come from many networks, not from one VM. Retransmits
then spread over many paths, so production should stay near the framing
figure. The control plane (tc-dashboard#10) uses **1.10** to estimate egress
per station. The operator view uses the node's real `tx_bytes` against
the quota, not the estimate.

## AutoDJ playout

Issue #65. What one AutoDJ station costs the `playout` service (#63), and
how many fit next to the listener load above.

### Method

`tests/load/playout-bench.sh 1 5 10 15` runs Icecast, the stubs and the
playout image with N stations, each publishing MP3 128 kbps (44.1 kHz
stereo) and Ogg Opus 64 kbps (48 kHz stereo) from pink-noise tracks (the
encoders work as hard as with music). After a 20 s warm-up it averages 12
`docker stats` samples (one call for both containers, then 5 s), with no CPU
or memory limit. 100% = one core. A station count whose mounts do not all come
up within 90 s fails the run instead of being measured. Measured on a laptop (Intel i7-8550U, 4 cores / 8 threads) on
2026-10-15; **not yet on a CX33**, see *Confirm on the node type* below.

### Encoders

One station, per encoder, from `cpu.stat` over 30 s:

| Part | Native Liquidsoap encoders | FFmpeg encoders (`%ffmpeg`) |
|---|---|---|
| Decode and Liquidsoap itself | 3% | 3% |
| MP3 128 kbps | 5% | |
| Ogg Opus 64 kbps, 44.1 to 48 kHz | 10% (most of it the resampler) | |
| Both outputs | **20%** | **10%** |

Lower LAME quality (`internal_quality=5`) saved 4 points and Opus
`complexity=5` none: the cost was Liquidsoap's resampler. The playout
service uses FFmpeg's libmp3lame and libopus.

### Per station

| Stations | Playout CPU | Playout memory | Icecast CPU |
|---|---|---|---|
| 1 | 9% | 105 MB | 4% |
| 5 | 42% | 466 MB | 4% |
| 10 | 74% | 918 MB | 7% |
| 15 | 91% | 1,382 MB | 6% |

About **6–9% of a core and 92 MB per station** (one Liquidsoap process
each). Icecast barely notices: an AutoDJ mount is one more source.

### Limits and placement

- **Limits** (`compose.yaml`, `deploy/compose.yaml`): `cpus: 1.5`
  (`PLAYOUT_CPUS`), `mem_limit: 2g` (`PLAYOUT_MEMORY`), `pids_limit: 1024`,
  and `cpu_shares: 512`: the container's CPU weight (cgroup v2 `cpu.weight`
  59) is about half that of Icecast and Caddy (100), so they win on a busy
  node. A `nice` value inside the container would not do this: it only orders
  processes within the container's own cgroup. `pids_limit` counts threads:
  about 28 per station (28, 109, 225 and 457 at 1, 4, 8 and 16 stations, on
  an 8-thread machine, 2026-10-15), so 1,024 leaves memory as the limit that
  binds first (2 GB is about 20 stations). The ramp test used 0.6 core at 1,400
  listeners (Icecast 0.15, Caddy 0.5) of the CX33's 4, so AutoDJ can never
  take the cores the listeners need. A playout service at its limit makes
  AutoDJ audio stutter; live stations are not affected.
- **Threshold: 8 AutoDJ stations per node** (MP3 + Opus each), assuming up
  to 15% of a shared CX33 vCPU per station: 1.2 cores and about 750 MB,
  inside the limits with room to spare. The source budget allows 16
  single-format AutoDJ stations, which still fit: about 1.5 GB and 0.8 core.
- **`<sources>` is 66**: 50 live mounts as before, plus 16 AutoDJ mounts.
  The control plane counts AutoDJ mounts in `STREAMING_MAX_SOURCES`
  (tc-dashboard `NodeCapacity`), so set it to **66** together with this
  release. Deploying the change restarts Icecast (quiet hour).
- **Beyond 8 stations:** run playout on its own node on the private network,
  feeding the streaming node's Icecast. Not built yet: one node carries
  the AutoDJ stations of the MVP.
- Later, to fit more per node: one Liquidsoap process for several stations
  would save most of the 92 MB each, at the cost of the isolation between
  stations.

### Confirm on the node type

Before relying on the threshold, run on `tc-runner-1` (same Hetzner type as
`tc-stream-1`):

```sh
tests/load/playout-bench.sh 1 4 8 12
```

Then the acceptance test, on the production node in a quiet hour: enable
AutoDJ for 8 test stations, run the 1,400-listener ramp from *Reproduce*
against a live station, and compare the listeners' time to first audio,
drops and errors, and Icecast's CPU, with the ramp test above. If the CX33
needs more than 15% per station, lower the threshold (and
`STREAMING_MAX_SOURCES`) accordingly.

## Reproduce

```sh
cd tools/loadtest && CGO_ENABLED=0 GOOS=linux go build -o loadtest .
./loadtest -url https://listen.<domain>/stations/<id>/live.opus -listeners 700 \
           -url https://listen.<domain>/stations/<id>/live.mp3 -listeners 700 \
           -ramp 5m -hold 10m -every 30s
ssh ops@<node> 'bash -s 10' < tests/load/sample-node.sh > node.csv   # in parallel
```

Raise the station's cap first (`deploy.sh apply-stations`), run from a
machine with enough bandwidth (a temporary Hetzner CX33 in the same location
works), and restore the cap
afterwards. Each 1,000 listeners at MP3 128 kbps cost about 74 GB of the
node's quota per hour.

## Re-test after the latency changes (#83)

#85 cut each station mount's start-up burst from 64 KiB to 0.5 s of audio,
and `<source-timeout>` from 10 s to 3 s. A player now starts with less audio
in hand, so a network gap it used to ride out may become a silence.
`tools/loadtest` counts these: a **stall** is a gap longer than `-stall`
(500 ms) between two reads after the first byte. `MaxGap` is the longest
gap.

Pass when, compared with the 2026-10-06 run above:

- no drops, refusals or errors, as before;
- stalls: none during the hold at 1,400 listeners, none over the 24 h soak;
  max gap under 500 ms (Icecast writes every ~100 ms);
- time to first audio p95 no worse than 1 s (Opus) and 400 ms (MP3);
- the node's CPU, memory and egress per listener-hour within 10 % of the
  tables above.

Steps, with the release that contains #85 deployed on the node:

1. Raise the test station's listener cap to 1,500 or more through the
   control plane: put it on a plan whose cap covers the test (Pro: 25,000,
   lowered to 16,384 on the node). Not with `deploy.sh apply-stations`:
   tc-dashboard pushes `stations.json` again within seconds and would undo
   it, and that command replaces the whole file.
   The burst follows the plan's bitrate cap (#85: 0.5 s at the cap, Opus
   counted at no more than 96 kbps, at least 4 KiB), so the plan changes
   what the test measures:

   | Plan (bitrate cap) | MP3 128 kbps burst | Opus 64 kbps burst |
   |---|---|---|
   | Free (64) | can't publish 128 kbps MP3 (4,096 B: 0.5 s at 64 kbps) | 4,096 B = 0.5 s |
   | Starter (128) | 8,000 B = 0.5 s | 6,000 B = 0.75 s |
   | Growth (192) | 12,000 B = 0.75 s | 6,000 B = 0.75 s |
   | Pro (320) | 20,000 B = 1.25 s | 6,000 B = 0.75 s |

   On Pro, judge stalls on the **Opus** stream: its burst is the one Starter
   and Growth stations get. The MP3 stream starts with 2.5 times a Starter
   station's burst, so its stall count is optimistic; it still checks drops,
   CPU and egress. For a Starter-like MP3 figure, run a shorter second pass
   with the station on Starter (500 listeners: about 250 MP3 for an hour).
2. Create the load generator, `tc-loadgen-1`, with `infra/loadgen`
   ([Load generator](reference/infrastructure.md#load-generator-terraform)):
   `terraform apply`, then `ssh root@<ipv4> cloud-init status --wait`. It has
   ffmpeg, tmux and `loadtest` installed. `tc-runner-1`, used for #12, no
   longer exists.
3. Publish the two sources from it, inside `tmux`, with the desktop app's
   encoder flags (tc-station `FfmpegExecutable.Arguments`):

   ```sh
   ffmpeg -re -f lavfi -i "anoisesrc=color=pink:sample_rate=44100" -ac 2 \
     -c:a libmp3lame -b:a 128k -flush_packets 1 -write_xing 0 \
     -content_type audio/mpeg -ice_public 0 -f mp3 -tls 1 \
     "icecast://42:<password>@ingest.tropicastradio.com:443/stations/42/live.mp3" &
   ffmpeg -re -f lavfi -i "anoisesrc=color=pink:sample_rate=48000" -ac 2 \
     -c:a libopus -b:a 64k -application audio -flush_packets 1 -page_duration 100000 \
     -content_type audio/ogg -ice_public 0 -f ogg -tls 1 \
     "icecast://42:<password>@ingest.tropicastradio.com:443/stations/42/live.opus" &
   ```

4. Sample the node (10 s for the ramp test, 60 s for the soak), from your
   machine:
   `ssh ops@<node> 'bash -s 10' < tests/load/sample-node.sh > node-ramp.csv`.
5. Ramp test, from the load generator:

   ```sh
   loadtest -url https://listen.tropicastradio.com/stations/42/live.opus -listeners 700 \
              -url https://listen.tropicastradio.com/stations/42/live.mp3 -listeners 700 \
              -ramp 5m -hold 10m | tee ramp.txt
   ```

6. Soak: the same with `-listeners 150` each, `-ramp 2m -hold 24h -every 5m`,
   under `tmux`, and the node sampled every 60 s.
7. Put the test station back on its plan, stop the sources, copy the results off the load
   generator (`scp root@<ipv4>:ramp.txt .`), `terraform destroy` it, and add
   the results here.

### Results (2026-10-18/19)

Node `tc-stream-1` with #85 (0.5 s bursts, 3 s source timeout) and #86. The test station was on the Pro plan, so its
MP3 burst was 1.25 s (see the table above): judge stalls on Opus. Load from `tc-loadgen-1` (`infra/loadgen`) in
the same site, sources with the desktop app's flags (100 ms Ogg pages).

**Verdict: pass.** No drops, refusals, errors or stalls, in the ramp test or in 24 hours. Every listener kept its
first connection. Memory is flat. Time to first audio on Opus is better than before. The node uses more CPU per
listener than on 2026-10-06; it is far from a limit (see below).

Listeners:

| | Ramp: 1,400 for 10 min | Soak: 300 for 24 h | 2026-10-06 (ramp / soak) |
|---|---|---|---|
| Drops / refused / errors | 0 / 0 / 0 | 0 / 0 / 0 | 0 / 0 / 0 |
| Stalls (gap > 500 ms), Opus | 1 of 700, 560 ms (\*) | 0 | not measured |
| Stalls, MP3 | 0 | 0 | not measured |
| Longest gap, Opus / MP3 | 560 / 425 ms | 320 / 214 ms | not measured |
| Time to first audio p95, Opus | 425 ms | 423 ms | 999 ms / 1.0 s |
| Time to first audio p95, MP3 | 385 ms | 378 ms | 383 / 374 ms |
| Payload per listener-hour, Opus / MP3 | 21.5 / 57.6 MB | 21.4 / 57.6 MB | 20.9 / 57.9 MB |

(\*) Between 840 and 850 s, the same 10 s as the node's highest retransmit rate of the hold (113/s against 26/s on
average): the network path, not Icecast. Shorter than the 0.75 s Opus burst a player starts with.

Node, during the hold:

| | Ramp (48 samples) | Soak (1,387 samples) | 2026-10-06 (ramp / soak) |
|---|---|---|---|
| CPU busy | 21.7 % (max 22.9) | 6.2 % (max 21.5), flat | 13.8 % / 3.8 % |
| Network out | 163.0 Mbit/s | 29.9 Mbit/s, flat | 155.8 / 28.3 Mbit/s |
| Caddy CPU | 59.5 % | 15.0 % | 38.6 % / 9.6 % |
| Icecast CPU | 16.1 % | 4.3 % | 10.8 % / 2.9 % |
| Icecast memory | 27.7 MB | 26.9 → 27.4 MB | 14.5 / 14.7 MB |
| Caddy memory | 325 → 355 MB | 298 → 298 MB | 316 → 351 / 281 MB |
| Retransmits | 0.07 % of segments | 0.06 % | not measured |
| Bytes per TCP segment | 558 | 552 | not measured (751 locally, #37) |
| Overhead over the audio payload | 33 % | 13.5 % | 28 % / 8.5 % |

What changed since 2026-10-06:

- **CPU is about 60 % higher for the same listeners**, mostly Caddy (TLS). Segments carry about 552 bytes of audio
  instead of 751 measured locally in #37: more, smaller writes, so more TLS records and segments. The likely cause
  is the Opus sources' 100 ms Ogg pages (tc-station#74, about 575 bytes at 46 kbit/s) instead of about 1 s pages:
  each page reaches the listener as its own write. Not proven: a ramp with the Opus source on FFmpeg's default
  pages would confirm it. At 1,400 listeners the node is at 22 % CPU, so capacity is still set by the 20 TB egress
  quota, not the CPU.
- **Overhead on the wire grew with it**: 13.5 % at 300 listeners (8.5 % before), 33 % at 1,400 (28 %). Plan with
  1.15 instead of 1.10 for framing at normal load (Egress overhead above), until the cause is confirmed.
- **Icecast holds about 13 MB more memory** (27 MB), flat over 24 hours: no leak. Likely the AutoDJ mounts and
  per-mount settings added since; not a concern at this size.
- **Opus starts faster**: 423 ms instead of about 1 s at p95, from the smaller pages and burst.
