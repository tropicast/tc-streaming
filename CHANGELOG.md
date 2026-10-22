# Changelog

All notable changes to the streaming plane. Format: [Keep a Changelog](https://keepachangelog.com/);
versions follow [Semantic Versioning](https://semver.org/).

When releasing, rename `Unreleased` to the version (for example `## [0.2.0] - 2026-11-01`) and add a
new empty `Unreleased` section. The release workflow requires that section and publishes it above the
auto-generated list of merged pull requests. See [Releasing](docs/runbook.md#releasing).

## [Unreleased]

### Added

- GitLab CI (#117): `.gitlab-ci.yml` runs the GitHub workflows' image builds, e2e tests, lints, releases, deploys and Terraform on the self-hosted GitLab, plus the shared security jobs. Images go to the GitLab registry; `deploy.sh` reads the registry from the release (`STREAMING_REGISTRY`, GHCR for older releases). The first deploy from GitLab restarts Icecast, Caddy and playout, because the image names change. Setup: [runbook, GitLab CI](docs/runbook.md#gitlab-ci).

### Changed

- The Caddy image cross-compiles for the target platform (`caddy/Dockerfile`), so the arm64 GitLab runner builds the x86 image without emulation. Its tag changes, so the next deploy restarts Caddy: connections drop for a few seconds.

### Fixed

- The load generator (`tools/loadtest`) no longer races its own shutdown: listeners are counted before the ramp starts, so `wg.Wait` never runs while the ramp adds one (found by the GitLab SAST job).
- Security scan findings accepted with a reason: Icecast's entrypoint parses the config it rendered itself (`nosemgrep` on the XML parse), and Caddy still runs as root (`.trivyignore`; #119 changes that). The entrypoint change is a comment, but it changes the Icecast image: the next deploy restarts Icecast.

## [0.2.0] - 2026-10-21

### Changed

- AutoDJ fades in when a DJ drops (#109): while a DJ is live on a format, that format's AutoDJ output is silent; when the DJ drops, it fades in over 2 s, on a new track once no format is live, instead of starting at full volume mid-track. The playout service reads Icecast's public status page every 0.25 s (`PLAYOUT_LIVE_POLL_SECONDS`) to know which live mounts have a DJ. Live to AutoDJ is now heard after 1.7–1.9 s (was 0.5–0.8 s), part way into the fade; `tests/latency.sh` budgets it separately (2.5 s, a dead source 7 s). Deploying it restarts the AutoDJ sources.
- AutoDJ crossfades between tracks (#110): the ending track fades out while the next fades in, over 3 s, instead of a hard cut. Deploying it restarts the AutoDJ sources (a new script): their listeners reconnect.

### Fixed

- Off-air stations no longer look broken (#113). A player asking for a station mount with no source got Icecast's 404 XML ("The file you requested could not be found"), and every request logged an `EROR` and two `WARN` lines. Caddy now answers `503` with `Retry-After: 60` and a plain-text "Station off air" body; Alloy drops Icecast's file-lookup and Accept-parse lines and ships the 404 access line at level `info`. Unknown station IDs get the same `503`. Deploying it reloads Caddy in place and restarts Alloy: no listener disconnects.
- Directory metadata reached RadioBrowser only while a DJ was live (#107): a listener on an idle live mount gets the AutoDJ fallback mount's headers, which had none (`icy-name: AutoDJ`, no `icy-index-metadata`). The `autodj.<fmt>` mounts now send the station's directory headers and name too, so a listing updates whatever is on air. Deploying it restarts Icecast (a new image): listeners and sources reconnect.

### Added

- `stations.json`: `directory.geo_lat_long` (`"<lat>,<long>"`), sent as `icy-geo-lat-long` by a listed station's mounts (#105). RadioBrowser reads it to place an already listed station on its map (tc-dashboard#148). Deploy this before the tc-dashboard release that sends it: an older node refuses the whole file.

### Fixed

- Back to live on Opus took up to 1.7 s, and listeners stayed that far behind the DJ (#93): AutoDJ sent Ogg pages of about 1.25 s, and a listener plays out the page they hold before the live audio. AutoDJ's Opus now leaves in 100 ms pages, as the desktop app's: 0.5–0.7 s, as quick as MP3. Deploying it restarts the AutoDJ sources. `tests/latency.sh` budgets for switches are back to 1.5 s, and its DJ captures audio only once Icecast accepts it, as the app does.

### Added

- Load and soak re-test after #83 (#94): 1,400 listeners and 300 for 24 h, no drops or stalls; CPU about 60 % higher per listener, likely the 100 ms Ogg pages ([load test](docs/load-test.md#results-2026-10-1819)).

### Changed

- AutoDJ goes on air within seconds (#86): the playout service polls every 3 s instead of 30 s (`304` while nothing changed), and starts a station as soon as one of its tracks is cached. It downloads the others in the background, `PLAYOUT_DOWNLOAD_WORKERS` (4) at once, every station's first track first. 200 tracks published to the first AutoDJ byte: 27 s before, 5–9 s now (most of it Liquidsoap's start).
- Listeners hear the station about 0.6 s behind the source instead of 4.3 s (MP3) and 5.5 s (Opus), and a switch between live and AutoDJ within 0.5–1.5 s instead of 4–7 s (#85). Each station mount's start-up burst is 0.5 s at its `max_bitrate_kbps` (at least 4 KiB) instead of a global 64 KiB; the global default is 8 KiB. Players that buffer before playing wait that long at start. Deploying it restarts Icecast (a new image): listeners and sources reconnect.
- `<source-timeout>` is 3 s instead of 10 s: when a DJ's connection dies without closing, listeners get AutoDJ in about 4 s. `tests/latency.sh` checks it.
- `stations.json`: `max_bitrate_kbps` must be an integer from 8 to 640 when present.

### Added

- `tests/latency.sh` (#84) measures, in CI, how far behind the microphone a listener hears the station, how late they hear a switch between live and AutoDJ, and the AutoDJ warm-up, against budgets ([Latency](docs/reference/latency.md)). Baseline: 4.3 s (MP3) and 5.5 s (Opus), switches included, mostly Icecast's burst.
- The exporter reports `tc_autodj_mount_start_timestamp_seconds` and `tc_autodj_mount_bitrate_kbps` (#77), so tc-dashboard can spot a playout restart and estimate AutoDJ egress from the bitrate. The start time is left out when Icecast gives none.
- The playout service declares each AutoDJ output's bitrate (`ice-bitrate`): `%ffmpeg` hides it from Liquidsoap, so Icecast only had a measured estimate. Deploying it restarts the AutoDJ sources.

### Fixed

- Icecast warnings in the logs: source auth reads only the new-style answer headers (`x-icecast-auth-result: ok`; **the control plane must send them first**: tc-dashboard#135); MP3 AutoDJ title updates send `song` only; `GET /admin/metadata` (how every ICY source updates titles) runs in Icecast's legacy mode, so it is not reported as an unsafe use of GET.
- A deploy that changes `config.alloy` or the exporter now restarts Alloy or the exporter: Compose did not recreate them, so they kept the old file (the *AutoDJ playout* panel showed "AutoDJ is not enabled on this node" because Alloy never scraped playout).
- The playout service accepts tracks without `sha256` (cached by track id), as tc-dashboard sends them.
- The deploy signs the playout service in with the source auth node credentials unless `PLAYOUT_USER` / `PLAYOUT_PASSWORD` are set, and the runbook's `PLAYOUT_URL` is tc-dashboard's `/internal/playout/stations`.

## [0.1.0] - 2026-10-15

### Changed

- StationSourceDropped no longer fires while AutoDJ plays for the station; the *Live stations*, *Listeners per station* and *Listener egress per station* panels no longer count AutoDJ mounts as a station without a name (listeners and egress now include AutoDJ).
- Icecast `<sources>` is 66 (50 live plus 16 AutoDJ mounts); set the control plane's `STREAMING_MAX_SOURCES` to the same. Deploying it restarts Icecast.
- The playout service encodes with FFmpeg's libmp3lame and libopus: half the CPU of Liquidsoap's native encoders.

### Added

- AutoDJ monitoring (#66): the exporter reports `tc_station_autodj_enabled` and `tc_autodj_mount_up` / `_listeners` / `_sent_bytes_total`; the playout service serves `playout_*` metrics on `:9101`, scraped by Alloy. Alerts PlayoutDown, AutoDJSourceMissing and StationOffAir (per format, not for stations without a playable track), AutoDJNoPlayableTrack (info), PlayoutEndpointFailing and PlayoutStationRestarting; dashboard panels *Stations on live vs AutoDJ* and *AutoDJ playout*.
- AutoDJ capacity (#65): `tests/load/playout-bench.sh`; the playout service is capped (`PLAYOUT_CPUS` 1.5, `PLAYOUT_MEMORY` 2g, 1,024 pids) and has half the CPU weight of Icecast and Caddy (`cpu_shares: 512`); about 8 AutoDJ stations per node.
- AutoDJ playout service (`playout/`, Compose profile `autodj`): Liquidsoap 2.4.6 and a supervisor that polls the control plane's playout endpoint, caches tracks by sha256 and runs one Liquidsoap process per station on its AutoDJ mounts. Playlist changes apply without a restart; adding or removing a station leaves the others playing. Image `ghcr.io/tropicast/playout`, deployed and release-tagged with the others.
- AutoDJ fallback mounts: `"autodj": true` in `stations.json` adds a hidden `/stations/{id}/autodj.{fmt}` mount per format; the live mount falls back to it when the DJ drops and takes listeners back when the DJ returns. Caddy never serves AutoDJ mounts.
- Release workflow: a `v*` tag checks the changelog, adds version tags to the Icecast and Caddy images of that commit (same digests, nothing restarts) and drafts a GitHub Release. The version comes from the tag only.
- Deploy a release by tag (`ref=v0.1.0`); the exporter reports the deployed release as `tc_streaming_build_info`, shown in the dashboard's **Release** panel.
- Icecast 2.5.0 image built from pinned sources, running as non-root, with passwords kept out of the environment.
- Per-station mounts for MP3 and Ogg Opus, with listener caps, formats and bitrates from `stations.json`, reloaded without dropping listeners.
- Source authentication against the control plane; no shared broadcast password.
- Caddy TLS gateway: HTTP proxy for listeners, layer4 pass-through for sources, Let's Encrypt certificates.
- RadioBrowser listing metadata (`icy-*` headers) per station.
- Monitoring: exporter, Grafana Alloy, alert rules, dashboard, and Icecast logs in Grafana Cloud Logs.
- Hetzner node with Terraform, hardening with Ansible, and a manual deploy workflow with rollback.

### Fixed

- MP3 track titles reach listeners (#72): Icecast checks a source's ICY metadata update with source auth (`action=metadata_auth`), and the ingest gateway passes it for live mounts. Needs tc-dashboard's endpoint to accept `metadata_auth`; until then titles stay refused as before.
- Pro-plan listener caps above Icecast's maximum (16384) are lowered instead of being ignored.
