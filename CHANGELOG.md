# Fork Divergence

This file records changes in `andretakagi/truenas-hailo` that differ from the upstream `scyto/truenas-hailo` baseline. Tracked-version bumps (`.github/tracked-versions.json`) are not listed here — they happen continuously and are visible in `git log` and on the GitHub Releases page.

## Install / Restore Scripts

- **Custom source repository.** `install.sh` accepts `--repo=OWNER/NAME` and the `HAILO_REPO` environment variable, so installs from a fork pull artifacts from the fork's releases instead of upstream. The selected repo is recorded in `${PERSIST_DIR}/.hailo-repo`.
- **Branch-aware preinit error messages.** `hailo-preinit.sh` reads `.hailo-repo` and points kernel-mismatch error output at the source fork's releases page, falling back to upstream if the file is missing.
- **Loud failure on missing HailoRT version.** Install/preinit now exit with a clear error if the HailoRT version cannot be determined, instead of silently proceeding with bad state.
- **Bounded curl downloads.** `install.sh` caps every release/firmware/install-script download with `--max-time`, so a stalled connection fails fast instead of hanging the install indefinitely.

## Sysext Activation on TrueNAS

- **`systemd-sysext unmerge` before ZFS writes.** `install.sh` and `restore.sh` now `unmerge` the sysext (rather than `refresh`) before unlocking `/usr`, so the overlay does not block the remount. Without this, repeated installs/restores would intermittently fail.

## Automated Workflows

- **Single check workflow + single state file.** Replaced the two scheduled workflows (`check-truenas-release.yml`, `check-hailo-release.yml`) and the three root-level state files (`version`, `train`, `.hailo-driver-version`) with one workflow (`.github/workflows/check-releases.yml`) and one CI-state file (`.github/tracked-versions.json`). When both upstreams move on the same day, only one consolidated build is dispatched instead of two back-to-back. A `concurrency` block serializes manual dispatches against the scheduled run so they cannot race on the commit/push.
- **Daily schedule.** The unified `Check for New Releases` runs daily at 06:00 UTC instead of weekly.
- **Explicit `GITHUB_TOKEN` permissions.** Scheduled workflows declare `permissions:` blocks so the default read-only token does not block issue/dispatch/push API calls.
- **Branch-aware HailoRT detection.** The check shallow-clones the upstream `hailo8` branch and uses `git tag --merged origin/hailo8` to enumerate candidate tags. The previous `/tags` API + major-version filter could not guarantee a 4.x tag actually lived on `hailo8`.
- **Hailo auto-bump and auto-build.** When a newer hailo8-reachable tag is detected, the workflow commits the bump to `.github/tracked-versions.json` and dispatches `build.yml` directly (the previous flow filed an issue and waited for a human dispatch).
- **TrueNAS ISO availability gate.** The check only bumps the tracked TrueNAS version and dispatches `build.yml` once the matching ISO is published at `download.truenas.com`. Tags in `truenas/scale-build` can land hours or days before the ISO appears.
- **Auto-resolved train name.** The check no longer hardcodes a major.minor filter or the train name. It picks the highest stable scale-build tag, resolves the train name from `download.truenas.com`'s directory listing, and writes both `version` and `train` atomically. When iXsystems rolls a new train (Goldeye → next), the daily check picks it up automatically and surfaces a `::notice::` annotation on the run that does the rollover.
- **Frigate-pin gate on Hailo bumps.** The check caps the candidate version at the `hailo_version` pinned in Frigate's `docker/main/install_hailort.sh` on the `dev` branch. The tracked driver never moves ahead of what Frigate's bundled userspace can talk to.
- **`mark_latest` input on `build.yml`.** The scheduled check dispatches with `mark_latest='false'`, so auto-built releases publish without claiming the "Latest" badge. A human still promotes a release to Latest in the GitHub UI after verifying it on Hailo-8 hardware. Manual `workflow_dispatch` invocations default to `mark_latest='true'` to preserve previous behavior.
- **Build runner resolved per-build.** `runs-on:` is no longer pinned to `ubuntu-22.04`. The check invokes `.github/scripts/resolve-runner.sh` to look up TrueNAS's Debian release from its own published build metadata (`GITMANIFEST` → `truenas-build/conf/build.manifest`) and pick a matching Ubuntu runner. When TrueNAS rebases onto a new Debian release, the auto-bump fails loud with `::error::unknown debian_release '<codename>'` and the fix is a one-line `case` arm — no more hand-tracking which Ubuntu pairs with which TrueNAS.
- **Auto-synced `workflow_dispatch` defaults.** Each auto-bump commit also rewrites `build.yml`'s `workflow_dispatch` defaults via `.github/scripts/sync-build-defaults.sh`, so a manual "Run workflow" in the Actions UI always pre-fills the latest tracked combination (TrueNAS version, train, HailoRT driver, runner). The substitution is structurally validated and fails loud if `build.yml`'s shape drifts.
- **Lint workflow with shellcheck and PREINIT-sync gate.** `.github/workflows/lint.yml` runs `shellcheck --severity=warning` against all shipped shell scripts (`scripts/*.sh`, `.github/scripts/*.sh`) and runs `check-preinit-sync.sh` to ensure the standalone `hailo-preinit.sh` and the heredoc copy embedded in `install.sh` cannot drift apart.
- **Dependabot for `github-actions`.** `.github/dependabot.yml` opens weekly PRs to bump action major versions, so floating `@v4`/`@v7` references don't drift silently.
- **`tracked-versions.json` shape gate.** `.github/scripts/validate-tracked-versions.sh` runs in `lint.yml` and fails the build if `.github/tracked-versions.json` is malformed JSON, missing `truenas.{version,train}` / `hailo.driver`, has an empty train, or has a version string that doesn't match `X.Y.Z[.W]`. Catches hand-edits before they break a scheduled `check-releases` run.

## Documentation

- README and install/restore docs point at `andretakagi/truenas-hailo` releases instead of upstream.
- README credits `scyto/truenas-hailo` as the upstream project.

## Known constraints

- **HailoRT requires exact-match between kernel driver and userspace library.** The library checks the driver version on init and refuses to load with `HAILO_INVALID_DRIVER_VERSION(76)` on any mismatch — it is not "same minor" or "newer driver tolerates older lib", it is exact equality. The sysext ships the kernel module; Frigate's container ships its own bundled `libhailort` and Python wheel via `docker/main/install_hailort.sh`. Both must agree.
- **Frigate is the canonical consumer.** Tracked driver version is therefore gated by Frigate's pin (currently `4.21.0` on both stable `v0.17.1` and `dev`). When Frigate bumps `hailo_version` in its install script, the next scheduled Hailo check on this fork picks up the new ceiling automatically.
