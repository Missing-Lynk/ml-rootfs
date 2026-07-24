#!/usr/bin/env bash
# Build + configure the rootfs tree and generate the UBIFS/UBI images. Run by
# build.sh under a single `fakeroot` session (so file ownership recorded into
# the image is root:root throughout). All inputs arrive as exported environment
# variables (APK_STATIC, KEYS, ROOT, repos, STAGE, ROOT_HASH, the mtd tools, the image
# paths, and the NAND/UBI geometry); see build.sh for their definitions.
set -euo pipefail

rm -rf "$ROOT"
mkdir -p "$ROOT"

# Build the rootfs from scratch. --usermode lets apk run as the (faked) root user;
# --no-scripts skips aarch64 post-install scripts that cannot run on the x86_64 host.
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

# Enable services: gadget (provides net) in boot, dropbear + best-effort NTP in default.
# The device has a battery-backed RTC, so the openrc `hwclock` service (boot runlevel)
# loads it into the system clock at boot and writes it back at shutdown; ntp-oneshot then
# corrects RTC drift when online and is a no-op offline (safe in both flavors).
ln -sf /etc/init.d/usb-gadget "$ROOT/etc/runlevels/boot/usb-gadget"
ln -sf /etc/init.d/dropbear   "$ROOT/etc/runlevels/default/dropbear"
[ -e "$ROOT/etc/init.d/hwclock" ]     && ln -sf /etc/init.d/hwclock     "$ROOT/etc/runlevels/boot/hwclock"
[ -e "$ROOT/etc/init.d/ntp-oneshot" ] && ln -sf /etc/init.d/ntp-oneshot "$ROOT/etc/runlevels/default/ntp-oneshot"

# DT coldplug, the single module path for both flavors. mdev + hwdrivers autoload every driver with
# a DT node (display, buttons, buzzer, temp, GPIO, wave5, SD); modules force-loads the ones without a
# DT node or needing params (/etc/modules-load.d/ml.conf: OSD framebuffer, SDIO/SD overlay, DSI
# panel), ordered before hwdrivers. /etc/modprobe.d/ml.conf blacklists the MPP-legacy + RF drivers.
# The ml-* services order after this and load no modules.
for svc in mdev hwdrivers modules; do
  [ -e "$ROOT/etc/init.d/$svc" ] && ln -sf "/etc/init.d/$svc" "$ROOT/etc/runlevels/boot/$svc"
done

# Runtime hotplug: the mainline kernel has no CONFIG_UEVENT_HELPER, so the mdev service's
# /proc/sys/kernel/hotplug helper never fires. ml-hotplugd runs `mdev -d` (netlink daemon) so post-boot
# device events (notably SD-card insert/remove -> the mmcblk mdev rule -> ml-sdmount) are handled.
if [ -e "$ROOT/etc/init.d/ml-hotplugd" ]; then
  ln -sf /etc/init.d/ml-hotplugd "$ROOT/etc/runlevels/boot/ml-hotplugd"
fi

# /usrdata (the usr_data UBI volume), in the boot runlevel ahead of every ml-* service: it is the
# only persistent store, so the HUD's settings and the RF band marker are unreadable without it.
# The kernel attaches only the rootfs UBI from the bootargs, so this service attaches usr_data too.
if [ -e "$ROOT/etc/init.d/ml-usrdata" ]; then
  ln -sf /etc/init.d/ml-usrdata "$ROOT/etc/runlevels/boot/ml-usrdata"
fi

# Status LED indicator, in the boot runlevel (earlier than the default-runlevel ml-* daemons) so
# breathe-red is one of the first signs of life. `after devfs` is enough: it needs only /run
# (sysinit) and /dev/spidev* (built-in SPI, present once devtmpfs mounts). Best-effort, backgrounded.
if [ -e "$ROOT/etc/init.d/ml-ledd" ]; then
  ln -sf /etc/init.d/ml-ledd "$ROOT/etc/runlevels/boot/ml-ledd"
fi

# A short power-on buzzer chime, ordered after the coldplug (hwdrivers) that binds artosyn_pwm,
# so the PWM sysfs is ready. Best-effort and backgrounded; never blocks boot.
if [ -e "$ROOT/etc/init.d/ml-chime" ]; then
  ln -sf /etc/init.d/ml-chime "$ROOT/etc/runlevels/default/ml-chime"
fi

# Display bring-up + boot splash, in the boot runlevel ordered after the coldplug (hwdrivers) that
# binds VO/DSI/panel and creates card0 (~5 s). Painting the splash here rather than in the default
# runlevel (~12 s) makes the panel's first modeset, and so its first light, happen ~7 s earlier; until
# then the backlit panel is black. Best-effort; a missing broker/splash/asset only logs a warning.
if [ -e "$ROOT/etc/init.d/ml-display" ]; then
  ln -sf /etc/init.d/ml-display "$ROOT/etc/runlevels/boot/ml-display"
fi

# SD card mount at /mnt/sdcard, ordered after coldplug and before ml-hud.
if [ -e "$ROOT/etc/init.d/ml-sdcard" ]; then
  ln -sf /etc/init.d/ml-sdcard "$ROOT/etc/runlevels/default/ml-sdcard"
fi

# Automount the microSD card on insert/remove. The SD controller has a native card-detect line, so the
# kernel fires mmcblk hotplug uevents; the stock mdev.conf only runs persistent-storage on them (no
# mount). busybox mdev uses the first matching rule, so an mmcblk hook is inserted ahead of the stock
# rule; ml-sdmount (the * prefix runs it on both add and remove) reconciles /mnt/sdcard each event.
if [ -e "$ROOT/etc/mdev.conf" ] && ! grep -q ml-sdmount "$ROOT/etc/mdev.conf"; then
  grep -q '^mmcblk\.\*' "$ROOT/etc/mdev.conf" || { echo "make-rootfs: mdev.conf mmcblk rule not found" >&2; exit 1; }
  sed -i '/^mmcblk\.\*/i mmcblk[0-9].* root:disk 0660 */usr/local/bin/ml-sdmount' "$ROOT/etc/mdev.conf"
fi

# HUD autostart, ordered after ml-display (DRM broker + modeset).
if [ -e "$ROOT/etc/init.d/ml-hud" ]; then
  ln -sf /etc/init.d/ml-hud "$ROOT/etc/runlevels/default/ml-hud"
fi

# Session logger, ordered after ml-sdcard (needs /mnt/sdcard); skips cleanly if the card is absent.
if [ -e "$ROOT/etc/init.d/ml-logd" ]; then
  ln -sf /etc/init.d/ml-logd "$ROOT/etc/runlevels/default/ml-logd"
fi

# RF video autostart: AR8030 bring-up + ml-linkd + ml-pipeline, ordered after ml-display.
if [ -e "$ROOT/etc/init.d/ml-video" ]; then
  ln -sf /etc/init.d/ml-video "$ROOT/etc/runlevels/default/ml-video"
fi

# Air-unit RF link autostart: ml-linkd in air (TX) role for telemetry. Present only in the air
# device overlay (the goggle uses ml-video instead), so this enables nothing on the goggle.
if [ -e "$ROOT/etc/init.d/ml-air-link" ]; then
  ln -sf /etc/init.d/ml-air-link "$ROOT/etc/runlevels/default/ml-air-link"
fi

# Boot-count recorder, ordered after the usable-unit services (its depend()); marks a healthy boot
# in the per-unit device record. Best-effort; skips cleanly if /usrdata or the binary is absent.
if [ -e "$ROOT/etc/init.d/ml-boot-record" ]; then
  ln -sf /etc/init.d/ml-boot-record "$ROOT/etc/runlevels/default/ml-boot-record"
fi

# OpenRC silently skips a non-executable init script (a stripped exec bit -> the service
# never runs and boot looks fine); force +x on every init script so that can't happen.
chmod +x "$ROOT"/etc/init.d/* 2>/dev/null || true

# Same trap for the helper scripts/binaries: start-stop-daemon --exec cannot run a non-executable
# file, and OpenRC still reports the service "started" (the exec fails in the backgrounded child).
# Force +x on everything under /usr/local/bin so a 644 helper can't silently no-op a service.
chmod +x "$ROOT"/usr/local/bin/* 2>/dev/null || true

# Standard early services so /proc, /sys, /dev, hostname, fstab mounts come up.
# `sysctl` applies /etc/sysctl.d/*.conf (incl. our 99-panic-reboot.conf -> auto-reboot on crash).
for svc in devfs procfs sysfs hostname bootmisc sysctl; do
  [ -e "$ROOT/etc/init.d/$svc" ] && ln -sf "/etc/init.d/$svc" "$ROOT/etc/runlevels/boot/$svc"
done
[ -e "$ROOT/etc/init.d/localmount" ] && ln -sf /etc/init.d/localmount "$ROOT/etc/runlevels/boot/localmount"

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
