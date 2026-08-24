#!/usr/bin/env bash
# Build + configure the rootfs tree and generate the UBIFS/UBI images. Run by
# build.sh under a single `fakeroot` session (so file ownership recorded into
# the image is root:root throughout). All inputs arrive as exported environment
# variables (APK_STATIC, KEYS, ROOT, repos, STAGE, ROOT_HASH, the mtd tools, the image
# paths, and the NAND/UBI geometry); see build.sh for their definitions.
set -euo pipefail

# Fail loudly at the seam if build.sh's export list ever drifts from what this script reads.
# Without this, a missing input surfaces as a bare "unbound variable" deep inside the build
# under `set -u`, with no name. Each entry here is a variable build.sh must export non-empty;
# keep this list in step with that export. MODULES_STAGE and the ML_* identity vars are
# deliberately absent: they are read with defaults (${VAR:-...}) and may legitimately be empty.
: "${APK_STATIC:?}" "${KEYS:?}" "${ROOT:?}" "${MAIN_REPO:?}" "${COMMUNITY_REPO:?}" \
  "${PACKAGES:?}" "${STAGE:?}" "${ROOT_HASH:?}" "${MKFS_UBIFS:?}" "${UBINIZE:?}" \
  "${UBIFS_IMG:?}" "${UBI_IMG:?}" "${UBINIZE_CFG:?}" "${MIN_IO:?}" "${LEB_SIZE:?}" \
  "${MAX_LEB_COUNT:?}" "${PEB_SIZE:?}" "${SUBPAGE:?}" "${FLAVOR:?}" "${DEV:?}"

rm -rf "$ROOT"
mkdir -p "$ROOT"

# Build the rootfs from scratch. --usermode lets apk run as the (faked) root user;
# --no-scripts skips aarch64 post-install scripts that cannot run on the x86_64 host.
# shellcheck disable=SC2086  # $PACKAGES is a space-separated list and must word-split
"$APK_STATIC" --root "$ROOT" --arch aarch64 --keys-dir "$KEYS" \
  --repository "$MAIN_REPO" --repository "$COMMUNITY_REPO" \
  --initdb --no-scripts --usermode --update-cache \
  add $PACKAGES >&2

# busybox applet symlinks. --no-scripts skipped busybox's post-install (which runs
# `busybox --install -s`), so /sbin/init, /bin/ls, /bin/sh etc. would all be missing -
# the kernel could not even find init. Recreate them from the target busybox's own
# applet table (read via qemu, since it is an aarch64 binary), placing each at its real
# path and skipping any a package already provides (e.g. iproute2's /sbin/ip, /bin/ip).
# QEMU_LD_PREFIX points qemu at the rootfs so it finds busybox's musl loader + libs;
# LD_PRELOAD= drops fakeroot's x86_64 preload, which otherwise gets injected into the
# emulated aarch64 process and fails to relocate (this listing needs no fakeroot).
# shellcheck disable=SC1007  # LD_PRELOAD= is a deliberate empty override for this one command
LD_PRELOAD= QEMU_LD_PREFIX="$ROOT" qemu-aarch64-static "$ROOT/bin/busybox" --list-full | while read -r path; do
  [ -n "$path" ] && [ "$path" != "bin/busybox" ] || continue
  mkdir -p "$ROOT/$(dirname "$path")"
  [ -e "$ROOT/$path" ] || ln -sf /bin/busybox "$ROOT/$path"
done

# Drop the overlay in.
cp -a "$STAGE/." "$ROOT/"
mkdir -p "$ROOT/sys/kernel/config" "$ROOT/proc" "$ROOT/dev" "$ROOT/run" "$ROOT/etc/dropbear"
chmod 0700 "$ROOT/etc/dropbear"

# Place the whitelisted kernel modules (built + depmod'd by kernel/modules/build.sh) at
# /lib/modules/$KVER/. Placed only, NOT auto-loaded: no modules-load.d entry, no rc
# service enabling them - load manually with insmod/modprobe once booted.
if [ -n "${MODULES_STAGE:-}" ] && [ -d "$MODULES_STAGE/lib/modules" ]; then
  mkdir -p "$ROOT/lib/modules"
  cp -a "$MODULES_STAGE/lib/modules/." "$ROOT/lib/modules/"
fi

# Set the root password hash in /etc/shadow (replace the root line).
sed -i "s|^root:[^:]*:|root:${ROOT_HASH//|/\\|}:|" "$ROOT/etc/shadow"

# Record the build flavor (dev|slim) so on-device tooling (ml-info, the login banner)
# can report which image is running.
echo "${FLAVOR:-dev}" > "$ROOT/etc/ml-flavor"

# Record the image identity in an os-release-style /etc/ml-release: the open firmware
# version (mirrors the mlimg bundle label), the kernel version, the rootfs/kernel
# git-describes, the build time, flavor, and target device. Read-only like the rest of the
# rootfs; answers "what image is this" from inside the slot (ml-info, the CLI, the boot
# service that self-heals the per-unit device record).
cat > "$ROOT/etc/ml-release" <<EOF
ML_NAME="MissingLynk open firmware"
ML_VERSION="${ML_VERSION:-dev}"
ML_FLAVOR="${FLAVOR:-dev}"
ML_DEVICE="${DEV:-}"
ML_KERNEL_VERSION="${ML_KERNEL_VERSION:-}"
ML_KERNEL_GIT="${ML_KERNEL_GIT:-}"
ML_ROOTFS_GIT="${ML_ROOTFS_GIT:-}"
ML_BUILD_TIME="${ML_BUILD_TIME:-}"
EOF

# Enable services by symlinking each into its runlevel. Membership is all that is set
# here; run ORDER comes from each init script's own depend() (`after ...`), so the two
# lists below are grouped for reading, not sequenced. A service is enabled only when its
# init script is present, so a device overlay that omits one (e.g. the air unit has no
# ml-display, the goggle no ml-air-camera) simply never enables it. boot holds bring-up
# that later services depend on (net, coldplug, the usr_data store, the panel); default
# holds the login shell and the media/RF daemons.
enable_service() {
  local runlevel="$1"
  local service="$2"

  if [ ! -e "$ROOT/etc/init.d/$service" ]; then
    return 0
  fi

  ln -sf "/etc/init.d/$service" "$ROOT/etc/runlevels/$runlevel/$service"
}

enable_services() {
  local runlevel="$1"
  shift

  local service
  for service in "$@"; do
    enable_service "$runlevel" "$service"
  done
}

# The stock early services (devfs/procfs/sysfs/hostname/bootmisc/sysctl/localmount) bring up
# /proc, /sys, /dev, the hostname and the fstab mounts; sysctl applies /etc/sysctl.d/*.conf,
# including 99-panic-reboot.conf (auto-reboot on crash).
BOOT_SERVICES="
  devfs procfs sysfs hostname bootmisc sysctl localmount
  usb-gadget hwclock
  mdev hwdrivers modules
  ml-hotplugd ml-usrdata ml-ledd ml-display
"

DEFAULT_SERVICES="
  dropbear ntp-oneshot
  ml-chime ml-sdcard ml-hud ml-logd ml-watchdog ml-video
  ml-air-link ml-air-camera ml-air-ae
  ml-boot-record ml-pstore
"

# shellcheck disable=SC2086  # both lists are space/newline-separated and must word-split
enable_services boot $BOOT_SERVICES
# shellcheck disable=SC2086  # see above
enable_services default $DEFAULT_SERVICES

# ml-sdmount and ml-sdformat source their card selection from this library. Without it the mount
# fails at boot and the format aborts with an unbound function, so a missing file must fail the
# build rather than ship an image whose SD card never appears.
[ -f "$ROOT/usr/local/lib/ml-sd.sh" ] || { echo "make-rootfs: /usr/local/lib/ml-sd.sh missing from the overlay" >&2; exit 1; }

# Automount the microSD card on insert/remove. The SD controller has a native card-detect line, so the
# kernel fires mmcblk hotplug uevents; the stock mdev.conf only runs persistent-storage on them (no
# mount). busybox mdev uses the first matching rule, so an mmcblk hook is inserted ahead of the stock
# rule; ml-sdmount (the * prefix runs it on both add and remove) reconciles /mnt/sdcard each event.
if [ -e "$ROOT/etc/mdev.conf" ] && ! grep -q ml-sdmount "$ROOT/etc/mdev.conf"; then
  grep -q '^mmcblk\.\*' "$ROOT/etc/mdev.conf" || { echo "make-rootfs: mdev.conf mmcblk rule not found" >&2; exit 1; }
  sed -i '/^mmcblk\.\*/i mmcblk[0-9].* root:disk 0660 */usr/local/bin/ml-sdmount' "$ROOT/etc/mdev.conf"
fi

# OpenRC silently skips a non-executable init script (a stripped exec bit -> the service
# never runs and boot looks fine); force +x on every init script so that can't happen.
chmod +x "$ROOT"/etc/init.d/* 2>/dev/null || true

# Same trap for the helper scripts/binaries: start-stop-daemon --exec cannot run a non-executable
# file, and OpenRC still reports the service "started" (the exec fails in the backgrounded child).
# Force +x on everything under /usr/local/bin so a 644 helper can't silently no-op a service.
chmod +x "$ROOT"/usr/local/bin/* 2>/dev/null || true

# Drop the apk index cache (--update-cache populated it, ~3 MB of APKINDEX). Build-only; on this
# near-full NAND every megabyte in the image counts.
rm -rf "$ROOT"/var/cache/apk/* "$ROOT"/etc/apk/cache 2>/dev/null || true

# mkfs.ubifs (run as non-root via fakeroot) cannot read execute-only files. The only
# one is busybox's setuid helper (bbsuid, mode 0111), unused on this root-only dev box;
# make it readable so it goes into the image.
find "$ROOT" -type f ! -readable -exec chmod u+r {} +

# Build the UBIFS image (no compression: no kernel decompressor dependency).
"$MKFS_UBIFS" -m "$MIN_IO" -e "$LEB_SIZE" -c "$MAX_LEB_COUNT" -x none \
  -o "$UBIFS_IMG" -d "$ROOT" >&2

# Wrap in a UBI image with an autoresize volume named "rootfs".
"$UBINIZE" -o "$UBI_IMG" -m "$MIN_IO" -p "$PEB_SIZE" -s "$SUBPAGE" "$UBINIZE_CFG" >&2
