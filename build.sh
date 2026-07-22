#!/usr/bin/env bash
# Reproducible Alpine aarch64 dev-platform rootfs for the open mainline kernel on Artosyn
# Proxima-class devices (goggles, air units, video receivers). Output is a UBIFS+UBI image
# to flash to the device's NAND partition.
#
# Per-device specifics live in devices/<name>/: board.conf (identity/addressing + NAND geometry)
# and overlay/ (the device-specific OpenRC services + modules-load, layered on the shared
# skeleton/). Arg 1 = the device name; default = the goggle.
#
#   build.sh [<device-name>]          # default: betafpv-vr04-goggle
#
# No root required: the rootfs is built under `fakeroot` (so files are recorded root:root),
# apk-tools-static is run from a local sha-verified extract, and the image is generated
# inside the same fakeroot session so ownership is preserved. mkfs.ubifs/ubinize must be
# installed on the host (mtd-utils); missing tools fail early with a message, they are
# never fetched onto the host by this script.
#
# Re-runnable: re-running rebuilds from the verified downloads (cached in build/dl).
set -euo pipefail

# ======================================================================================
# CONFIG
#
# Per-board identity (hostname, root password), USB addressing and NAND/UBI geometry are
# NOT here: they live in the device profile (devices/*.conf), sourced further down.
# Everything in this section is host/build-wide.
# ======================================================================================

# Package sets. BASE ships in both flavors; dev layers DEV on top. The slim base is
# intentionally tiny - busybox already provides the less/mount/blkid/fdisk/losetup/getty
# applets, so no util-linux and no less package are needed. exfatprogs adds mkfs.exfat
# (busybox has none) for the DVR menu's whole-device exFAT SD format.
BASE_PACKAGES="alpine-base busybox openrc dropbear iproute2 exfatprogs"

# Dev extras: scp/sftp (openssh-sftp-server; dropbear serves the subsystem), the full
# util-linux coreutils (lsblk/findmnt/hexdump/flock), and introspection tooling.
DEV_PACKAGES="openssh-sftp-server util-linux strace tcpdump htop"

# Pinned Alpine inputs. Bump deliberately; the sha256s keep the rootfs reproducible.
ALPINE_BRANCH="v3.24"                  # latest-stable at pin time
ALPINE_VER="3.24.1"
ALPINE_CDN="https://dl-cdn.alpinelinux.org/alpine"
MINIROOTFS_SHA256="f55a90f69052c5bd6f92cb09a8f47065970830b194c917a006fb94028e721259"
APK_TOOLS_VER="3.0.6-r0"
# apk-tools-static sha is pinned for x86_64 build hosts; other host arches skip it.
APK_STATIC_SHA256_x86_64="a62f54609910d1eb23d8ebcf69dd7954280fe76047452bb88410122cbca14a6e"

# Build flavor default: `dev` (full bring-up tooling: scp/sftp, util-linux, strace/
# tcpdump/htop) or `slim` (lean production image, updated by reflash rather than file
# push). Override per run with the env var: `FLAVOR=slim build.sh`.
FLAVOR="${FLAVOR:-dev}"

# ======================================================================================
# CONFIG END
# ======================================================================================

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Sibling userspace repo: the gstreamer/hud/ml-linkd/ml-ledd binaries AND the shared
# assets (splash + OSD font, rendered by ml-splash/ml-hud). Mounted at ../userspace from a
# wrapper checkout; override with US= to point elsewhere. Refs into kernel/firmware/native/
# glue stay at ../ (they sit at the wrapper root).
US="${US:-$HERE/../userspace}"
SCRIPTS="$HERE/scripts"  # build machinery (the fakeroot build body)
SKEL="$HERE/skeleton"    # static rootfs config tree, copied verbatim into the image
OUT="$HERE/build"        # all regenerable output lives here (gitignored)
DL="$OUT/dl"             # cached, verified downloads
WORK="$OUT/work"         # scratch: extracted tools + the staged rootfs tree
ROOT="$WORK/root"        # the target rootfs tree
mkdir -p "$DL" "$WORK"

log() {
  echo "[$(date -u +%H:%M:%S)] $*" >&2
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Validate the flavor (needs die, defined just above).
case "$FLAVOR" in
  dev|slim)
    ;;
  *)
    die "unknown FLAVOR: $FLAVOR (dev|slim)"
    ;;
esac

# Assemble the package list for this flavor.
PACKAGES="$BASE_PACKAGES"
if [ "$FLAVOR" = dev ]; then
  PACKAGES="$PACKAGES $DEV_PACKAGES"
fi

# Alpine repos + build-input URLs, derived from the pinned CONFIG above.
MAIN_REPO="$ALPINE_CDN/$ALPINE_BRANCH/main"
COMMUNITY_REPO="$ALPINE_CDN/$ALPINE_BRANCH/community"

# aarch64 minirootfs: used only as the source of the verified Alpine signing keys (the
# same RSA keys sign every arch); the rootfs itself is built fresh below with apk.static.
MINIROOTFS="alpine-minirootfs-${ALPINE_VER}-aarch64.tar.gz"
MINIROOTFS_URL="$ALPINE_CDN/latest-stable/releases/aarch64/$MINIROOTFS"

# apk-tools-static for the BUILD host (run here with --arch aarch64).
HOST_ARCH="$(uname -m)"
APK_STATIC_PKG="apk-tools-static-${APK_TOOLS_VER}.apk"
APK_STATIC_URL="$MAIN_REPO/$HOST_ARCH/$APK_STATIC_PKG"

# Everything per-device lives in devices/<name>/: board.conf (target identity/addressing + NAND
# geometry) and overlay/ (the device-specific OpenRC services + modules-load, layered on the
# shared skeleton/ below). Arg 1 = the device name; default = the goggle. Same names as the root
# Makefile DEVICE and kernel/devices/<name>/. See plans/device-hal.md.
DEV="${1:-betafpv-vr04-goggle}"
DEVICE_DIR="$HERE/devices/$DEV"
DEVICE_CONF="$DEVICE_DIR/board.conf"
DEVICE_OVERLAY="$DEVICE_DIR/overlay"
[ -f "$DEVICE_CONF" ] || die "device '$DEV': no $DEVICE_CONF (devices/$DEV/board.conf)"
log "device: $DEV ($DEVICE_CONF)"

# shellcheck source=/dev/null
. "$DEVICE_CONF"

# Whitelisted kernel modules (built by kernel/modules/build.sh, which already stages
# only the modules we ship - Artosyn out-of-tree + the in-tree DRM stack - with depmod
# already run). They are placed at /lib/modules/$KVER/ and NOT auto-loaded (no
# modules-load.d entry, no rc service) - load manually with insmod/modprobe once booted.
# Skip silently if that build hasn't been run; the rootfs still builds without them.
# shellcheck source=/dev/null
source "$HERE/../kernel/scripts/pin.env" 2>/dev/null || true
KERNEL_BUILD_DIR="${BUILD_DIR:-$KERNEL_BUILD_DEFAULT}"
MODULES_STAGE="${MODULES_STAGE:-$KERNEL_BUILD_DIR/ml-modules/rootfs}"
if [ -d "$MODULES_STAGE/lib/modules" ]; then
  log "kernel modules: staging from $MODULES_STAGE"
else
  log "kernel modules: none staged at $MODULES_STAGE (build with kernel/modules/build.sh); skipping"
  MODULES_STAGE=""
fi

# Fail early on an incomplete profile rather than midway through the build.
for v in HOSTNAME ROOT_PASS GADGET_IP GADGET_CIDR HOST_GW DEV_MAC HOST_MAC USB_PRODUCT \
         PARTITION PARTITION_PEBS PEB_SIZE MIN_IO SUBPAGE LEB_SIZE MAX_LEB_COUNT; do
  [ -n "${!v:-}" ] || die "device config $DEVICE_CONF: missing $v"
done

# ======================================================================================
# Host tooling: verify what must be installed, then fetch the pinned build inputs
# (apk.static + Alpine keys) into build/dl without touching the system (no root).
# ======================================================================================
command -v fakeroot >/dev/null || die "fakeroot not found"
command -v openssl  >/dev/null || die "openssl not found"
command -v curl     >/dev/null || die "curl not found"
# make-rootfs.sh lists the aarch64 busybox's applets through user-mode qemu.
command -v qemu-aarch64-static >/dev/null || die "qemu-aarch64-static not found - install qemu-user-static"
# mkfs.ubifs + ubinize are deliberately NOT auto-fetched: host tools come from your OS
# package manager; the build only downloads its pinned build inputs (apk.static, keys).
# Debian installs them into /usr/sbin, which is not on a regular user's PATH (they run
# fine unprivileged - they only write image files), so check the sbin dirs too.
find_tool() {  # name -> full path, searching PATH then the sbin dirs
  command -v "$1" 2>/dev/null && return
  local d
  for d in /usr/sbin /sbin /usr/local/sbin; do
    if [ -x "$d/$1" ]; then
      echo "$d/$1"
      return
    fi
  done

  return 1
}
MKFS_UBIFS="$(find_tool mkfs.ubifs || true)"
UBINIZE="$(find_tool ubinize || true)"
[ -n "$MKFS_UBIFS" ] || die "mkfs.ubifs not found - install mtd-utils with your OS package manager"
[ -n "$UBINIZE" ]    || die "ubinize not found - install mtd-utils with your OS package manager"

fetch() {  # url outfile [sha256]
  local url="$1" out="$2" sha="${3:-}"
  if [ -f "$out" ] && [ -n "$sha" ] && echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
    return
  fi

  log "fetch $(basename "$out")"
  curl -fSL "$url" -o "$out.tmp"
  if [ -n "$sha" ]; then
    echo "$sha  $out.tmp" | sha256sum -c - >/dev/null || die "sha256 mismatch for $out"
  fi

  mv "$out.tmp" "$out"
}

# 1. apk-tools-static (host runner).
APK_SHA=""
[ "$HOST_ARCH" = "x86_64" ] && APK_SHA="$APK_STATIC_SHA256_x86_64"
fetch "$APK_STATIC_URL" "$DL/$APK_STATIC_PKG" "$APK_SHA"
APK_STATIC="$WORK/sbin/apk.static"
rm -rf "$WORK/sbin"
mkdir -p "$WORK/sbin"
tar -xzf "$DL/$APK_STATIC_PKG" -C "$WORK" sbin/apk.static 2>/dev/null
[ -x "$APK_STATIC" ] || die "could not extract apk.static"

# 2. Alpine signing keys (from the verified aarch64 minirootfs).
fetch "$MINIROOTFS_URL" "$DL/$MINIROOTFS" "$MINIROOTFS_SHA256"
KEYS="$WORK/keys"
rm -rf "$KEYS"
mkdir -p "$KEYS"
tar -xzf "$DL/$MINIROOTFS" -C "$WORK" ./etc/apk/keys 2>/dev/null
cp "$WORK/etc/apk/keys/"*.rsa.pub "$KEYS/"

# ======================================================================================
# Stage the overlay: the shared base tree from skeleton/, then the device overlay from
# devices/$DEV/overlay/ layered on top (device-specific OpenRC services + modules-load;
# it may add files or override a base file). Then the files that depend on the device/build
# vars, templating the gadget service's addressing. Edit skeleton/ and the device overlay
# directly. make-rootfs.sh enables each ml-* service only if present, so a device that omits
# one (e.g. no ml-display) simply never enables it - no other change needed.
# ======================================================================================
STAGE="$WORK/overlay"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$SKEL/." "$STAGE/"
[ -d "$DEVICE_OVERLAY" ] && cp -a "$DEVICE_OVERLAY/." "$STAGE/"
mkdir -p "$STAGE/etc/apk"

# The proprietary vendor blobs the open stack needs live under firmware/bin/slot-a/
# (git-ignored; repopulate from your own goggle with glue/fetch/fetch-vendor-blobs.sh).
# Each block below stages what is present and skips silently otherwise, so the image
# still builds on a fresh clone - it just lacks that firmware until the blobs are fetched.
VENDOR_BLOBS="$HERE/../firmware/bin/slot-a"

# Codec firmware: the wave5 driver (wave5.ko) request_firmware()s cnm/wave521c_k3_codec_fw.bin
# once loaded. chagall.bin is the proprietary Wave521C VCPU ucode. Install it into the
# overlay if present; the codec module just won't probe until it is provided.
CODEC_FW="$VENDOR_BLOBS/usr/bin/chagall.bin"
if [ -f "$CODEC_FW" ]; then
  mkdir -p "$STAGE/lib/firmware/cnm"
  cp "$CODEC_FW" "$STAGE/lib/firmware/cnm/wave521c_k3_codec_fw.bin"
  log "codec firmware: staged chagall.bin -> /lib/firmware/cnm/wave521c_k3_codec_fw.bin"
else
  log "codec firmware: $CODEC_FW absent; wave5 codec will need it installed on the rootfs"
fi

# RF baseband firmware: the open artosyn_sdio driver request_firmware()s the AR8030
# baseband image + its merged config (insmod fw_name=/cfg_name=), which the ROM loader
# then uploads to the chip. Unlike the vendor's full /lib/firmware, ours has room, so bake
# both blobs in at request_firmware's default search path - then a flashed image needs no
# host push or firmware_class path override to bring RF up. The device reset + insmod
# sequence itself stays in glue/dev/rf-bringup.sh (bring-up is never baked into the image).
RF_FW="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_demo_gnd_d.img"
RF_CFG="$VENDOR_BLOBS/tmp/ar813x/bb_config_gnd.json.usr_cfg.json"
if [ -f "$RF_FW" ] && [ -f "$RF_CFG" ]; then
  mkdir -p "$STAGE/lib/firmware"
  cp "$RF_FW"  "$STAGE/lib/firmware/bb_demo_gnd_d.img"
  cp "$RF_CFG" "$STAGE/lib/firmware/bb_config_gnd.json.usr_cfg.json"

  # The Normal/Race band is the config's chan_valid_bmp, which only enters the chip at firmware
  # upload, so each band is a whole config blob and switching one costs a boot. The captured blob
  # is a race-mode one (0x0007FFF8 = table indices 3..18); derive the normal variant (0x00000007 =
  # 5758/5788/5828) by rewriting that one field. ml-video picks between the two at boot.
  sed 's/"chan_valid_bmp":\([[:space:]]*\)"0x0007FFF8"/"chan_valid_bmp":\1"0x00000007"/I' \
      "$RF_CFG" > "$STAGE/lib/firmware/bb_config_gnd.json.normal_cfg.json"
  if ! grep -qi '"chan_valid_bmp":[[:space:]]*"0x00000007"' \
        "$STAGE/lib/firmware/bb_config_gnd.json.normal_cfg.json"; then
    die "RF firmware: chan_valid_bmp not rewritten in $RF_CFG - normal-band config would be a race blob"
  fi

  log "RF firmware: staged bb_demo_gnd_d.img + race/normal configs -> /lib/firmware/"
else
  log "RF firmware: $RF_FW / $RF_CFG absent; RF bring-up will push them at runtime (glue/dev/rf-bringup.sh -> /run/ml/fw)"
fi

# Display bring-up (the ml-display boot service, in the goggle device overlay): the
# static ml-drmfd DRM-master broker + ml-splash (both built by userspace/gstreamer/src/build.sh)
# and the splash asset (userspace/assets/splash/splash.yuv). Binaries staged if present; the
# service warns and skips at boot otherwise.
DISPLAY_BIN="$US/gstreamer/build/bin"
for b in ml-drmfd ml-splash; do
  if [ -f "$DISPLAY_BIN/$b" ]; then
    mkdir -p "$STAGE/usr/local/bin"
    install -m 0755 "$DISPLAY_BIN/$b" "$STAGE/usr/local/bin/$b"
    log "display: staged $b -> /usr/local/bin/"
  else
    log "display: $DISPLAY_BIN/$b absent (build with userspace/gstreamer/src/build.sh); skipping"
  fi
done
SPLASH="$US/assets/splash/splash.yuv"
if [ -f "$SPLASH" ]; then
  mkdir -p "$STAGE/usr/local/share"
  install -m 0644 "$SPLASH" "$STAGE/usr/local/share/nosignal.yuv"
  log "display: staged splash.yuv -> /usr/local/share/nosignal.yuv"
else
  log "display: $SPLASH absent (ships in userspace/assets/splash); skipping (boot splash will be blank)"
fi

# HUD (ml-hud service): the static menu+OSD binary, its BTFL glyph font, and the i18n catalogs,
# staged to /usr/local/{bin,share}. Skipped if ml-hud/build/hud is absent.
HUD_BIN="$US/ml-hud/build/hud"
if [ -f "$HUD_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin" "$STAGE/usr/local/share/hud/lang"
  install -m 0755 "$HUD_BIN" "$STAGE/usr/local/bin/ml-hud"
  "${CROSS_STRIP:-aarch64-linux-gnu-strip}" "$STAGE/usr/local/bin/ml-hud" 2>/dev/null || true
  BTFL_FONT="$US/assets/osd-fonts/font_BTFL_hd.png"
  if [ -f "$BTFL_FONT" ]; then
    install -m 0644 "$BTFL_FONT" "$STAGE/usr/local/share/hud/font_BTFL_hd.png"
  else
    log "hud: $BTFL_FONT absent (generate with userspace/assets/osd-fonts/mcm2png.py); skipping font"
  fi

  install -m 0644 "$US"/ml-hud/lang/*.lang "$STAGE/usr/local/share/hud/lang/"
  log "hud: staged ml-hud + lang -> /usr/local/{bin,share}/"
else
  log "hud: $HUD_BIN absent (build with userspace/ml-hud/tools/deploy.sh); skipping"
fi

# Video (production track): the standalone fully-static ml-pipeline
# (userspace/gstreamer/scripts/build-static.sh - whole GStreamer + the curated plugin set baked in, no /mnt/gst, no
# plugin registry) plus the static RF daemon ml-linkd. With ml-drmfd + ml-hud (above) and the kernel
# modules + codec fw (already in this rootfs), RF video runs with NO SD card. The SD squashfs
# (userspace/gstreamer/scripts/deploy.sh) stays the development track. Both optional; skipped if not built.
PIPELINE_BIN="$US/gstreamer/build/static/ml-pipeline"
if [ -f "$PIPELINE_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$PIPELINE_BIN" "$STAGE/usr/local/bin/ml-pipeline"
  log "video: staged ml-pipeline (standalone static) -> /usr/local/bin/"
else
  log "video: $PIPELINE_BIN absent (build with userspace/gstreamer/scripts/build-static.sh); skipping"
fi

LINKD_BIN="$US/build/ml-linkd"
if [ -f "$LINKD_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$LINKD_BIN" "$STAGE/usr/local/bin/ml-linkd"
  "${CROSS_STRIP:-aarch64-linux-gnu-strip}" "$STAGE/usr/local/bin/ml-linkd" 2>/dev/null || true
  log "video: staged ml-linkd -> /usr/local/bin/"
else
  log "video: $LINKD_BIN absent (build with make -C userspace linkd); skipping"
fi

# ml-rf-bringup: the AR8030 RF link bring-up at boot (ml-video service) - reset release, SDIO
# re-probe, baseband firmware download, sdio0 config (absorbs the old gpio_pulse). Essential: with
# no RF bring-up there is no video, so a missing binary is a HARD build error, not a silent skip.
# Static aarch64 (make -C userspace rf-bringup).
RF_BRINGUP_BIN="$US/build/ml-rf-bringup"
if [ -f "$RF_BRINGUP_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$RF_BRINGUP_BIN" "$STAGE/usr/local/bin/ml-rf-bringup"
  "${CROSS_STRIP:-aarch64-linux-gnu-strip}" "$STAGE/usr/local/bin/ml-rf-bringup" 2>/dev/null || true
  log "video: staged ml-rf-bringup -> /usr/local/bin/ (AR8030 RF link bring-up at boot)"
else
  die "video: $RF_BRINGUP_BIN absent - RF bring-up is essential; build it with 'make -C userspace rf-bringup'"
fi

# ml-rf-persist (native/build.sh): writes a newly-paired air-unit MAC into the config candidate list
# under /usrdata so a bind survives reboot. ml-linkd execs it on a successful persist-mode bind;
# absent, binding still works but only as a runtime lock (a power cycle drops it). Static aarch64.
RF_PERSIST_BIN="$HERE/../native/build/ml-rf-persist"
if [ -f "$RF_PERSIST_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$RF_PERSIST_BIN" "$STAGE/usr/local/bin/ml-rf-persist"
  "${CROSS_STRIP:-aarch64-linux-gnu-strip}" "$STAGE/usr/local/bin/ml-rf-persist" 2>/dev/null || true
  log "video: staged ml-rf-persist -> /usr/local/bin/ (persist a paired air-unit MAC across reboot)"
else
  log "video: $RF_PERSIST_BIN absent (build with native/build.sh); binding will be runtime-only"
fi

# minidhcpd (native/build.sh, the musl-static build): single-lease DHCP on the USB gadget link so
# a phone/PC running a DHCP client gets an address on the gadget /24 (the Android app finds the
# device by that subnet). Started by the usb-gadget service; absent, static-IP hosts still work.
MINIDHCPD_BIN="$HERE/../native/build/minidhcpd-musl"
if [ -f "$MINIDHCPD_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$MINIDHCPD_BIN" "$STAGE/usr/local/bin/minidhcpd"
  log "net: staged minidhcpd -> /usr/local/bin/ (DHCP lease on the USB gadget link)"
else
  log "net: $MINIDHCPD_BIN absent (build with native/build.sh); USB hosts need a static IP"
fi

# Slot-switch helpers for the HUD's "Switch to Slot A" action: mtdtool (flips the gpt0 active bit;
# native/build.sh) and wdt-reset (watchdog reset so the SPL boots the active slot; built from
# glue/boot/wdt-reset.c). Both aarch64 static. Skipped if absent.
MTDTOOL_BIN="$HERE/../native/build/mtdtool"
WDTRESET_BIN="$HERE/../glue/build/wdt-reset"
# name|path|build-hint (mtdtool from the native gcc:7 container; wdt-reset from the glue Makefile)
for entry in "mtdtool|$MTDTOOL_BIN|native/build.sh" "wdt-reset|$WDTRESET_BIN|make -C glue"; do
  name="${entry%%|*}"; rest="${entry#*|}"
  path="${rest%%|*}"; hint="${rest#*|}"
  if [ -f "$path" ]; then
    mkdir -p "$STAGE/usr/local/bin"
    install -m 0755 "$path" "$STAGE/usr/local/bin/$name"
    "${CROSS_STRIP:-aarch64-linux-gnu-strip}" "$STAGE/usr/local/bin/$name" 2>/dev/null || true
    log "slot-switch: staged $name -> /usr/local/bin/"
  else
    log "slot-switch: $path absent (build with $hint); skipping (HUD slot switch will no-op)"
  fi
done

# ml-ledd (the ml-ledd boot service): the static status-LED indicator daemon. It runs in the
# boot runlevel before the SD card mounts, so unlike the gst-squashfs daemons it must live in the
# rootfs itself. Staged if built (ml-ledd/Makefile); the service warns and skips at boot otherwise.
LEDD_BIN="$US/build/ml-ledd"
if [ -f "$LEDD_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$LEDD_BIN" "$STAGE/usr/local/bin/ml-ledd"
  log "ml-ledd: staged -> /usr/local/bin/ml-ledd"
else
  log "ml-ledd: $LEDD_BIN absent (build with make -C userspace ledd); skipping"
fi

# umtprd (started by the usb-gadget service): the uMTP-Responder MTP daemon that exposes the
# SD-card DVR recordings over USB (ml-kernel issue #5). Static aarch64 musl build from the
# wrapper's native/umtprd/build.sh (a separate `make umtprd` - it clones upstream, so it is not
# part of `make native`/`all`). Staged if built; the gadget service falls back to ECM-only at
# boot otherwise, so MTP being absent never affects ECM/SSH.
UMTPRD_BIN="$HERE/../native/umtprd/build/umtprd"
if [ -f "$UMTPRD_BIN" ]; then
  mkdir -p "$STAGE/usr/local/bin"
  install -m 0755 "$UMTPRD_BIN" "$STAGE/usr/local/bin/umtprd"
  log "mtp: staged umtprd -> /usr/local/bin/umtprd"
else
  log "mtp: $UMTPRD_BIN absent (build with 'make umtprd'); MTP gadget will fall back to ECM-only"
fi

echo "$HOSTNAME" > "$STAGE/etc/hostname"

cat > "$STAGE/etc/hosts" <<EOF
127.0.0.1   localhost localhost.localdomain $HOSTNAME
::1         localhost localhost.localdomain $HOSTNAME
EOF

# apk repositories so `apk add` works once host NAT is up.
cat > "$STAGE/etc/apk/repositories" <<EOF
$ALPINE_CDN/latest-stable/main
$ALPINE_CDN/latest-stable/community
EOF

# Template the device addressing + USB product name into the gadget service
# (skeleton/etc/init.d/usb-gadget).
sed -i \
  -e "s|@DEV_MAC@|$DEV_MAC|" \
  -e "s|@HOST_MAC@|$HOST_MAC|" \
  -e "s|@GADGET_IP@|$GADGET_IP|" \
  -e "s|@GADGET_CIDR@|$GADGET_CIDR|" \
  -e "s|@HOST_GW@|$HOST_GW|" \
  -e "s|@USB_PRODUCT@|$USB_PRODUCT|" \
  "$STAGE/etc/init.d/usb-gadget"
chmod 0755 "$STAGE/etc/init.d/usb-gadget"

# Template the same USB product name into the MTP responder config so the MTP-level device
# name matches the USB descriptor (skeleton/etc/umtprd.conf).
[ -f "$STAGE/etc/umtprd.conf" ] && sed -i -e "s|@USB_PRODUCT@|$USB_PRODUCT|" "$STAGE/etc/umtprd.conf"

# Precompute the root password hash (fixed salt -> reproducible /etc/shadow line).
ROOT_HASH="$(openssl passwd -6 -salt artlynkopen "$ROOT_PASS")"

# ======================================================================================
# Build + configure + image, all inside one fakeroot session so file ownership recorded
# into the UBIFS image is root:root throughout.
# ======================================================================================
UBIFS_IMG="$OUT/rootfs.ubifs"
UBI_IMG="$OUT/rootfs.ubi"
UBINIZE_CFG="$WORK/ubinize.cfg"
cat > "$UBINIZE_CFG" <<EOF
[rootfs]
mode=ubi
image=$UBIFS_IMG
vol_id=0
vol_type=dynamic
vol_name=rootfs
vol_flags=autoresize
EOF

log "building rootfs under fakeroot (flavor=$FLAVOR: $PACKAGES)"
export APK_STATIC KEYS ROOT MAIN_REPO COMMUNITY_REPO PACKAGES STAGE \
       ROOT_HASH MKFS_UBIFS UBINIZE UBIFS_IMG UBI_IMG UBINIZE_CFG \
       MIN_IO LEB_SIZE MAX_LEB_COUNT PEB_SIZE SUBPAGE MODULES_STAGE FLAVOR

fakeroot bash -euo pipefail "$SCRIPTS/make-rootfs.sh"

# ======================================================================================
# Report
# ======================================================================================
UBI_BYTES="$(stat -c %s "$UBI_IMG")"
UBIFS_BYTES="$(stat -c %s "$UBIFS_IMG")"
LIMIT=$(( PEB_SIZE * PARTITION_PEBS ))
LIMIT_MIB=$(( LIMIT / 1024 / 1024 ))

echo
echo "=================================================================="
echo " Alpine $ALPINE_VER aarch64 rootfs for the open kernel ($HOSTNAME, flavor=$FLAVOR)"
echo "=================================================================="
# Fail on overflow up front; the stats themselves print LAST so they don't scroll away
# behind the package list.
if [ "$UBI_BYTES" -ge "$LIMIT" ]; then
  die "rootfs.ubi ($UBI_BYTES) does NOT fit in $PARTITION ($LIMIT)"
fi

echo "Installed packages:"
"$APK_STATIC" --root "$ROOT" info 2>/dev/null | sort | sed 's/^/  /'
echo

if [ -n "$MODULES_STAGE" ]; then
  KO_COUNT="$(find "$ROOT/lib/modules" -name '*.ko' 2>/dev/null | wc -l)"
  echo "Kernel modules: $KO_COUNT staged at /lib/modules/ (placed only, not auto-loaded)"
else
  echo "Kernel modules: none staged (build with kernel/modules/build.sh)"
fi
echo

echo "rootfs.ubifs : $UBIFS_IMG  ($UBIFS_BYTES bytes)"
echo "rootfs.ubi   : $UBI_IMG  ($UBI_BYTES bytes)"
printf "partition    : %s = %d bytes (%d MiB); image uses %d%%\n" \
  "$PARTITION" "$LIMIT" "$LIMIT_MIB" "$(( UBI_BYTES * 100 / LIMIT ))"
echo

echo "Flash:  ubiformat /dev/mtdN -f $(basename "$UBI_IMG")   (mtdN = $PARTITION)"
echo "Boot:   ubi.mtd=$PARTITION root=ubi:rootfs rootfstype=ubifs rw"
