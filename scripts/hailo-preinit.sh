#!/usr/bin/env bash
# TrueNAS PREINIT script: activates hailo.raw sysext on every boot.
# Runs before middleware starts, so the Hailo device is ready before
# app containers (e.g., Frigate) launch.
#
# Stored on persistent pool; registered via midclt during install.
# Idempotent — safe to run on every boot.
#
# The hailo.raw squashfs contains firmware (injected at install time),
# so restoring the sysext also restores firmware. No separate firmware
# handling is needed.

set -uo pipefail

log() {
    echo "[hailo-preinit] $*"
    logger -t hailo-preinit "$*" 2>/dev/null || true
}

# USR_WAS_WRITABLE: 1 while we have ${USR_DATASET}'s readonly=off and
# haven't restored it yet. Mirrors install.sh / restore.sh: a SIGINT/SIGTERM
# (or unexpected error path) between off and on must not leave /usr writable
# until reboot.
USR_WAS_WRITABLE=0
USR_DATASET=""

restore_usr_readonly() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
}
trap restore_usr_readonly EXIT INT TERM

# --- Find persistent config via glob ---
PERSIST_DIR=""
for d in /mnt/*/.config/hailo; do
    [ -d "$d" ] && PERSIST_DIR="$d" && break
done

if [ -z "$PERSIST_DIR" ]; then
    log "No persistent config found at /mnt/*/.config/hailo/, nothing to do"
    exit 0
fi

HAILO_RAW_BACKUP="${PERSIST_DIR}/hailo.raw"
SYSEXT_TARGET="/usr/share/truenas/sysext-extensions/hailo.raw"

# --- Determine source repo (for error messages pointing users at releases) ---
# Written at install time by install.sh. Falls back to this fork to match
# install.sh's default — error messages for an install with no .hailo-repo
# marker point at the same releases page the install came from. The
# upstream-pr/* branches override this default back to scyto/truenas-hailo.
HAILO_REPO_FILE="${PERSIST_DIR}/.hailo-repo"
if [ -f "$HAILO_REPO_FILE" ]; then
    HAILO_REPO=$(tr -d '[:space:]' < "$HAILO_REPO_FILE")
fi
HAILO_REPO="${HAILO_REPO:-andretakagi/truenas-hailo}"

if [ ! -f "$HAILO_RAW_BACKUP" ]; then
    log "No hailo.raw backup at ${HAILO_RAW_BACKUP}, nothing to do"
    exit 0
fi

# --- Compare checksums and reinstall if needed ---
# Empty hashes mean sha256sum couldn't read one of the files (rare: ZFS
# read error, pool flapping at PREINIT, /usr overlay weirdness). Treating
# two empty strings as equal would log "matches backup, skipping copy" and
# silently leave a possibly-broken installed sysext active. Require both
# hashes to be non-empty before declaring a match; otherwise reinstall
# defensively from the backup.
NEED_COPY=true
if [ -f "$SYSEXT_TARGET" ]; then
    INSTALLED_SUM=$(sha256sum "$SYSEXT_TARGET" | awk '{print $1}')
    BACKUP_SUM=$(sha256sum "$HAILO_RAW_BACKUP" | awk '{print $1}')
    if [ -z "$INSTALLED_SUM" ] || [ -z "$BACKUP_SUM" ]; then
        log "WARNING: failed to read sha256 (installed='${INSTALLED_SUM}', backup='${BACKUP_SUM}'); reinstalling defensively"
    elif [ "$INSTALLED_SUM" = "$BACKUP_SUM" ]; then
        log "hailo.raw already matches backup, skipping copy"
        NEED_COPY=false
    else
        log "hailo.raw differs from backup (update detected), reinstalling..."
    fi
else
    log "hailo.raw missing, installing from backup..."
fi

if [ "$NEED_COPY" = true ]; then
    log "Removing old hailo sysext..."
    rm -f /run/extensions/hailo.raw
    systemd-sysext unmerge 2>/dev/null || true

    log "Making /usr writable..."
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=off "$USR_DATASET"
        USR_WAS_WRITABLE=1
    fi

    log "Copying hailo.raw from backup..."
    if ! cp "$HAILO_RAW_BACKUP" "$SYSEXT_TARGET"; then
        log "ERROR: Failed to copy hailo.raw from backup"
        # Trap will re-assert readonly=on; leave the cleanup to it so the
        # path is identical whether we error out here or get signalled.
        exit 1
    fi

    if [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET"
        USR_WAS_WRITABLE=0
    fi
fi

# --- Always activate sysext (symlink is on tmpfs, gone after reboot) ---
log "Activating hailo sysext..."
mkdir -p /run/extensions
ln -sf "$SYSEXT_TARGET" /run/extensions/hailo.raw
systemd-sysext refresh
ldconfig

# --- Check kernel version matches the module in the sysext ---
HAILO_KO="/usr/lib/modules/$(uname -r)/extra/hailo_pci.ko"
if [ -f "$HAILO_KO" ]; then
    log "Loading Hailo module..."
    insmod "$HAILO_KO" || log "WARNING: insmod hailo_pci failed (device may not be present)"
else
    # Module path doesn't match running kernel — likely a TrueNAS update changed the kernel.
    # Identify the sysext's kernel by looking for the actual hailo_pci.ko under
    # /usr/lib/modules/*/extra/ rather than picking the first non-running directory:
    # after multiple TrueNAS upgrades several kernel dirs can coexist there, and
    # whichever sorts earliest may not be the one the sysext was built for.
    SYSEXT_KVER=""
    running_kver=$(uname -r)
    for d in /usr/lib/modules/*/; do
        [ -d "$d" ] || continue
        name=${d%/}
        name=${name##*/}
        if [ "$name" != "$running_kver" ] && [ -f "${d}extra/hailo_pci.ko" ]; then
            SYSEXT_KVER="$name"
            break
        fi
    done
    if [ -n "$SYSEXT_KVER" ]; then
        log "ERROR: Kernel version mismatch — running ${running_kver} but sysext has module for ${SYSEXT_KVER}"
        log "ERROR: TrueNAS was likely updated. Download a new hailo.raw release matching ${running_kver}"
        log "ERROR: Visit https://github.com/${HAILO_REPO}/releases"
    else
        log "WARNING: hailo_pci.ko not found at ${HAILO_KO}"
    fi
fi

# --- Reload udev rules from sysext so /dev/hailo0 gets correct permissions ---
log "Reloading udev rules..."
udevadm control --reload-rules 2>/dev/null || true
if [ -e /dev/hailo0 ]; then
    udevadm trigger /dev/hailo0 2>/dev/null || true
fi

log "Done"
exit 0
