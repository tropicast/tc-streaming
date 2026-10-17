# Build and test

Run the end-to-end tests locally with `tests/source-auth.sh`, `tests/gateway.sh` and
`tests/station-limits.sh`; they build the images themselves unless `E2E_PREBUILT=1`.

## CI

Every workflow runs only when the files it covers change, so a docs-only
change runs nothing. A newer push to a pull request cancels its running
checks; runs on `main` always finish.

| Workflow                                          | Runs when                                  | Does                                                                                 |
| ------------------------------------------------- | ------------------------------------------ | ------------------------------------------------------------------------------------ |
| `image.yml`                                       | Icecast image files change (PR, `main`)    | Build, health smoke test, Trivy. On `main`, push `ghcr.io/tropicast/icecast`         |
| `caddy-image.yml`                                 | `caddy/Dockerfile` changes (PR, `main`)    | Build, layer4 check, Trivy. On `main`, push `ghcr.io/tropicast/caddy`                |
| `playout-image.yml`                               | `playout/` changes (PR, `main`)            | Build, supervisor and encoder smoke test, Trivy. On `main`, push `ghcr.io/tropicast/playout` |
| `e2e.yml`                                         | Images, Compose, auth stub or tests change | One job: builds the images once, runs the `tests/*.sh` end-to-end suites (including `tests/playout.sh`, and `tests/latency.sh` with its [budgets](../reference/latency.md)) |
| `deploy-lint.yml`, `terraform.yml`, `ansible.yml` | Their own files change                     | Lint and validate                                                                    |
| `release.yml`                                     | A `v*` tag is pushed                       | Checks the tag and changelog, adds version tags to the images, drafts the release    |

Jobs run on GitHub-hosted `ubuntu-latest` runners. Workflows and tests use
per-run image tags, Compose projects, ports and Docker config, so they never
depend on what another job left behind.

Images are built with the full git SHA as their tag. A release
([Releasing](../runbook.md#releasing)) adds `:<version>` (and `:latest` for
non-pre-releases) to the same images, without rebuilding them. The `push` path filters of the two image
workflows must match the path lists in `deploy.yml`, because a deploy uses
the image of the last `main` commit that touched those paths.

Builds share the GitHub Actions cache by image (`scope=icecast`,
`scope=caddy`), so e2e and pull requests reuse what `main` built. The Trivy
database is cached for a day. Run the e2e tests locally with
`tests/source-auth.sh` and `tests/gateway.sh` (they build the images
themselves unless `E2E_PREBUILT=1`).
