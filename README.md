# Open dev-platform rootfs for Artosyn devices

A reproducible Alpine Linux aarch64 root filesystem for the open mainline Linux 6.18 kernel on Artosyn Proxima-class devices, packaged as a UBIFS+UBI image to flash to the device's SPI-NAND partition.

Supported devices:

| Device | Hardware | Peripherals |
|---|---|---|
| `betafpv-vr04-goggle` | BetaFPV VR04 HD goggle | DSI panel, microSD, keypad, RF ground (RX) role |
| `betafpv-vr04-air` | BetaFPV VR04 HD air unit | camera, no panel, no SD, RF air (TX) role |

Everything per-board - identity, addressing, NAND geometry, which peripherals exist - lives in a [device profile](#device-profiles); the rest of the tree is device-neutral, so adding a device is a new profile rather than a change here.

It builds in two flavors (`FLAVOR=dev|slim`): `dev` adds SSH file transfer and introspection tooling for bring-up and debugging, `slim` is the lean production image. Both boot the device as a working unit; the flavor only changes which packages ship.

## What the image is

`build/rootfs-<device>.ubi` is a UBI image containing a single auto-resizing dynamic volume named `rootfs` holding an uncompressed UBIFS filesystem. It is Alpine 3.24.1 aarch64, built fresh with `apk.static --initdb`.

The base package set (both flavors) is intentionally tiny: `alpine-base`, `busybox`, `openrc`, `dropbear` (SSH), `iproute2`, `exfatprogs` (busybox has no `mkfs.exfat`, which the SD format needs). Busybox supplies the `less`/`mount`/`blkid`/`fdisk`/`losetup`/`getty` applets, so no `util-linux` or `less` package is needed. The `dev` flavor adds `openssh-sftp-server` (enables scp/sftp), `util-linux`, and `strace`/`tcpdump`/`htop`.

The build is pinned (Alpine 3.24.1 minirootfs sha256-verified for the signing keys, apk-tools-static 3.0.6-r0) and runs entirely on the host with no root and without touching any hardware, under `fakeroot` so the files land in the image as `root:root`.

The image records its own identity: `/etc/ml-flavor` (`dev`|`slim`) and `/etc/ml-release` (open firmware version, kernel version, rootfs/kernel git-describes, build time, device), so on-device tooling can answer "what image is this" from inside the slot.

Hostname and root password come from the device profile; the profiles shipped here all use the password `libre`. Dropbear permits root password login and generates its host keys on first boot into `/etc/dropbear`. In the `dev` flavor `openssh-sftp-server` lands at `/usr/lib/ssh/sftp-server`, which dropbear serves as its SFTP subsystem automatically (no config), so `scp`, `sftp`, and file-manager mounts work; `slim` has no scp - update it by reflashing.

A getty runs on the debug UART (`ttyS0`, `/etc/inittab`) for a network-independent login. `/tmp` is a 32 MB exec-allowed tmpfs and `/var/log` an 8 MB tmpfs (`/etc/fstab`), so nothing writes to the read-only NAND at runtime.

### Networking

The `usb-gadget` service brings up a USB composite gadget on the dwc2 UDC via configfs: CDC-ECM (network/SSH) and CDC-ACM (config/recovery console) always, plus MTP (exposes the SD-card recordings) on devices with a card, best-effort - if `umtprd` is absent or slow to come ready, the gadget binds ECM-only. MTP never costs SSH.

Addressing is a shared-subnet scheme keyed on a per-device index NN, so several devices can be plugged into one host at the same time: fixed locally-administered MACs (`EE:EE:…:NN` device side, `AA:AA:…:NN` host side) give a stable host interface name, the device side is `192.168.3.(100+NN)`, and the default route goes via the host bridge at `192.168.3.222`, which NATs so `apk add` works. NN=0 (`192.168.3.100`) is reserved for stock, unflashed units. `minidhcpd` hands out a single lease on the gadget link so a phone or PC running a DHCP client gets an address without manual configuration.

The gadget service declares `provide net`, which satisfies dropbear's `need net`, so SSH comes up once the host enumerates the device.

## Build

Run on the host (needs `fakeroot`, `openssl`, `curl`, `qemu-aarch64-static` from `qemu-user-static`, and `mkfs.ubifs`/`ubinize` from `mtd-utils`). The whole build runs as plain host processes, no container and no root. The only downloads are the pinned, sha256-verified Alpine build inputs (`apk.static` and the signing keys), cached under `build/dl/`:

```sh
build.sh betafpv-vr04-goggle              # dev flavor (default); the device name is required
FLAVOR=slim build.sh betafpv-vr04-goggle  # lean production image
FLAVOR=slim build.sh betafpv-vr04-air
```

The positional arg is the device name, resolving `devices/<name>/board.conf` + `devices/<name>/overlay/`. Images are named per device (`rootfs-<device>.ubi` / `.ubifs`), so builds for different devices coexist; the scratch `work/` tree and the cached downloads in `dl/` are shared. All regenerable output lands under `build/`. Re-running rebuilds from the cached downloads.

The build prints the flavor, the installed package list, the module count, and the image size as a percentage of the target partition, and fails if the image does not fit. Flash the **`slim`** flavor for production: the partition is tight and the `dev` flavor's extra tooling can push it over.

The static config files dropped into the image live as an editable tree under `skeleton/`, layered with `devices/<name>/overlay/`. Only the handful of files that depend on build variables are generated in `build.sh` (`/etc/hostname`, `/etc/hosts`, `/etc/apk/repositories`, and the `@…@` placeholders in the gadget service, the MTP config, and the air-unit link service). The fakeroot build body is `scripts/make-rootfs.sh`.

### Kernel modules

If the kernel modules have been built (`../kernel/modules/build.sh`, which stages them depmod'd under the kernel build dir), `build.sh` copies that staged tree into the image at `/lib/modules/<kver>/`; if the staged tree is absent the build logs that it is skipping modules and produces a module-less image. On a device with `HAS_DISPLAY=1` a *present but incomplete* stage is a hard error rather than a skip - a stale or no-display stage lacks the DRM modules and the panel then stays dark with no visible cause.

> This is the only place the rootfs build reaches outside `rootfs/` (it sources `../kernel/scripts/pin.env` to locate the kernel build dir; override with `MODULES_STAGE=`).

### Staged firmware and binaries

`build.sh` bakes the proprietary blobs the open stack needs into `/lib/firmware` from `../firmware/bin/slot-a/` (git-ignored; repopulate from your own device with `../glue/fetch/fetch-vendor-blobs.sh`), so a flashed image needs no host push:

- **Codec firmware** - `chagall.bin` as `cnm/wave521c_k3_codec_fw.bin`, which `wave5.ko` requests on load.
- **RF baseband firmware** - the AR8030 image + config for this device's `RF_ROLE`. On the ground role the captured race-band config is also rewritten into a normal-band variant (the band is the config's `chan_valid_bmp` and only reaches the chip at firmware upload, so each band is a whole blob and switching one costs a boot).
- **ISP tuning blob** - air unit only, and a *hard build error* if missing or the wrong size: `ar-isp` merely warns and runs unconfigured, and an unconfigured ISP produces garbage that still encodes, transmits and decodes with every counter healthy, so the failure is invisible everywhere downstream.

The open stack's own binaries are staged into `/usr/local/bin` from `../userspace/`, `../native/` and `../glue/`; `build.sh` is the authoritative list, and each entry names the command that builds it. They are independently optional: staged if built, skipped with a log line otherwise, and the service that uses it then warns and skips at boot - so the image always builds on a fresh clone, it just lacks that feature. Two entries are hard build errors instead of skips: `ml-rf-bringup` (no RF bring-up means no video at all) and the SD helper library `/usr/local/lib/ml-sd.sh`.

## Boot services

The device comes up as a working unit on its own: network and SSH over USB, the drivers bound from the devicetree, the persistent store mounted, and - where the hardware has them - display, HUD, video and recording. The shared services live in `skeleton/etc/init.d/`, the device-specific ones in `devices/<name>/overlay/etc/init.d/`, and each carries a header comment explaining what it does and why it is ordered where it is. `scripts/make-rootfs.sh` is where they are enabled.

Three rules apply across all of them:

- **Enablement is file-presence-gated.** A device whose overlay omits a service simply never enables it - there is no per-device list to maintain.
- **The `boot` runlevel carries what must be early** (gadget/network, module coldplug, `/usrdata`, status LED, display bring-up and splash); the `default` runlevel carries the daemons on top of that.
- **Everything is best-effort.** A missing binary, driver or asset logs a warning and boot continues, so the serial console and SSH always come up - which also means a dark panel or absent video is a real fault, not a missing file.

The alternative development track for video is the dynamic GStreamer squashfs on the SD card (`../userspace/gstreamer/scripts/deploy.sh`); the rootfs track is fully static and needs no card.

## Module loading

Both flavors use the same single path: the devicetree drives it, via stock services. `mdev` provides `/dev` and installs the hotplug helper, `hwdrivers` is the modalias coldplug (`modprobe -b` over every `/sys` `modalias`), and `modules` processes `/etc/modules-load.d/*.conf`. So every on-board driver with a DT node autoloads from that node, with no driver list to maintain - adding a new param-less DT driver to the kernel whitelist makes it autoload with zero rootfs change, and only devices actually present load.

Two declarative files handle the exceptions:

- **`/etc/modules-load.d/ml.conf`** (per device, in the overlay) force-loads modules that have no DT node, need parameters, or whose coldplug is unreliable. The `modules` service passes trailing args straight to `modprobe`.
- **`/etc/modprobe.d/ml.conf`** (shared) blacklists what coldplug must *not* autoload despite having a DT node - notably the RF driver `artosyn_sdio`, which is owned by the link services and insmod'd explicitly with firmware parameters. Coldplug uses `modprobe -b`, which honors the blacklist; the deliberate loads bypass `-b` and still work.

The status LED needs no module: its SPI/spidev/leds-gpio drivers are built in and it is driven from userspace over the built-in spidev node.

## Device profiles

Everything per-device lives in `devices/<name>/`:

- **`board.conf`** - hostname and root password, USB product string, the ECM addressing and MACs, feature flags (`HAS_SD`, `HAS_DISPLAY`, `RF_ROLE`), and the NAND/UBI geometry plus target partition. The build fails early if a required variable is missing.
- **`overlay/`** - the device-specific OpenRC services and `modules-load.d`, layered on the shared `skeleton/`.

To add a device, create `devices/<name>/board.conf` (plus an `overlay/` for any device-specific services) and pass `<name>` to `build.sh`. The same device names are used by the root `Makefile` and `kernel/devices/<name>/`.

## Flash

For the goggle there is a guarded host-side flasher: `../glue/flash/flash-rootfs-b.sh` streams the image to a slot-A-booted device over SSH and ubiformats the target partition only (see `../glue/README.md`). The rest of this section is the generic on-device procedure it automates.

Write the UBI image to the target MTD character device with `ubiformat` - this writes the UBI image with its erase-counter/volume layout, so do **not** use `nandwrite` or `dd`. The partition name is the profile's `PARTITION`. Run it from a context that actually has the partition, for example the vendor recovery/initramfs or a booted system where the partition is visible in `/proc/mtd`:

```sh
cat /proc/mtd                                # find the number whose name matches PARTITION
ubiformat /dev/mtdN -f rootfs-<device>.ubi
```

`ubiformat -f` erases the partition, writes the image, and preserves/initializes erase counters. The volume is flagged `autoresize`, so on first attach UBI grows the `rootfs` volume to fill the whole partition.

## Boot

Point the kernel at the UBI volume (`build.sh` prints the exact line for the device it built):

```
ubi.mtd=<partition> root=ubi:rootfs rootfstype=ubifs rw
```

## Support

This is unpaid nights-and-weekends work: reverse engineering, bricked-and-recovered hardware, and serial-console archaeology. Everything here is free and open, but if it saved you time or got video flowing off your goggles, you can [buy me a coffee](https://buymeacoffee.com/stylesuxx) - it genuinely helps keep work like this going.
