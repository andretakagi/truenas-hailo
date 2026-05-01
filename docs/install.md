# Install Reference

## Installing a Specific Version

Release tags encode both versions: `v<truenas>-hailo<driver>` (e.g., `v25.10.2.1-hailo4.21.0`).

To install from a specific release:

```bash
# Download install.sh from a specific release tag
curl -fsSL https://github.com/andretakagi/truenas-hailo/releases/download/v25.10.3-hailo4.21.0/install.sh | sudo bash -s -- --repo=andretakagi/truenas-hailo
```

Or download `hailo.raw` manually and install it:

```bash
# Download hailo.raw from a specific release
curl -fSL https://github.com/andretakagi/truenas-hailo/releases/download/v25.10.3-hailo4.21.0/hailo.raw -o /tmp/hailo-input.raw
sudo bash install.sh --repo=andretakagi/truenas-hailo /tmp/hailo-input.raw
```

> **Note:** The path `/tmp/hailo.raw` is the installer's staging path and is rejected as a positional argument (would self-cp + clobber via the cleanup trap). Save the download to any other path.

> **Warning:** Using a `hailo.raw` built for a different TrueNAS version will fail to load
> the kernel module. The module is compiled against exact kernel headers — a version mismatch
> means `insmod` will refuse to load it. Always use the release matching your TrueNAS version.

## Install Options

| Option | Description |
| --- | --- |
| `--repo=OWNER/NAME` | GitHub repo to download release from (default: `andretakagi/truenas-hailo`). Pass `--repo=scyto/truenas-hailo` or set `HAILO_REPO` to install from upstream — but note that upstream's `tracked-versions.json` doesn't carry `hailo.firmware_sha256`, so install will hard-fail at firmware verification. |
| `--pool=NAME` | ZFS pool for persistent config (e.g., `fast`) |
| `--persist-path=PATH` | Exact path for persistent config directory |
| `--check` | Probe an existing install (read-only) and report status. Exits 0 if all checks pass, 1 otherwise. |
| `--dry-run` | Validate everything (downloads, checksums, firmware availability, squashfs repack) without modifying the system. Exits 0 if everything would have succeeded. |
| `--help` | Show usage help |

## Probing and Validating

Two read-only modes are available for diagnostics and pre-flight checks. They are mutually exclusive — passing both exits 2 with a usage error.

### `--check` — probe an existing install

Reports the state of nine things on a system that already has Hailo installed: the `/dev/hailo0` device node, the `hailo_pci` kernel module, the sysext file and merge state, the persistent config directory, the backup `hailo.raw`, the PREINIT script on disk, the PREINIT registration with TrueNAS middleware, and whether the kernel module path matches the running kernel. Each failed check prints a one-line `→` hint pointing at the next step.

Exits 0 if everything is healthy (warnings allowed), 1 if any check fails. Useful for confirming an install is sound and for gathering state to attach to a support report.

```bash
curl -fsSL https://github.com/andretakagi/truenas-hailo/releases/latest/download/install.sh | sudo bash -s -- --check
```

If you already have a local `install.sh` (e.g., downloaded for a `--pool=` install), `sudo bash install.sh --check` works too.

### `--dry-run` — validate without modifying the system

Performs every read-only and network step (release lookup, `hailo.raw` + firmware download, SHA256 verification, squashfs unpack/repack into `/tmp`) but skips every command that would mutate the running system. Each skipped mutation is logged as `[dry-run] would: <command>` so you can see exactly what an install would do, and the run ends with a summary of the target paths and resolved versions.

Useful for verifying that a release works end-to-end (network reachable, checksum matches, firmware available, squashfs tooling present) before committing to the install on a production system. Note that dry-run still requires running on TrueNAS itself — it calls `midclt` for version detection, which is not available on a generic Linux host.

```bash
sudo bash install.sh --dry-run
```

## What the Install Script Does

1. **Downloads `hailo.raw`** from the GitHub release matching your TrueNAS version (or uses a local file)
2. **Verifies the checksum** (SHA256)
3. **Downloads Hailo-8 firmware** directly from Hailo's S3 servers (not redistributed by this project)
4. **Injects firmware** into the sysext squashfs (unpacks, adds firmware, repacks)
5. **Installs the sysext** to `/usr/share/truenas/sysext-extensions/hailo.raw`
6. **Activates the sysext** via TrueNAS's symlink + refresh pattern
7. **Loads the kernel module** via `insmod`
8. **Sets up persistence** (see below)

## Persistence

TrueNAS updates replace the rootfs, which wipes `/usr/` and any installed sysext. The install script sets up automatic recovery:

### Recovery Process

1. **Backup**: The sysext (with firmware already injected) is copied to a persistent ZFS pool
2. **PREINIT script**: Registered with TrueNAS middleware, runs on every boot before apps start
3. On boot, the script compares checksums — if the installed sysext differs from the backup (indicating a TrueNAS update) or is missing, it reinstalls from the backup
4. No network access is needed at boot — firmware is already inside the backed-up sysext

### Persistent Storage Layout

```text
/mnt/<pool>/.config/hailo/
├── hailo.raw                ← Sysext backup (includes firmware)
├── .hailo-driver-version    ← HailoRT version (informational)
├── .hailo-repo              ← Source GitHub repo (used for error messages)
└── hailo-preinit.sh         ← Boot script (registered as PREINIT)
```

### Pool Selection

The install script selects a pool in this order:

1. `--persist-path=PATH` — use this exact path (highest priority)
2. `--pool=NAME` — use `/mnt/<NAME>/.config/hailo`
3. **Auto-detect** — first ZFS pool that isn't `boot-pool`

The PREINIT script finds the config at boot by scanning `/mnt/*/.config/hailo/`, so it works even if the pool name changes.

## Uninstalling

To remove the sysext and undo persistence, download `uninstall.sh` (or `restore.sh` under its historical name) from the matching release and run it as root:

```bash
curl -fsSL https://github.com/andretakagi/truenas-hailo/releases/download/v25.10.3-hailo4.21.0/uninstall.sh | sudo bash
```

> `uninstall.sh` is a thin wrapper around `restore.sh` — both are shipped in every release and do the same thing.

The script unloads `hailo_pci`, unmerges the sysext, removes `hailo.raw` from `/usr/share/truenas/sysext-extensions/`, deregisters the PREINIT init script via `midclt`, and deletes `/mnt/*/.config/hailo/`. After it finishes, a reboot returns the system to its pre-install state.

Use this if you're decommissioning the Hailo-8, switching forks, or recovering from a broken install. A TrueNAS update by itself does not require running `restore.sh` — the PREINIT script handles re-merging the sysext automatically.

## Scripts Reference

### Run-time (shipped in releases)

| Script | Purpose |
| --- | --- |
| `scripts/install.sh` | Downloads release, fetches firmware, injects into sysext, installs, sets up persistence |
| `scripts/restore.sh`   | Uninstalls sysext, deregisters init script, cleans up persistent storage |
| `scripts/uninstall.sh` | Discoverable alias — exec's `restore.sh`                                 |
| `scripts/hailo-preinit.sh` | Boot-time script — activates sysext before apps start. Bundled inside `hailo.raw` at `/usr/lib/hailo/hailo-preinit.sh`; `install.sh` extracts it during firmware injection and copies it to the persistent pool. |

### Build / CI (run on GitHub Actions, not shipped)

| Script | Purpose |
| --- | --- |
| `.github/scripts/validate-tracked-versions.sh` | Lint gate — verifies `.github/tracked-versions.json` has the shape the auto-bump workflow assumes |
| `.github/scripts/resolve-runner.sh` | Looks up TrueNAS's Debian release from build metadata and picks the matching Ubuntu runner for `build.yml` |
| `.github/scripts/sync-build-defaults.sh` | Auto-bump helper — rewrites `build.yml`'s `workflow_dispatch` defaults to match the latest tracked combination |

See [docs/build.md](build.md) and [docs/architecture.md](architecture.md) for how these fit into the build / version-tracking pipeline.


## Troubleshooting

See [troubleshooting.md](troubleshooting.md) for recovery from
kernel-mismatch errors after TrueNAS upgrades.
