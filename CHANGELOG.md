# Fork Divergence

This file records changes in `andretakagi/truenas-hailo` that differ from the upstream `scyto/truenas-hailo` baseline. Tracked-version bumps (`version`, `.hailo-driver-version`) are not listed here — they happen continuously and are visible in `git log` and on the GitHub Releases page.

## Install / Restore Scripts

- **Custom source repository.** `install.sh` accepts `--repo=OWNER/NAME` and the `HAILO_REPO` environment variable, so installs from a fork pull artifacts from the fork's releases instead of upstream. The selected repo is recorded in `${PERSIST_DIR}/.hailo-repo`.
- **Branch-aware preinit error messages.** `hailo-preinit.sh` reads `.hailo-repo` and points kernel-mismatch error output at the source fork's releases page, falling back to upstream if the file is missing.
- **Loud failure on missing HailoRT version.** Install/preinit now exit with a clear error if the HailoRT version cannot be determined, instead of silently proceeding with bad state.

## Sysext Activation on TrueNAS

- **`systemd-sysext unmerge` before ZFS writes.** `install.sh` and `restore.sh` now `unmerge` the sysext (rather than `refresh`) before unlocking `/usr`, so the overlay does not block the remount. Without this, repeated installs/restores would intermittently fail.

## Automated Workflows

- **Daily schedule.** Both `Check for New TrueNAS Releases` (06:15 UTC) and `Check for New Hailo Releases` (06:00 UTC) run daily instead of weekly.
- **Explicit `GITHUB_TOKEN` permissions.** Scheduled workflows declare `permissions:` blocks so the default read-only token does not block issue/dispatch/push API calls.
- **Branch-aware HailoRT detection.** `Check for New Hailo Releases` shallow-clones the upstream `hailo8` branch and uses `git tag --merged origin/hailo8` to enumerate candidate tags. The previous `/tags` API + major-version filter could not guarantee a 4.x tag actually lived on `hailo8`.
- **Hailo auto-bump and auto-build.** When a newer hailo8-reachable tag is detected, the workflow commits the bump to `.hailo-driver-version` and dispatches `build.yml` directly (the previous flow filed an issue and waited for a human dispatch).
- **TrueNAS ISO availability gate.** `Check for New TrueNAS Releases` only bumps `version` and dispatches `build.yml` once the matching ISO is published at `download.truenas.com`. Tags in `truenas/scale-build` can land hours or days before the ISO appears.
- **`mark_latest` input on `build.yml`.** Both scheduled checks dispatch with `mark_latest='false'`, so auto-built releases publish without claiming the "Latest" badge. A human still promotes a release to Latest in the GitHub UI after verifying it on Hailo-8 hardware. Manual `workflow_dispatch` invocations default to `mark_latest='true'` to preserve previous behavior.

## Documentation

- README and install/restore docs point at `andretakagi/truenas-hailo` releases instead of upstream.
- README credits `scyto/truenas-hailo` as the upstream project.
