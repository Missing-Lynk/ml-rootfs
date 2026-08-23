#!/usr/bin/env bash
# Populate the overlay staging tree ($STAGE) that make-rootfs.sh later copies into the
# rootfs: the shared skeleton, the device overlay, the vendor blobs, the compiled binaries
# from the sibling repos, and the files templated from the device profile.
#
# Sourced by build.sh (not exec'd) after the device profile is validated and the Alpine
# inputs are fetched, so it shares build.sh's shell and every variable already set there
# (HERE, US, STAGE, SKEL, DEVICE_OVERLAY, the RF_ROLE/HAS_*/ISP_*/addressing profile vars,
# ALPINE_CDN). Unlike make-rootfs.sh, this runs in-process rather than under fakeroot, so
# it needs no separate env contract. It leaves the populated $STAGE for the caller; the
# root password hash and image identity stay in build.sh alongside the fakeroot handoff.
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
# stage installs optional SRC when present and says how to produce it when absent. stage_req
# dies instead; --why states what breaks on the device. DST is relative to the image root,
# no leading slash. --tag prefixes the log line.
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

# ISP tuning blob, request_firmware()d by ar-isp. Declared per board; a board that declares none
# stages none. Absent or wrong-sized is fatal rather than a skip.
if [ -n "${ISP_TUNING:-}" ]; then
  # Expected size from the generated blob header, so this and the driver's check agree.
  ISP_BLOB_H="$HERE/../kernel/overlay/drivers/media/artosyn/vendor-tables/ar-isp-blob.h"
  [ -f "$ISP_BLOB_H" ] || die "ISP tuning: $ISP_BLOB_H absent - check out the kernel submodule"
  ISP_TUNING_SIZE=$(sed -n 's/^#define[[:space:]]\+AR_ISP_TUNING_SIZE[[:space:]]\+\(0x[0-9a-fA-F]\+\).*/\1/p' "$ISP_BLOB_H")
  [ -n "$ISP_TUNING_SIZE" ] || die "ISP tuning: no AR_ISP_TUNING_SIZE in $ISP_BLOB_H"
  ISP_TUNING_SIZE=$((ISP_TUNING_SIZE))

  ISP_TUNING_SRC="$VENDOR_BLOBS/$ISP_TUNING"
  if [ ! -f "$ISP_TUNING_SRC" ]; then
    die "ISP tuning: $ISP_TUNING_SRC absent - fetch it with glue/fetch/fetch-vendor-blobs.sh"
  fi

  if [ "$(stat -c %s "$ISP_TUNING_SRC")" != "$ISP_TUNING_SIZE" ]; then
    die "ISP tuning: $ISP_TUNING_SRC is $(stat -c %s "$ISP_TUNING_SRC") bytes, expected $ISP_TUNING_SIZE"
  fi

  stage "$ISP_TUNING_SRC" "lib/firmware/artosyn/$ISP_TUNING_NAME" \
    --tag "ISP tuning" --mode 0644
fi

# AR8030 baseband image + merged config, request_firmware()d by artosyn_sdio (insmod
# fw_name=/cfg_name=) and uploaded to the chip by the ROM loader. Baked in at the default search
# path so a flashed image needs no host push; the reset + insmod sequence stays in ml-rf-bringup.
# RF_ROLE picks the set, and each device carries only its own; RF_ROLE is validated air|gnd
# above, so this case is exhaustive.
case "$RF_ROLE" in
  air)
    RF_FW="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_demo_air_d.img"
    RF_CFG="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_config_air.json"
    RF_FW_DST="lib/firmware/bb_demo_air_d.img"
    RF_CFG_DST="lib/firmware/bb_config_air.json"
    ;;
  gnd)
    RF_FW="$VENDOR_BLOBS/usr/usrdata/ar813x/bb_demo_gnd_d.img"
    RF_CFG="$VENDOR_BLOBS/tmp/ar813x/bb_config_gnd.json.usr_cfg.json"
    RF_FW_DST="lib/firmware/bb_demo_gnd_d.img"
    RF_CFG_DST="lib/firmware/bb_config_gnd.json.usr_cfg.json"
    ;;
esac

# Paired: the driver needs image and config together, so half a set stages as none.
if [ -f "$RF_FW" ] && [ -f "$RF_CFG" ]; then
  stage "$RF_FW"  "$RF_FW_DST"  --tag "RF firmware" --mode 0644
  stage "$RF_CFG" "$RF_CFG_DST" --tag "RF firmware" --mode 0644

  # Ground carries a second, normal-band config derived from the captured one. Band =
  # chan_valid_bmp, which only enters the chip at firmware upload, so each band is a whole blob
  # and switching costs a boot. The captured config is race (0x0007FFF8, table indices 3..18);
  # rewrite that one field for normal (0x00000007 = 5758/5788/5828). ml-video picks between them
  # at boot. The grep is load-bearing: an unrewritten copy is a race blob shipped as the normal band.
  if [ "$RF_ROLE" = "gnd" ]; then
    sed 's/"chan_valid_bmp":\([[:space:]]*\)"0x0007FFF8"/"chan_valid_bmp":\1"0x00000007"/I' \
        "$RF_CFG" > "$STAGE/lib/firmware/bb_config_gnd.json.normal_cfg.json"
    if ! grep -qi '"chan_valid_bmp":[[:space:]]*"0x00000007"' \
          "$STAGE/lib/firmware/bb_config_gnd.json.normal_cfg.json"; then
      die "RF firmware: chan_valid_bmp not rewritten in $RF_CFG - normal-band config would be a race blob"
    fi

    log "RF firmware: staged normal-band config -> /lib/firmware/"
  fi
else
  log "RF firmware: $RF_FW / $RF_CFG absent; RF bring-up will push them at runtime (glue/dev/rf-bringup.sh -> /run/ml/fw)"
fi

# --------------------------------------------------------------------------------------
# Binaries. Every device gets these.
# --------------------------------------------------------------------------------------

stage_req "$US/build/ml-linkd" usr/local/bin/ml-linkd \
  --tag video --strip --hint "make -C userspace linkd" \
  --why "ml-linkd owns RF association and the video handshake on both roles"

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
stage_req "$HERE/../native/build/mtdtool" usr/local/bin/mtdtool \
  --tag slot-switch --strip --hint "native/build.sh" \
  --why "ml-usrdata needs it to mount the persistent store"

# --------------------------------------------------------------------------------------
# Display payload: the panel-side stack, none of which a HAS_DISPLAY=0 board can start.
# ml-pipeline is ~10 MiB and the splash 3 MB on an uncompressed UBIFS, so this is most of
# what separates a goggle image from an air-unit one.
# --------------------------------------------------------------------------------------
if [ "$HAS_DISPLAY" = 1 ]; then
  # ml-display service: DRM-master broker, splash painter, and the splash asset.
  stage_req "$US/gstreamer/build/bin/ml-drmfd" usr/local/bin/ml-drmfd \
    --tag display --hint "userspace/gstreamer/src/build.sh" \
    --why "display, HUD and video clients need the DRM broker socket"
  stage "$US/gstreamer/build/bin/ml-splash" usr/local/bin/ml-splash \
    --tag display --hint "userspace/gstreamer/src/build.sh"

  stage "$US/assets/splash/splash.yuv" usr/local/share/nosignal.yuv \
    --tag display --mode 0644 --see "userspace/assets/splash"

  # ml-hud service: menu + OSD on a DRM overlay plane, its glyph font and i18n catalogs.
  HUD_BIN="$US/ml-hud/build/hud"
  stage_req "$HUD_BIN" usr/local/bin/ml-hud \
    --tag hud --strip --hint "userspace/ml-hud/tools/deploy.sh" \
    --why "HAS_DISPLAY=1 images advertise the HUD/menu as part of the working unit"
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
  stage_req "$US/gstreamer/build/static/ml-pipeline" usr/local/bin/ml-pipeline \
    --tag video --hint "userspace/gstreamer/scripts/build-static.sh" \
    --why "ground-role video cannot flow without the static receiver pipeline"
fi

# --------------------------------------------------------------------------------------
# Role payload.
# --------------------------------------------------------------------------------------
if [ "$RF_ROLE" = "air" ]; then
  # Video TX (same gst-full mechanism as ml-pipeline), its control tool, and the passive FC
  # UART test tool.
  stage_req "$US/gstreamer/build/static/ml-air-video" usr/local/bin/ml-air-video \
    --tag video --hint "userspace/gstreamer/scripts/build-static.sh" \
    --why "air-role video cannot flow without the static camera transmitter"
  stage "$US/gstreamer/build/bin/ml-air-ctl" usr/local/bin/ml-air-ctl \
    --tag video --hint "make -C userspace gst"
  stage "$US/build/ml-msp-echo" usr/local/bin/ml-msp-echo \
    --tag video --strip --hint "make -C userspace msp-echo"
fi

# Watchdog reset so the SPL boots the active slot. Every board needs it: a plain reboot is a no-op
# on this SoC, so this is the only software reset either unit has. The HUD's slot-switch and
# band-change actions run it, `flip-slot.sh` pushes its own copy, and the flasher reboots through
# the installed one (openRebootCmd in flasher/internal/flow/landing.go), which is why it cannot be
# gated on the display.
stage "$HERE/../glue/build/wdt-reset" usr/local/bin/wdt-reset \
  --tag slot-switch --strip --hint "make -C glue"

# ml-rf-persist writes a newly-paired peer MAC into the config under /usrdata so a bind survives a
# power cycle; absent, a bind is only a runtime lock the next boot forgets. Both roles need it and
# the binary serves both: the ground writes a candidate list of up to five peers, and `--air` writes
# the DEV role's single AP scalar. ml-linkd execs it by absolute path (AIR_BIND_PERSIST in
# ml-air-bind.h, rx_bind on the ground side), and a missing binary is reported only as
# "persist FAILED" in the bind log, so it is invisible until the next power cycle.
stage_req "$HERE/../native/build/ml-rf-persist" usr/local/bin/ml-rf-persist \
  --tag video --strip --hint "native/build.sh" \
  --why "bind persistence silently degrades without it"

if [ "$RF_ROLE" = "gnd" ]; then
  # Sends the HUD's own RF commands (channel, scan, bind) from a shell, so those paths are
  # reachable without the UI.
  stage "$US/build/ml-rfcmd" usr/local/bin/ml-rfcmd \
    --tag video --strip --hint "make -C userspace rfcmd"
fi

# ml-aed is the auto-exposure daemon, which only a board with a camera has any use for. Gated on
# its own service the same way ml-ledd is: the device overlay is already staged at this point, so
# the daemon and the service that starts it cannot end up disagreeing about which boards get it.
# Without the binary the camera still streams, at the fixed operating point the driver commits
# before stream-on, so this is `stage` and not `stage_req`.
if [ -f "$STAGE/etc/init.d/ml-air-ae" ]; then
  stage "$US/build/ml-aed" usr/local/bin/ml-aed \
    --tag ml-aed --strip --hint "make -C userspace aed"
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
if [ -f "$STAGE/etc/umtprd.conf" ]; then
  sed -i -e "s|@USB_PRODUCT@|$USB_PRODUCT|" "$STAGE/etc/umtprd.conf"
fi

# Template the hardware version into the air-unit link service. File-presence gated: only an
# air-role overlay ships it, and only those profiles set HW_VERSION.
if [ -f "$STAGE/etc/init.d/ml-air-link" ]; then
  sed -i -e "s|@HW_VERSION@|${HW_VERSION:-V1.0}|" "$STAGE/etc/init.d/ml-air-link"
fi
