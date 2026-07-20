# Open dev-platform rootfs for Artosyn devices

A reproducible Alpine Linux aarch64 root filesystem for the open mainline Linux 6.18 kernel on Artosyn Proxima-class devices (goggles, air units, video receivers), packaged as a UBIFS+UBI image to flash to the device's SPI-NAND partition. It gives you a modern userland to bring up and debug the open kernel on the device. It builds in two flavors (`FLAVOR=dev|slim`, see Build below): `dev` is the full debug platform (networking + SSH + scp/sftp + `apk` + introspection tooling), `slim` is a lean production image. The per-board specifics (geometry, identity, addressing) live in a device profile (see below).

## What the image is

`build/rootfs.ubi` is a UBI image containing a single auto-resizing dynamic volume named `rootfs` that holds an uncompressed UBIFS filesystem. It is Alpine 3.24.1 aarch64 built fresh with `apk.static --initdb`. The base package set (both flavors) is intentionally tiny: `alpine-base`, `busybox`, `openrc`, `dropbear` (SSH), `iproute2` - busybox supplies the `less`/`mount`/`blkid`/`fdisk`/`losetup`/`getty` applets, so no `util-linux` or `less` package is needed. The `dev` flavor adds `openssh-sftp-server` (enables scp/sftp), `util-linux`, and `strace`/`tcpdump`/`htop`; `slim` ships the base only. The build is pinned (Alpine 3.24.1 minirootfs sha256-verified for the signing keys, apk-tools-static 3.0.6-r0) and runs entirely on the host with no root and without touching any hardware, under `fakeroot` so the files land in the image as `root:root`.

Root password is `libre` and the hostname is `artosyn-libre`. Dropbear permits root password login and generates its host keys on first boot into `/etc/dropbear`. In the `dev` flavor `openssh-sftp-server` is installed at `/usr/lib/ssh/sftp-server`, which dropbear serves as its SFTP subsystem automatically (no config), so `scp`, `sftp`, and file-manager mounts work; `slim` has no scp (update it by reflashing).

Quality-of-life (both flavors): a `MissingLynk` ASCII banner (`/etc/motd`) plus an `ml-info` status line (hostname, IPs, kernel, booted UBI volume, flavor, staged-module count) on interactive login via `/etc/profile.d/10-ml.sh` (which also sets a slot-aware prompt, color `ls`, and the `less` pager); a getty on the debug UART (`ttyS0`, `/etc/inittab`) for a network-independent login; and clock handling suited to a headless box - the battery-backed RTC drives the system clock at boot (openrc `hwclock` service, boot runlevel), and a best-effort, offline-safe one-shot NTP sync (`/etc/init.d/ntp-oneshot`, busybox `ntpd -q` wrapped in `timeout` and backgrounded) corrects RTC drift when the internet is reachable and writes the result back to the RTC, while doing nothing (no daemon, no boot delay) offline.

On boot an OpenRC service (`/etc/init.d/usb-gadget`, in the `boot` runlevel) brings up a USB CDC-ECM gadget over the dwc2 UDC via configfs, with fixed locally-administered MACs (`DE:AD:BE:EF:CA:FE` device side, `DE:AD:BE:EF:F0:0D` host side) so the host network interface name stays stable across reboots. It addresses the device-side interface `192.168.3.100/24` and routes default via the host at `192.168.3.222` (the host does NAT, so `apk add` works once `/etc/apk/repositories` points at the Alpine latest-stable mirrors). The gadget service declares `provide net`, which satisfies dropbear's `need net`, so SSH comes up on `192.168.3.100:22` after enumeration.

## Build

Run on the host (needs internet, `fakeroot`, `openssl`, `qemu-aarch64-static` from `qemu-user-static`, and `mkfs.ubifs`/`ubinize` from `mtd-utils`). The whole build runs as plain host processes, no container and no root. The only downloads are the pinned, sha256-verified Alpine build inputs (`apk.static` and the signing keys), cached under the gitignored `build/dl/`:

```sh
build.sh                       # dev flavor (default), default device (betafpv-vr04-goggle)
FLAVOR=slim build.sh           # lean production image
build.sh <device-name>         # or for another device (still FLAVOR-aware)
```

The flavor is chosen with the `FLAVOR` env var (`dev` default, or `slim`); the positional arg is the device name, resolving `devices/<name>/board.conf` + `devices/<name>/overlay/`. `dev` is the full bring-up platform (scp/sftp, util-linux, strace/tcpdump/htop); `slim` strips those to a 5-package busybox base for a smaller image. Both record their identity in `/etc/ml-flavor`. It prints the flavor, the final `rootfs.ubi` size, and the installed package list. All regenerable output (the images, the scratch `work/` tree, and the cached, verified downloads in `dl/`) lands under the gitignored `build/`; re-running rebuilds from those cached downloads.

The static config files dropped into the image live as an editable tree under `skeleton/` (copied verbatim into the rootfs); the gadget service `skeleton/etc/init.d/usb-gadget` carries `@...@` placeholders that `build.sh` fills in from the device profile. Only the handful of files that depend on build variables (`/etc/hostname`, `/etc/hosts`, `/etc/apk/repositories`) are still generated in `build.sh`. The fakeroot build body is `scripts/make-rootfs.sh`.

### Kernel modules (optional, baked in when available)

If the kernel modules have been built (`../kernel/modules/build.sh`, which stages them depmod'd under the kernel build dir), `build.sh` copies that staged tree into the image at `/lib/modules/<kver>/`. If the staged tree is absent the build just logs that it is skipping modules and produces a module-less image; the final report says which of the two happened. This is the only place the rootfs build reaches outside `rootfs/` (it sources `../kernel/scripts/pin.env` to locate the kernel build dir; override with `MODULES_STAGE=`).

Whether they auto-load depends on the flavor. In `dev` nothing loads them: the coldplug/`modules` services below are left disabled, so a fresh boot is identical with or without the modules until you `insmod`/`modprobe` by hand (this is the bring-up image, where manual control is the point; `devfs`/devtmpfs still creates the `/dev` nodes for anything you load). In `slim` the box comes up as a working device the idiomatic Linux way - the devicetree drives it, via stock services, not a bespoke loader. Three OpenRC services are enabled for this flavor (`boot` runlevel): `mdev` (provides `/dev` and installs the hotplug helper), `hwdrivers` (the modalias coldplug: `modprobe -b` over every `/sys` `modalias`), and `modules` (processes `/etc/modules-load.d/*.conf`). So every on-board driver that has a DT node autoloads itself from that node - the display controller/DSI (`artosyn,vo`/`artosyn,dsi`), buttons (`artosyn,adc` → `adc-keys`), buzzer/backlight (`artosyn,ar9301-pwm`), SoC temp, GPIO, and the wave5 codec (`ti,j721s2-wave521c`). No driver list to maintain: adding a new no-param DT driver to the kernel whitelist makes it autoload with zero rootfs change, and only devices that are actually present load.

Two small declarative config files handle the exceptions:

- `/etc/modules-load.d/ml.conf` force-loads the modules that have no DT node or need params (the `modules` service passes trailing args straight to `modprobe`): the DSI panel driver `panel-qy45043a0` (a DSI child, force-loaded because DSI-bus modalias coldplug is unreliable), plus `ml_dmablit`/`ml_mmzheap`/`ar_scaler` (the DVR 720p HW downscale engine, standalone since its `ar_osal` dependency was dropped; loaded here so its first-probe CGU poke happens before the video stack is up). The mmc host nodes (`mmc@1c00000` microSD + `mmc@1b00000` AR8030) live in the boot DTS, so the coldplug binds the SD card directly via the mainline `dw_mmc` core (`=y`) + `dw_mci-artosyn` (param-less; it derives the clock from the node's `clock-frequency`).
- `/etc/modprobe.d/ml.conf` blacklists what coldplug must NOT autoload despite having a base-DTB node (coldplug uses `modprobe -b`, which honors the blacklist; the deliberate `modules`/`ml-linkd`/`load.sh` loads bypass `-b`): the RF link `artosyn_sdio` (owned by `ml-linkd`, insmod'd explicitly with firmware params).

Note on the SD card / RF coupling: `slim` owns the SDIO/SD *host stack* at boot (the DTS mmc nodes + `dw_mci-artosyn`), including the AR8030 SDIO host (the chip stays in reset at boot, so that host sits idle until `ml-rf-bringup` releases it and rescans). Both hosts run the driver's default clock programming (SEL `0x80`, phase 0, the stock-faithful values from the slot-A register diff); the old `clk_sel=135 clk_cfg=2` bring-up override (misread-dump values) is retired from `modprobe.d`, with a restore line documented there should a host fail to enumerate. The status LED needs no module either way: its SPI/spidev/leds-gpio drivers are built in (`=y`) and it is driven from userspace over the built-in spidev node. Loads are best-effort (a failure warns but never blocks boot), so SSH and the serial console always come up.

Once the drivers are up, `slim` plays a short power-on chime through the buzzer: an OpenRC service (`/etc/init.d/ml-chime`, `default` runlevel, ordered `after hwdrivers` so the coldplug has bound `artosyn_pwm` and the pwmchip exists) walks a small melody through the `/sys/class/pwm` sysfs ABI - no SDK, no `/dev/mem` - the same path the stock firmware uses (RE'd from `customerHmBuzzerEnable`, reference impl `../kernel/test_tools/buzzer_test.c`). The buzzer is channel 0 of the 2nd PWM controller (`pwm@1002000`); each note holds a fixed 50% duty and steps the period for pitch, and the melody (edit the `MELODY` list of `freqHz:durationMs` tokens to change the tune) plays in a backgrounded subshell so boot never waits on it. Best-effort like the rest: a missing pwmchip or a failed write just skips the chime.

Both flavors run display bring-up + boot splash at boot: `/etc/init.d/ml-display` (`default` runlevel) modprobes the DRM display chain (idempotent, so it works with and without the slim coldplug), starts the static `ml-drmfd` DRM-master broker (the session anchor every later display client - `ml-pipeline`, `ml-hud` - attaches to), paints the vendor mountain (`/usr/local/share/nosignal.yuv`, raw I420 1920x1080 on the DRM primary via the static raw-ioctl `ml-splash`), and only then turns the backlight on, already at the persisted HUD brightness (`goggles.brightness`). The kernel never drives the backlight (the panel driver does not attach it; pwm-backlight probes OFF), so the panel stays fully dark until the splash is committed - no backlit-black window and no brightness step when ml-hud starts. Splash visible = display drivers healthy; later video/OSD planes simply cover it and it reappears when they stop (stock's no-signal behavior). The binaries come from `../userspace/gstreamer/src/build.sh` and the asset from your own vendor dump (`out/P1_GND/...`, proprietary, git-ignored) - `build.sh` stages whatever is present and the service warns and skips at boot for anything missing. Best-effort: never blocks or fails the boot.

The RF video pipeline is the production (rootfs) track: `build.sh` stages the standalone fully-static `ml-pipeline` (built by `../userspace/gstreamer/scripts/build-static.sh` - whole GStreamer + the curated plugin set baked in, no `/mnt/gst`, no plugin registry; details in `../userspace/gstreamer/README.md`) and the static RF daemon `ml-linkd` into `/usr/local/bin/`. With `ml-drmfd` + `ml-hud` (above) and the codec firmware + wave5/`ml_dmablit` modules already in this rootfs, RF video runs with **no SD card**. The launcher `/usr/local/bin/ml-video-up` (from `skeleton/`) checks the DRM broker, starts `ml-linkd` if down, and runs `ML_COMPOSE=1 ml-pipeline rf` - it is a manual/explicit launch for now, not yet a boot service. The alternative development track is the dynamic GStreamer squashfs on the SD card (`../userspace/gstreamer/scripts/deploy.sh`). Flash the **`slim`** flavor for production: the static binary fits comfortably (rootfs ~34 MiB, 75% of the 45 MiB partition), whereas the `dev` flavor's debug tools push it over.

### Device profiles

Everything per-device lives in `devices/<name>/`: `board.conf` (target hostname/password, the USB ECM addressing and MACs, and the NAND/UBI geometry + target partition) and `overlay/` (the device-specific OpenRC services + `modules-load.d`, layered on the shared `skeleton/`). `build.sh` takes the device name (first argument, default `betafpv-vr04-goggle`) and resolves both. To add a device, create `devices/<name>/board.conf` (+ `overlay/` for any device-specific services) and pass `<name>`. The build fails early if `board.conf` is missing a required variable. Service enablement (`scripts/make-rootfs.sh`) is file-presence-gated, so a device whose overlay omits a service (e.g. no `ml-display`) simply never enables it.

## Flash

For the goggle there is a guarded host-side flasher: `../glue/flash/flash-rootfs-b.sh` streams the image to a slot-A-booted device over SSH and ubiformats `userapp1` only (see `../glue/README.md`). The rest of this section is the generic on-device procedure it automates.

Flash the UBI image to the target MTD character device with `ubiformat` (this writes the UBI image with its erase-counter/volume layout; do NOT use `nandwrite` or `dd`). The partition name is the profile's `PARTITION` (`userapp1` for the goggle); substitute your own below. Run it from a context that actually has the partition (for example the existing vendor recovery/initramfs, or a booted system where `userapp1` is visible in `/proc/mtd`).

Identify the right `mtdN` first:

```sh
cat /proc/mtd                              # find the number whose name is "userapp1"
ubiformat /dev/mtdN -f rootfs.ubi          # mtdN = the userapp1 partition
```

`ubiformat -f` erases the partition, writes the image, and preserves/initialises erase counters. The volume is flagged `autoresize`, so on first attach UBI grows the `rootfs` volume to fill the whole partition.

## Boot

Point the kernel at the UBI volume:

```
ubi.mtd=userapp1 root=ubi:rootfs rootfstype=ubifs rw
```

## NAND / UBI geometry (from the live kernel, set per board in the device profile)

For the goggle (`devices/betafpv-vr04-goggle/board.conf`): PEB 131072 (128 KiB), min I/O 2048, sub-page 2048, VID header offset 2048, data offset 4096, UBIFS LEB 126976, `userapp1` = 360 PEBs (45 MiB). The UBIFS image is built with `mkfs.ubifs -m 2048 -e 126976 -c 350 -x none` (no compression, to avoid any kernel decompressor dependency for the first cut) and wrapped with `ubinize -m 2048 -p 131072 -s 2048`.
