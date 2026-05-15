# Building Sysexts for TrueNAS SCALE: A Community Guide

A practical guide for building, shipping, and maintaining systemd-sysext packages on TrueNAS SCALE. Based on what the TrueNAS sysext community has learned so far.

> **Note:** TrueNAS does not publish official documentation for building custom sysexts. This guide fills that gap with community-sourced knowledge. For official TrueNAS documentation on related topics, see:
> - [Developer Mode (Unsupported)](https://www.truenas.com/docs/scale/scaletutorials/systemsettings/advanced/developermode/) -- covers `systemd-sysext unmerge` and enabling dev tools
> - [Managing Init/Shutdown Scripts](https://www.truenas.com/docs/scale/scaletutorials/systemsettings/advanced/manageinitshutdownscale/) -- covers the PREINIT/POSTINIT mechanism via the TrueNAS UI
> - [TrueNAS SCALE Documentation Hub](https://www.truenas.com/docs/scale/) -- the main documentation site
>
> For background on the `systemd-sysext` mechanism itself, see the [systemd-sysext man page](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html).

## Who this is for

Anyone building a sysext for TrueNAS SCALE -- whether it's an NVIDIA driver, an AI accelerator, or any other out-of-tree kernel module or userspace component. This guide covers the TrueNAS-specific quirks that differ from standard systemd-sysext usage on other Linux distributions.

## TrueNAS sysext fundamentals

### The activation path

TrueNAS does not use the standard `systemd-sysext merge` path (`/var/lib/extensions/`). The working pattern is:

1. Place `<name>.raw` at `/usr/share/truenas/sysext-extensions/<name>.raw`
2. Symlink into `/run/extensions/<name>.raw`
3. `systemd-sysext refresh`
4. `ldconfig`

The `/run/extensions/` symlink lives on tmpfs and disappears on every reboot. Any persistence mechanism must recreate it.

### The extension-release file

Every sysext must include `usr/lib/extension-release.d/extension-release.<name>`. TrueNAS's own NVIDIA sysext uses `ID=_any`, which allows the sysext to merge regardless of OS version. This is the recommended approach for community sysexts.

### Read-only filesystem constraints

| Path | Writable? | Notes |
|------|-----------|-------|
| `/usr` | No (ZFS readonly) | Temporarily unlockable via `zfs set readonly=off` |
| `/lib` | No | Symlink to `/usr/lib`, on its own readonly ZFS dataset |
| `/lib/modules` | No | Part of the `/lib` dataset |
| `/lib/firmware` | No | Part of the `/lib` dataset |
| `/etc/extensions` | Yes | Symlinks here are picked up by `systemd-sysext` |
| `/run/extensions` | Yes (tmpfs) | Cleared on reboot |
| `/mnt/<pool>` | Yes | ZFS data pools, persistent across updates |

Key implications:

- **Firmware** must go inside the sysext image (merged into `/usr/lib/firmware/` via overlayfs), not placed directly at `/lib/firmware/`.
- **`depmod`** cannot write to `/lib/modules`. If your sysext ships kernel modules that need `modprobe`, you must ship a combined `modules.dep` inside the sysext (see [Kernel module considerations](#kernel-module-considerations)). Alternatively, load modules via `insmod` with absolute paths, which bypasses `modules.dep` entirely.
- **Install scripts** that place files in `/usr` must temporarily unlock the ZFS dataset and re-lock it on exit. Always use a `trap` to restore readonly on exit/signal.

### What sysexts can overlay

Sysexts can only overlay `/usr`. If a driver installer places files in `/etc` (OpenCL vendor configs, Vulkan ICD files, container toolkit configs, systemd units), those files must be remapped into `/usr` paths:

| Original path | Sysext path |
|---------------|-------------|
| `/etc/OpenCL/vendors/` | `/usr/share/OpenCL/vendors/` |
| `/etc/vulkan/icd.d/` | `/usr/share/vulkan/icd.d/` |
| `/etc/nvidia-container-runtime/` | `/usr/share/nvidia-container-runtime/` |
| `/etc/systemd/system/` | `/usr/lib/systemd/system/` |

## Building sysexts

### Extracting kernel headers from TrueNAS

Most sysexts need to compile kernel modules against TrueNAS's kernel headers. The headers are embedded in a double-nested squashfs inside the TrueNAS ISO or `.update` file:

```
TrueNAS ISO / .update file
  -> TrueNAS-SCALE.update (outer squashfs)
    -> rootfs.squashfs (inner squashfs)
      -> usr/src/linux-headers-*
      -> usr/lib/modules/*/
```

Extract them with `unsquashfs` (twice), then compile your module against the extracted headers. This is much faster than rebuilding TrueNAS from source. For a detailed walkthrough of the full `scale-build` approach (which this method replaces), see the [HomeLabProject blog post on building NVIDIA vGPU driver extensions](https://www.homelabproject.cc/posts/truenas/truenas-build-nvidia-vgpu-driver-extensions-systemd-sysext/) and the [CodeZ.one guide on adding drivers to TrueNAS](https://www.codez.one/adding-your-driver-to-truenas/).

**Watch out for kernel version naming.** TrueNAS uses non-standard header package names (e.g., `linux-headers-truenas-production-amd64`) that differ from the actual kernel release string (e.g., `6.12.33-production+truenas`). Always verify the real kernel version from `include/config/kernel.release` or the `/lib/modules/` directory names inside the extracted rootfs. Prefer the "production" variant over "debug" when both exist.

### Assembling the sysext image

Two approaches work well depending on complexity:

**Known-path assembly** (recommended for simple drivers): Your build script explicitly places each file at its expected path in a staging directory, then runs `mksquashfs`. This is auditable and predictable.

**Filesystem-diff assembly** (recommended for complex installers like NVIDIA): Take a snapshot of `/usr` and `/etc` before running the installer, take another snapshot after, and diff to find all new files. This is more robust when the installer produces many files that vary across versions. The diff approach avoids maintaining a file list that goes stale.

Whichever approach you use:

```bash
# Create the sysext image
mksquashfs staging/ output.raw -comp zstd -all-root

# Or use gzip to match TrueNAS's own convention
mksquashfs staging/ output.raw -comp gzip -all-root
```

The `-all-root` flag prevents your build user's UID from leaking into the squashfs.

### Kernel module considerations

**The modules.dep problem.** When a sysext containing kernel modules is merged, the overlayfs replaces the *entire* `/usr/lib/modules/<kver>/` directory -- including `modules.dep`, `modules.alias`, and other index files. If your sysext ships only your driver's modules and module index, `modprobe` will no longer find *any* of the base system's kernel modules. This breaks Docker networking, iptables, NFS, and other critical subsystems.

Two solutions:

1. **Ship a combined modules.dep.** Extract the base system's full module tree (from the TrueNAS rootfs squashfs or the `linux-image` deb), copy your compiled `.ko` files into it, run `depmod` against the merged tree, and include the resulting index files in your sysext. This is the recommended approach when your module will be loaded via `modprobe`.

2. **Use `insmod` instead of `modprobe`.** If your sysext adds a single module with no in-tree dependencies, you can skip `modules.dep` entirely and load via `insmod /path/to/module.ko`. This is simpler but only works for standalone modules.

### CI runner selection

TrueNAS is based on Debian. The kernel modules you compile must be linked against a compatible GLIBC. When building on GitHub Actions:

- TrueNAS based on Debian Bookworm: use `ubuntu-22.04`
- TrueNAS based on Debian Trixie: use `ubuntu-24.04`

You can resolve this dynamically by fetching TrueNAS's GITMANIFEST for the target version, reading the Debian release, and mapping to a runner. Hard-coding a runner works but will silently break when TrueNAS rebases to a new Debian.

### Compiler compatibility

Newer TrueNAS kernels may use build flags that older GCC versions don't support (e.g., `-fmin-function-alignment=16` requires GCC 14, `-ftrivial-auto-var-init=zero` requires GCC 12+). If the default compiler on your build environment doesn't support the required flags, install a newer GCC and specify it explicitly (e.g., `CC=gcc-14`).

## Installing sysexts on TrueNAS

### Install script best practices

A good install script should:

1. **Auto-detect the TrueNAS version** via `midclt call system.info | jq -r '.version'`
2. **Find the matching release** from your project's releases
3. **Download and verify** the sysext (SHA256 checksum at minimum)
4. **Handle the ZFS readonly dance** with a cleanup trap:
   ```bash
   USR_DATASET="$(zfs list -H -o name /usr)"
   cleanup() { zfs set readonly=on "$USR_DATASET" 2>/dev/null; }
   trap cleanup EXIT
   zfs set readonly=off "$USR_DATASET"
   # ... install operations ...
   zfs set readonly=on "$USR_DATASET"
   ```
5. **Unmerge before writing** -- `systemd-sysext unmerge` before modifying files under `/usr`, because the overlayfs mount can interfere with the ZFS readonly toggle
6. **Backup the original** before replacing any existing sysext
7. **Provide diagnostics on failure** -- if `systemd-sysext merge` fails, dump the host `os-release`, the sysext's `extension-release.*`, and `systemd-sysext status`

### NVIDIA-specific: toggle via middleware

When replacing TrueNAS's stock `nvidia.raw`, always toggle NVIDIA support through the middleware API:

```bash
# Before swapping
midclt call docker.update '{"nvidia": false}'

# ... swap the sysext ...

# After swapping
midclt call docker.update '{"nvidia": true}'
```

Skipping this can leave Docker in a bad state where it references a driver that's been unmerged.

## Surviving reboots and TrueNAS updates

TrueNAS updates replace the rootfs, wiping everything in `/usr`. Any sysext placed there is gone. If your project doesn't handle persistence, it will silently break after every OS update.

### The PREINIT + pool backup pattern

This is the approach most community projects have settled on:

1. **At install time**, copy the sysext to a ZFS data pool:
   ```
   /mnt/<pool>/.config/<your-project>/your-sysext.raw
   ```

2. **Register a PREINIT script** via TrueNAS middleware:
   ```bash
   midclt call initshutdownscript.create '{
     "type": "COMMAND",
     "command": "/mnt/<pool>/.config/<your-project>/preinit.sh",
     "when": "PREINIT",
     "enabled": true,
     "comment": "Load <your-project> sysext"
   }'
   ```

3. **The PREINIT script** runs on every boot (after ZFS pools mount, before apps start):
   - Compares SHA256 of the installed sysext vs the pool backup
   - If different (TrueNAS updated and restored the stock version): temporarily makes `/usr` writable, copies from backup, restores readonly
   - Creates the `/run/extensions/` symlink (always needed -- tmpfs is wiped on reboot)
   - Runs `systemd-sysext refresh` + `ldconfig`
   - Loads kernel modules

The PREINIT DB entry itself survives TrueNAS updates because it's stored in the middleware database, not on the filesystem.

### Why PREINIT and not POSTINIT

PREINIT runs after ZFS pools are mounted but before the middleware starts apps. POSTINIT runs after the middleware is up, by which time app containers may already be starting. For device drivers that apps depend on (Frigate needs Hailo/Coral, Plex needs NVIDIA), PREINIT is the only safe timing.

### Why not systemd WantedBy

Sysext-shipped systemd units with `[Install] WantedBy=multi-user.target` are silently skipped at boot on TrueNAS. No journal entries, no errors. The reliable pattern is the PREINIT approach described above, which calls `systemctl start <unit>` explicitly.

For more on configuring PREINIT/POSTINIT scripts via the TrueNAS UI (rather than `midclt`), see the official [Init/Shutdown Scripts documentation](https://www.truenas.com/docs/scale/scaletutorials/systemsettings/advanced/manageinitshutdownscale/).

### Pool auto-detection

Install scripts should auto-detect the right ZFS data pool for persistent storage. A good detection order:

1. Explicit user flag (`--pool=NAME` or `--persist-path=PATH`)
2. Existing config directory (if upgrading an existing install)
3. Single data pool (if only one exists, use it)
4. Interactive prompt (if multiple pools exist)

## Version management

### Tracking upstream versions

A sysext project typically tracks two upstream sources: the TrueNAS version (which determines the kernel) and the driver version. Keeping these up to date manually is a common maintenance burden.

The recommended approach is an automated check on a schedule (e.g., daily cron via GitHub Actions) that:

1. Queries the upstream source for new versions
2. Gates on actual availability (e.g., wait for the TrueNAS ISO to be published, not just the tag)
3. Respects consumer constraints (e.g., don't bump a driver past the version pinned by the app that consumes it)
4. Updates a single source-of-truth file and triggers a build

### Single source of truth

Keep all tracked versions in one file (e.g., `.github/tracked-versions.json`) rather than scattered across multiple files (version, train, .gitmodules, workflow defaults). Multiple files that must be updated in lockstep inevitably drift.

## Release strategy

### Tagged releases with version encoding

Encode both the TrueNAS version and the driver version in the release tag:

```
v<truenas-version>-<driver><driver-version>
```

This makes it immediately clear what each release targets, and allows install scripts to find matching releases via the GitHub API.

### Self-contained releases

Each release should carry everything needed for installation. An install script downloading a release should not need to also consult files on the `main` branch. Include:

- The sysext `.raw` image
- Checksum files (`.sha256`)
- The install script itself (as a release asset)
- Any metadata the install script needs (e.g., firmware checksums)

### Human-gated promotion

For sysexts that ship kernel modules, consider separating "build" from "promote":

1. Automated builds publish a release but do NOT mark it as "Latest"
2. A human verifies the build on real hardware
3. The human promotes to "Latest" via the GitHub UI

This prevents an automated build from pushing a broken driver to users who rely on `releases/latest`.

## Ecosystem directory

Community projects building sysexts and drivers for TrueNAS SCALE (as of 2026-05-15):

### truenas-community-sysexts org

| Repo | Hardware | Description |
|------|----------|-------------|
| [hailo8-support](https://github.com/truenas-community-sysexts/hailo8-support) | Hailo-8 AI accelerator | Sysext driver package with automated version tracking and CI/CD |
| [nvidia-mig-support](https://github.com/truenas-community-sysexts/nvidia-mig-support) | NVIDIA MIG (RTX PRO 6000 Blackwell) | Lightweight MIG-only sysext and optional full-driver replacement |

### NVIDIA GPU driver sysexts

| Repo | Description |
|------|-------------|
| [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers) | Legacy GPU driver build framework with pre-built artifacts. Covers GTX 700/900/10-series, Quadro M/P, Tesla M/P. |
| [biohazardious/truenas-nvidia-driver-updater](https://github.com/biohazardious/truenas-nvidia-driver-updater) | Docker-automated sysext builder for any NVIDIA driver version. Uses the filesystem-diff assembly approach. |
| [binary-person/truenas-nvidia-raw-builder](https://github.com/binary-person/truenas-nvidia-raw-builder) | Interactive install script with pre-built releases covering multiple TrueNAS and NVIDIA version combinations. |
| [oxc/truenas-nvidia-legacy](https://github.com/oxc/truenas-nvidia-legacy) | Clean Dockerfile-based legacy driver builder with thorough depmod handling. |
| [Renari/truenas-legacy-nvidia-driver](https://github.com/Renari/truenas-legacy-nvidia-driver) | Minimal wrapper around truenas/scale-build for producing legacy nvidia.raw via CI. |
| [jbaznik/truenas-nvidia-drivers](https://github.com/jbaznik/truenas-nvidia-drivers) | Early legacy driver project with pre-built artifacts. |

### Other driver projects

| Repo | Hardware | Description |
|------|----------|-------------|
| [cbetti/truenas-coral-pcie-driver-helper](https://github.com/cbetti/truenas-coral-pcie-driver-helper) | Google Coral Edge TPU (PCIe/M.2) | DKMS-based driver build scripts (not sysext). Excellent documentation of TrueNAS-specific DKMS quirks. |

## Further reading

- [TrueNAS Developer Mode (Unsupported)](https://www.truenas.com/docs/scale/scaletutorials/systemsettings/advanced/developermode/) -- official docs on `systemd-sysext unmerge` and enabling dev tools
- [Managing Init/Shutdown Scripts](https://www.truenas.com/docs/scale/scaletutorials/systemsettings/advanced/manageinitshutdownscale/) -- official docs on PREINIT/POSTINIT via the UI
- [HomeLabProject: TrueNAS Build Nvidia vGPU Driver extensions (systemd-sysext)](https://www.homelabproject.cc/posts/truenas/truenas-build-nvidia-vgpu-driver-extensions-systemd-sysext/) -- detailed walkthrough of building sysexts via `scale-build`
- [CodeZ.one: Adding your driver to TrueNAS](https://www.codez.one/adding-your-driver-to-truenas/) -- walkthrough of the sysext directory structure and extension-release file
- [NVIDIA Kernel Module Change in TrueNAS 25.10](https://forums.truenas.com/t/nvidia-kernel-module-change-in-truenas-25-10-what-this-means-for-you/51070) -- TrueNAS forum thread where much of the community sysext work was discussed
- [systemd-sysext man page](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html) -- upstream documentation for the `systemd-sysext` mechanism
- [truenas/scale-build](https://github.com/truenas/scale-build) -- the official TrueNAS SCALE build system, including the `NvidiaExtension` class that produces the stock `nvidia.raw`

## Contributing

This guide is a living document. If you've discovered a TrueNAS sysext pattern that should be documented here, or if something in this guide is wrong or outdated, please open an issue or PR.
