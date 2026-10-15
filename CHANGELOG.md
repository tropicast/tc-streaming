# Changelog

All notable changes to the streaming plane. Format: [Keep a Changelog](https://keepachangelog.com/);
versions follow [Semantic Versioning](https://semver.org/).

When releasing, rename `Unreleased` to the version (for example `## [0.2.0] - 2026-11-01`) and add a
new empty `Unreleased` section. The release workflow requires that section and publishes it above the
auto-generated list of merged pull requests. See [Releasing](docs/runbook.md#releasing).

## [Unreleased]

### Added

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
