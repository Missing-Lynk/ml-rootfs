#!/usr/bin/env bash
# Reproducible Alpine aarch64 dev-platform rootfs for the open mainline kernel on Artosyn
# Proxima-class devices (goggles, air units, video receivers). Output is a UBIFS+UBI image
# to flash to the device's NAND partition.
#
# Per-device specifics live in devices/<name>/: board.conf (identity/addressing + NAND geometry)
# and overlay/ (the device-specific OpenRC services + modules-load, layered on the shared
# skeleton/). Arg 1 = the device name (required, no default).
#
#   build.sh <device-name>            # e.g. betafpv-vr04-goggle
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
MINIROOTFS_URL="$ALPINE_CDN/$ALPINE_BRANCH/releases/aarch64/$MINIROOTFS"

# apk-tools-static for the BUILD host (run here with --arch aarch64).
HOST_ARCH="$(uname -m)"
APK_STATIC_PKG="apk-tools-static-${APK_TOOLS_VER}.apk"
APK_STATIC_URL="$MAIN_REPO/$HOST_ARCH/$APK_STATIC_PKG"

# Everything per-device lives in devices/<name>/: board.conf (target identity/addressing + NAND
# geometry) and overlay/ (the device-specific OpenRC services + modules-load, layered on the
# shared skeleton/ below). Arg 1 = the device name (required, no default). Same names as the root
# Makefile DEVICE and kernel/devices/<name>/.
DEV="${1:-}"
[ -n "$DEV" ] || die "no device given (arg 1); pass a device name, e.g. betafpv-vr04-goggle"
DEVICE_DIR="$HERE/devices/$DEV"
DEVICE_CONF="$DEVICE_DIR/board.conf"
DEVICE_OVERLAY="$DEVICE_DIR/overlay"
[ -f "$DEVICE_CONF" ] || die "device '$DEV': no $DEVICE_CONF (devices/$DEV/board.conf)"
log "device: $DEV ($DEVICE_CONF)"

# shellcheck source=/dev/null
. "$DEVICE_CONF"

# Fail early on an incomplete or malformed profile rather than midway through the build. Every
# value below is read unguarded from here on, so this is what makes that safe.
for v in HOSTNAME ROOT_PASS GADGET_IP GADGET_CIDR HOST_GW DEV_MAC HOST_MAC USB_PRODUCT HAS_SD \
         HAS_DISPLAY RF_ROLE PARTITION PARTITION_PEBS PEB_SIZE MIN_IO SUBPAGE LEB_SIZE \
         MAX_LEB_COUNT; do
  [ -n "${!v:-}" ] || die "device config $DEVICE_CONF: missing $v"
done

# Capability flags gate whole payloads, so anything but 0/1 - "yes", "true", a typo - would read
# as "this board has no panel" and silently ship an image missing its display stack.
for v in HAS_SD HAS_DISPLAY; do
  case "${!v}" in
    0|1)
      ;;
    *)
      die "device config $DEVICE_CONF: $v='${!v}' (0|1)"
      ;;
  esac
done

# The role branches are per-role with no fallback, so an unrecognised value would produce an
# image with no baseband firmware and no role binaries.
case "$RF_ROLE" in
  air|ground)
    ;;
  *)
    die "device config $DEVICE_CONF: RF_ROLE='$RF_ROLE' (air|ground)"
    ;;
esac

# The tuning blob's device-side name and size are only meaningful together with the source path.
if [ -n "${ISP_TUNING:-}" ]; then
  for v in ISP_TUNING_NAME ISP_TUNING_SIZE; do
    [ -n "${!v:-}" ] || die "device config $DEVICE_CONF: ISP_TUNING set but $v missing"
  done
fi


# Whitelisted kernel modules (built by kernel/modules/build.sh, which already stages
# only the modules we ship - Artosyn out-of-tree + the in-tree DRM stack - with depmod
# already run). They are placed at /lib/modules/$KVER/ and NOT auto-loaded (no
# modules-load.d entry, no rc service) - load manually with insmod/modprobe once booted.
# Skip silently if that build hasn't been run; the rootfs still builds without them.
# shellcheck source=/dev/null
# KERNEL_BUILD_DEFAULT comes from pin.env, so it is unset when the kernel checkout is
# absent; the :- keeps that case out of `set -u`. An empty build dir leaves MODULES_STAGE
# empty rather than rooted at /, which would otherwise resolve to the HOST's /lib/modules.
source "$HERE/../kernel/scripts/pin.env" 2>/dev/null || true
KERNEL_BUILD_DIR="${BUILD_DIR:-${KERNEL_BUILD_DEFAULT:-}}"
# "-" not ":-": an explicitly empty MODULES_STAGE= disables module staging, which ":-" would
# quietly turn back into the default.
MODULES_STAGE="${MODULES_STAGE-${KERNEL_BUILD_DIR:+$KERNEL_BUILD_DIR/ml-modules/rootfs}}"
if [ -n "$MODULES_STAGE" ] && [ -d "$MODULES_STAGE/lib/modules" ]; then
  log "kernel modules: staging from $MODULES_STAGE"
  # Guard against shipping a display device an incomplete module stage: a stage that was left
  # stale or built for a no-display kernel lacks the DRM stack, and the panel then stays dark
  # with no visible cause (the failure that motivated this guard). Only enforced when a stage is
  # present AND this device has a panel; a deliberately module-less build still logs and skips
  # above. `make kernel` also asserts this stage-side (kernel/modules/stage.sh), so this is the
  # belt-and-braces net for the case where rootfs is rebuilt against a pre-existing bad stage.
  if [ "$HAS_DISPLAY" = 1 ]; then
    for ko in artosyn_vo.ko drm.ko; do
      find "$MODULES_STAGE/lib/modules" -name "$ko" | grep -q . \
        || die "kernel modules: HAS_DISPLAY=1 but $ko missing from $MODULES_STAGE (stale/incomplete stage; rebuild with 'make kernel')"
    done
  fi
elif [ -z "$MODULES_STAGE" ]; then
  log "kernel modules: staging disabled (MODULES_STAGE empty); building a module-less image"
else
  log "kernel modules: nothing at $MODULES_STAGE (build with kernel/modules/build.sh); skipping"
  MODULES_STAGE=""
fi

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
  # A cached file is reused when its checksum matches, and unconditionally when no checksum is
  # pinned for this host arch - re-fetching a file nothing can verify gains nothing.
  if [ -f "$out" ]; then
    if [ -z "$sha" ]; then
      return
    fi
    if echo "$sha  $out" | sha256sum -c - >/dev/null 2>&1; then
      return
    fi
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

# ======================================================================================
# Staging helpers
#
#   stage     SRC DST [--tag T] [--hint H | --see S] [--mode M] [--strip]
#   stage_req SRC DST [--tag T] [--hint H | --see S] [--mode M] [--strip] [--why W]
#
# stage installs SRC if a sibling repo built it and says where to get it otherwise, so a fresh
# clone still produces an image. stage_req dies instead; --why states what breaks on the
# device. DST is relative to the image root, no leading slash. --tag prefixes the log line.
#
# --hint is the command that builds SRC; --see points at an asset that is committed rather
# than built, where "build with" would be wrong.
#
# Gated-off artifacts are silent: a log line is only worth printing when a feature this
# device HAS is missing its artifact.
# ======================================================================================
_stage() {
  local required="$1" src="$2" dst="$3"
  shift 3
  local tag="stage" hint="" why="" mode=0755 strip=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --tag)
        tag="$2"
        shift 2
        ;;
      --hint)
        hint="build with $2"
        shift 2
        ;;
      --see)
        hint="see $2"
        shift 2
        ;;
      --why)
        why="$2"
        shift 2
        ;;
      --mode)
        mode="$2"
        shift 2
        ;;
      --strip)
        strip=1
        shift
        ;;
      *)
        die "_stage: unknown option '$1' (staging $src)"
        ;;
    esac
  done

  if [ ! -f "$src" ]; then
    if [ "$required" = 1 ]; then
      die "$tag: $src absent${why:+ - $why}${hint:+; $hint}"
    fi

    log "$tag: $src absent${hint:+ ($hint)}; skipping"
    return 0
  fi

  mkdir -p "$STAGE/$(dirname "$dst")"
  install -m "$mode" "$src" "$STAGE/$dst"
  if [ "$strip" = 1 ]; then
    "${CROSS_STRIP:-aarch64-linux-gnu-strip}" "$STAGE/$dst" 2>/dev/null || true
  fi

  log "$tag: staged $(basename "$src") -> /$dst"
}

stage() {
  _stage 0 "$@"
}

stage_req() {
  _stage 1 "$@"
}

# Proprietary vendor blobs, populate with glue/fetch/fetch-vendor-blobs.sh.
VENDOR_BLOBS="$HERE/../firmware/bin/slot-a"

# Wave521C VCPU ucode, request_firmware()d by wave5.ko under the name it asks for.
stage "$VENDOR_BLOBS/usr/bin/chagall.bin" lib/firmware/cnm/wave521c_k3_codec_fw.bin \
  --tag "codec firmware" --mode 0644 --hint "glue/fetch/fetch-vendor-blobs.sh"

# ISP tuning blob, request_firmware()d by ar-isp. Which file, what the driver calls it and how
# big it must be are sensor-specific and declared in the device profile; a board that declares
# none stages none. Absent or wrong-sized is fatal rather than a skip.
if [ -n "${ISP_TUNING:-}" ]; then
  ISP_TUNING_SRC="$VENDOR_BLOBS/$ISP_TUNING"
  if [ ! -f "$ISP_TUNING_SRC" ]; then
    die "ISP tuning: $ISP_TUNING_SRC absent - the ISP would run unconfigured and the picture would be garbage with no error anywhere; fetch it with glue/fetch/fetch-vendor-blobs.sh"
  fi

  if [ "$(stat -c %s "$ISP_TUNING_SRC")" != "$ISP_TUNING_SIZE" ]; then
    die "ISP tuning: $ISP_TUNING_SRC is $(stat -c %s "$ISP_TUNING_SRC") bytes, expected $ISP_TUNING_SIZE - ar-isp would reject it and run unconfigured"
  fi

  stage "$ISP_TUNING_SRC" "lib/firmware/artosyn/$ISP_TUNING_NAME" \
    --tag "ISP tuning" --mode 0644
fi

# AR8030 baseband image + merged config, request_firmware()d by artosyn_sdio (insmod
# fw_name=/cfg_name=) and uploaded to the chip by the ROM loader. Baked in at the default search
# path so a flashed image needs no host push; the reset + insmod sequence stays in ml-rf-bringup.
# RF_ROLE picks the set, and each device carries only its own.
#
# Paired: the driver needs image and config together, so half a set stages as none.
if [ "$RF_ROLE" = "air" ]; then
  RF_FW="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_demo_air_d.img"
  RF_CFG="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_config_air.json"
  if [ -f "$RF_FW" ] && [ -f "$RF_CFG" ]; then
    stage "$RF_FW"  lib/firmware/bb_demo_air_d.img  --tag "RF firmware" --mode 0644
    stage "$RF_CFG" lib/firmware/bb_config_air.json --tag "RF firmware" --mode 0644
  else
    log "RF firmware: $RF_FW / $RF_CFG absent; air RF bring-up will need them pushed at runtime"
  fi
fi

if [ "$RF_ROLE" = "ground" ]; then
  RF_FW="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_demo_gnd_d.img"
  RF_CFG="$VENDOR_BLOBS/tmp/ar813x/bb_config_gnd.json.usr_cfg.json"
  if [ -f "$RF_FW" ] && [ -f "$RF_CFG" ]; then
    stage "$RF_FW"  lib/firmware/bb_demo_gnd_d.img               --tag "RF firmware" --mode 0644
    stage "$RF_CFG" lib/firmware/bb_config_gnd.json.usr_cfg.json --tag "RF firmware" --mode 0644

    # Band = chan_valid_bmp, which only enters the chip at firmware upload, so each band is a
    # whole blob and switching costs a boot. The captured config is race (0x0007FFF8, table
    # indices 3..18); rewrite that one field for normal (0x00000007 = 5758/5788/5828). ml-video
    # picks between them at boot. The grep is load-bearing: an unrewritten copy is a race blob
    # shipped as the normal band.
    sed 's/"chan_valid_bmp":\([[:space:]]*\)"0x0007FFF8"/"chan_valid_bmp":\1"0x00000007"/I' \
        "$RF_CFG" > "$STAGE/lib/firmware/bb_config_gnd.json.normal_cfg.json"
    if ! grep -qi '"chan_valid_bmp":[[:space:]]*"0x00000007"' \
          "$STAGE/lib/firmware/bb_config_gnd.json.normal_cfg.json"; then
      die "RF firmware: chan_valid_bmp not rewritten in $RF_CFG - normal-band config would be a race blob"
    fi

    log "RF firmware: staged normal-band config -> /lib/firmware/"
  else
    log "RF firmware: $RF_FW / $RF_CFG absent; RF bring-up will push them at runtime (glue/dev/rf-bringup.sh -> /run/ml/fw)"
  fi
fi

# --------------------------------------------------------------------------------------
# Binaries. Every device gets these.
# --------------------------------------------------------------------------------------

stage "$US/build/ml-linkd" usr/local/bin/ml-linkd \
  --tag video --strip --hint "make -C userspace linkd"

# AR8030 bring-up at boot: reset release, SDIO re-probe, firmware download, sdio0 config.
# Required - without it there is no RF and so no video on any device.
stage_req "$US/build/ml-rf-bringup" usr/local/bin/ml-rf-bringup \
  --tag video --strip --hint "make -C userspace rf-bringup" \
  --why "RF bring-up is essential, there is no video without it"

# Marks a healthy boot in /usrdata/missinglynk/device.json; absent, the boot count is not kept.
stage "$HERE/../native/build/ml-boot-record" usr/local/bin/ml-boot-record \
  --tag identity --strip --hint "native/build.sh"

# Single-lease DHCP on the USB gadget link, started by the usb-gadget service, so a phone or PC
# running a DHCP client gets an address on the gadget /24. Absent, static-IP hosts still work.
stage "$HERE/../native/build/minidhcpd-musl" usr/local/bin/minidhcpd \
  --tag net --hint "native/build.sh"

# Flips the gpt0 active bit for the slot switch, and is how ml-usrdata attaches usr_data.
stage "$HERE/../native/build/mtdtool" usr/local/bin/mtdtool \
  --tag slot-switch --strip --hint "native/build.sh"

# --------------------------------------------------------------------------------------
# Display payload: the panel-side stack, none of which a HAS_DISPLAY=0 board can start.
# ml-pipeline is ~10 MiB and the splash 3 MB on an uncompressed UBIFS, so this is most of
# what separates a goggle image from an air-unit one.
# --------------------------------------------------------------------------------------
if [ "$HAS_DISPLAY" = 1 ]; then
  # ml-display service: DRM-master broker, splash painter, and the splash asset.
  for b in ml-drmfd ml-splash; do
    stage "$US/gstreamer/build/bin/$b" "usr/local/bin/$b" \
      --tag display --hint "userspace/gstreamer/src/build.sh"
  done

  stage "$US/assets/splash/splash.yuv" usr/local/share/nosignal.yuv \
    --tag display --mode 0644 --see "userspace/assets/splash"

  # ml-hud service: menu + OSD on a DRM overlay plane, its glyph font and i18n catalogs.
  HUD_BIN="$US/ml-hud/build/hud"
  stage "$HUD_BIN" usr/local/bin/ml-hud \
    --tag hud --strip --hint "userspace/ml-hud/tools/deploy.sh"
  stage "$US/assets/osd-fonts/font_BTFL_hd.png" usr/local/share/hud/font_BTFL_hd.png \
    --tag hud --mode 0644 --hint "userspace/assets/osd-fonts/mcm2png.py"

  # A set, not an artifact: the catalogs ship with ml-hud and are never built separately.
  if [ -f "$HUD_BIN" ]; then
    mkdir -p "$STAGE/usr/local/share/hud/lang"
    install -m 0644 "$US"/ml-hud/lang/*.lang "$STAGE/usr/local/share/hud/lang/"
    log "hud: staged lang catalogs -> /usr/local/share/hud/lang/"
  fi

  # Standalone static decode/display binary: whole GStreamer + the curated plugin set baked
  # in, no /mnt/gst, no plugin registry. The SD squashfs (gstreamer/scripts/deploy.sh) is the
  # development track.
  stage "$US/gstreamer/build/static/ml-pipeline" usr/local/bin/ml-pipeline \
    --tag video --hint "userspace/gstreamer/scripts/build-static.sh"

  # Watchdog reset so the SPL boots the active slot. Only the HUD's "Switch to Slot A" runs it.
  stage "$HERE/../glue/build/wdt-reset" usr/local/bin/wdt-reset \
    --tag slot-switch --strip --hint "make -C glue"
fi

# --------------------------------------------------------------------------------------
# Role payload.
# --------------------------------------------------------------------------------------
if [ "$RF_ROLE" = "air" ]; then
  # Video TX (same gst-full mechanism as ml-pipeline), its control tool, and the passive FC
  # UART test tool.
  stage "$US/gstreamer/build/static/ml-air-video" usr/local/bin/ml-air-video \
    --tag video --hint "userspace/gstreamer/scripts/build-static.sh"
  stage "$US/gstreamer/build/bin/ml-air-ctl" usr/local/bin/ml-air-ctl \
    --tag video --hint "make -C userspace gst"
  stage "$US/build/ml-msp-echo" usr/local/bin/ml-msp-echo \
    --tag video --strip --hint "make -C userspace msp-echo"
fi

if [ "$RF_ROLE" = "ground" ]; then
  # ml-rf-persist writes a newly-paired peer MAC into the config candidate list under /usrdata
  # so a bind survives a power cycle; absent, a bind is only a runtime lock. The RX pair
  # sequence is what learns a MAC - the air unit only enters pair mode from its bind button.
  stage "$HERE/../native/build/ml-rf-persist" usr/local/bin/ml-rf-persist \
    --tag video --strip --hint "native/build.sh"
  # Sends the HUD's own RF commands (channel, scan, bind) from a shell, so those paths are
  # reachable without the UI.
  stage "$US/build/ml-rfcmd" usr/local/bin/ml-rfcmd \
    --tag video --strip --hint "make -C userspace rfcmd"
fi

# ml-ledd drives the WS2812-style RGB LED over spidev, which only some boards carry; the air
# unit's indicators are plain GPIO LEDs that leds-gpio handles in-kernel. Gated on its own
# service: the overlay is already staged, so the daemon and its service cannot disagree.
if [ -f "$STAGE/etc/init.d/ml-ledd" ]; then
  stage "$US/build/ml-ledd" usr/local/bin/ml-ledd \
    --tag ml-ledd --hint "make -C userspace ledd"
fi

# SD payload: the uMTP-Responder daemon the usb-gadget service starts to expose recordings over
# USB. Built by `make umtprd` alone - it clones upstream, so it is not part of `make native`.
# Absent, the gadget binds ECM-only, so MTP never costs SSH.
#
# Its config ships in the shared skeleton, so a card-less board is handed one unless it is dropped
# here; the templating further down is already presence-gated and skips it once it is gone.
if [ "$HAS_SD" = 1 ]; then
  stage "$HERE/../native/umtprd/build/umtprd" usr/local/bin/umtprd \
    --tag mtp --hint "make umtprd"
else
  rm -f "$STAGE/etc/umtprd.conf"
fi

echo "$HOSTNAME" > "$STAGE/etc/hostname"

cat > "$STAGE/etc/hosts" <<EOF
127.0.0.1   localhost localhost.localdomain $HOSTNAME
::1         localhost localhost.localdomain $HOSTNAME
EOF

# apk repositories so `apk add` works once host NAT is up. latest-stable rather than the pinned
# $ALPINE_BRANCH on purpose: the build inputs are pinned for reproducibility, but a running image
# should still reach a repo that exists after Alpine promotes the next release.
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
  -e "s|@HAS_SD@|$HAS_SD|" \
  "$STAGE/etc/init.d/usb-gadget"
chmod 0755 "$STAGE/etc/init.d/usb-gadget"

# Template the same USB product name into the MTP responder config so the MTP-level device
# name matches the USB descriptor (skeleton/etc/umtprd.conf).
[ -f "$STAGE/etc/umtprd.conf" ] && sed -i -e "s|@USB_PRODUCT@|$USB_PRODUCT|" "$STAGE/etc/umtprd.conf"

# Template the hardware version into the air-unit link service. File-presence gated: only an
# air-role overlay ships it, and only those profiles set HW_VERSION.
[ -f "$STAGE/etc/init.d/ml-air-link" ] && sed -i -e "s|@HW_VERSION@|${HW_VERSION:-V1.0}|" "$STAGE/etc/init.d/ml-air-link"

# Precompute the root password hash (fixed salt -> reproducible /etc/shadow line).
# shellcheck disable=SC2153  # ROOT_PASS comes from $DEVICE_CONF, presence-checked above
ROOT_HASH="$(openssl passwd -6 -salt artlynkopen "$ROOT_PASS")"

# ======================================================================================
# Build + configure + image, all inside one fakeroot session so file ownership recorded
# into the UBIFS image is root:root throughout.
# ======================================================================================
UBIFS_IMG="$OUT/rootfs-$DEV.ubifs"
UBI_IMG="$OUT/rootfs-$DEV.ubi"
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

# Image identity, baked into /etc/ml-release (make-rootfs.sh) so on-device tooling and the
# CLI can answer "what image is this" from inside the slot. ML_VERSION mirrors the mlimg
# manifest label (glue/flash/mlimg.py): the kernel git-describe, falling back to the pinned
# kernel version, then "dev". The git-describes and build time are the same provenance mlimg
# records, so a running rootfs can be matched to the bundle it came from.
ML_KERNEL_VERSION="${KERNEL_VERSION:-}"
ML_KERNEL_GIT="$(git -C "$HERE/../kernel" describe --tags --always --dirty 2>/dev/null || true)"
ML_ROOTFS_GIT="$(git -C "$HERE" describe --tags --always --dirty 2>/dev/null || true)"
ML_VERSION="${ML_KERNEL_GIT:-${ML_KERNEL_VERSION:-dev}}"
ML_BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

log "building rootfs under fakeroot (flavor=$FLAVOR: $PACKAGES)"
export APK_STATIC KEYS ROOT MAIN_REPO COMMUNITY_REPO PACKAGES STAGE \
       ROOT_HASH MKFS_UBIFS UBINIZE UBIFS_IMG UBI_IMG UBINIZE_CFG \
       MIN_IO LEB_SIZE MAX_LEB_COUNT PEB_SIZE SUBPAGE MODULES_STAGE FLAVOR \
       DEV ML_VERSION ML_KERNEL_VERSION ML_KERNEL_GIT ML_ROOTFS_GIT ML_BUILD_TIME

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
  die "$(basename "$UBI_IMG") ($UBI_BYTES) does NOT fit in $PARTITION ($LIMIT)"
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
