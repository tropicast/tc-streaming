# Changelog

All notable changes to the streaming plane. Format: [Keep a Changelog](https://keepachangelog.com/);
versions follow [Semantic Versioning](https://semver.org/).

When releasing, rename `Unreleased` to the version (for example `## [0.2.0] - 2026-11-01`) and add a
new empty `Unreleased` section. The release workflow requires that section and publishes it above the
auto-generated list of merged pull requests. See [Releasing](docs/runbook.md#releasing).

## [Unreleased]

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

- Pro-plan listener caps above Icecast's maximum (16384) are lowered instead of being ignored.
