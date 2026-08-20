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
# apk-tools-static sha is pinned for x86_64 build hosts; add a pin before enabling another host arch.
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
  air|gnd)
    ;;
  *)
    die "device config $DEVICE_CONF: RF_ROLE='$RF_ROLE' (air|gnd)"
    ;;
esac

# The tuning blob's device-side name is only meaningful together with the source path. Its size is
# not a board property: it comes from the layout, below.
if [ -n "${ISP_TUNING:-}" ]; then
  [ -n "${ISP_TUNING_NAME:-}" ] || die "device config $DEVICE_CONF: ISP_TUNING set but ISP_TUNING_NAME missing"
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
  # above.
  #
  # This coexists with the stage-side assert in kernel/modules/stage.sh on purpose; the two fire
  # at different times against different inputs. stage.sh runs during `make kernel`, keyed on the
  # kernel .config (CONFIG_DRM_ARTOSYN), and catches a kernel built without the display stack.
  # This one runs during a rootfs build, keyed on the device profile (HAS_DISPLAY), and is the
  # only check that fires when the rootfs is rebuilt alone against a stage produced by an earlier,
  # stale, or no-display kernel build. Keep both; deleting either loses one of those two triggers.
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
case "$HOST_ARCH" in
  x86_64)
    APK_SHA="$APK_STATIC_SHA256_x86_64"
    ;;
  *)
    die "unsupported host arch '$HOST_ARCH': no pinned sha256 for $APK_STATIC_PKG"
    ;;
esac
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
# Stage the overlay tree ($STAGE): skeleton + device overlay, vendor blobs, compiled
# binaries and the profile-templated files. Sourced so it shares this shell and every
# variable set above; it leaves $STAGE populated for the fakeroot build body below.
# ======================================================================================
# shellcheck source=scripts/stage-payload.sh
source "$SCRIPTS/stage-payload.sh"


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
