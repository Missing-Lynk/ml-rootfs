# MissingLynk rootfs

This repo builds the Alpine aarch64 root filesystem for [MissingLynk](https://github.com/Missing-Lynk/MissingLynk) devices. The output is a UBIFS-in-UBI image for the slot-B `userapp1` partition. It is meant to be used from the wrapper checkout, alongside `kernel/`, `userspace/`, `native/`, `glue/` and the private vendor blobs under `firmware/`.

Supported devices:

| Device | Hardware | Peripherals |
|---|---|---|
| `betafpv-vr04-goggle` | BetaFPV VR04 HD goggle | DSI panel, microSD, keypad, RF ground (RX) role |
| `betafpv-vr04-air` | BetaFPV VR04 HD air unit | camera, no panel, no SD, RF air (TX) role |

Everything per-board lives in a [device profile](#device-profiles): identity, USB addressing, NAND geometry and hardware capabilities. The shared tree is device-neutral.

It builds two flavors: `slim` for production and `dev` for bring-up. Both boot as working devices; `dev` adds file-transfer and diagnostic packages.

## What the image is

`build/rootfs-<device>.ubi` contains one auto-resizing dynamic UBI volume named `rootfs`, holding an uncompressed Alpine 3.24.1 UBIFS filesystem.

The base package set is small: `alpine-base`, `busybox`, `openrc`, `dropbear`, `iproute2` and `exfatprogs`. The `dev` flavor adds `openssh-sftp-server`, `util-linux`, `strace`, `tcpdump` and `htop`.

The build is pinned (Alpine 3.24.1 minirootfs sha256-verified for the signing keys, apk-tools-static 3.0.6-r0) and runs entirely on the host with no root and without touching any hardware, under `fakeroot` so the files land in the image as `root:root`.

This repo holds the rootfs config tree, shell helpers, device profiles and build machinery. Compiled binaries come from sibling project trees and are staged at build time.

Sibling inputs in the wrapper checkout:

| Path | Repo | Supplies |
|---|---|---|
| `../userspace/` | [ml-userspace](https://github.com/Missing-Lynk/ml-userspace) | video pipeline, RF daemon, HUD, display broker, LED daemon, shared assets |
| `../kernel/` | [ml-kernel](https://github.com/Missing-Lynk/ml-kernel) | the kernel and its loadable modules |
| `../native/`, `../glue/`, `../firmware/` | [MissingLynk](https://github.com/Missing-Lynk/MissingLynk) | static helpers, host-side tooling and vendor blobs from the umbrella repo |

The image records its own identity: `/etc/ml-flavor` (`dev`|`slim`) and `/etc/ml-release` (open firmware version, kernel version, rootfs/kernel git-describes, build time, device), so on-device tooling can answer "what image is this" from inside the slot.

Hostname and root password come from the device profile; the profiles shipped here use `libre`. Dropbear permits root password login and generates host keys on first boot. The `dev` flavor includes SFTP support; `slim` is updated by reflashing.

A getty runs on the debug UART (`ttyS0`) and on the USB ACM recovery console (`ttyGS0`). `/tmp` is a 32 MB exec-allowed tmpfs and `/var/log` is an 8 MB tmpfs.

### Networking

The `usb-gadget` service brings up CDC-ECM for SSH and CDC-ACM for the recovery console. Devices with SD support also get best-effort MTP for recordings; MTP failures degrade to ECM+ACM.

USB networking uses fixed per-device MACs and addresses on `192.168.3.0/24`, so multiple open devices can share one host bridge. The device address is `192.168.3.(100+NN)`; `NN=0` is reserved for stock units. `minidhcpd` offers a single host-side lease when present.

The gadget service declares `provide net`, which satisfies dropbear's `need net`, so SSH comes up once the host enumerates the device.

## Build

Run on an x86_64 host with `fakeroot`, `openssl`, `curl`, `qemu-aarch64-static`, `mkfs.ubifs` and `ubinize`. The build uses no root and no container. It downloads only pinned Alpine inputs into `build/dl/`; another host architecture needs an `apk.static` checksum pin before it is accepted:

```sh
build.sh betafpv-vr04-goggle              # dev flavor (default); the device name is required
FLAVOR=slim build.sh betafpv-vr04-goggle  # lean production image
FLAVOR=slim build.sh betafpv-vr04-air
```

The positional arg selects `devices/<name>/board.conf` and `devices/<name>/overlay/`. All output lands under `build/`; images are named per device.

The build prints installed packages, module count and image size, and fails if the image exceeds the device profile's partition size. Flash `slim` for production.

Static rootfs files live under `skeleton/`; device overlays layer on top. `build.sh` validates the profile and fetches the pinned Alpine inputs, sources `scripts/stage-payload.sh` to stage the tree, then runs `scripts/make-rootfs.sh` under `fakeroot` to build and image it.

### Kernel modules

If `../kernel/modules/build.sh` has staged modules, `build.sh` copies them into `/lib/modules/<kver>/`. An absent stage is allowed; a present but incomplete display-capable stage is fatal. Override with `MODULES_STAGE=`.

### Staged firmware and binaries

`scripts/stage-payload.sh` (sourced by `build.sh`) bakes required proprietary blobs into `/lib/firmware` from `../firmware/bin/slot-a/` (populate it from your own device with `../glue/fetch/fetch-vendor-blobs.sh`):

- **Codec firmware** - `chagall.bin` as `cnm/wave521c_k3_codec_fw.bin`, which `wave5.ko` requests on load.
- **RF baseband firmware** - the AR8030 image and config for this device's `RF_ROLE`.
- **ISP tuning blob** - air unit only; missing or wrong-sized tuning is fatal.

Open-stack binaries are staged into `/usr/local/bin` from the sibling trees. Role-critical binaries are required; convenience and diagnostic helpers are staged when present. `scripts/stage-payload.sh` is the authoritative staging list, and each entry names the command that builds it.

`make-rootfs.sh` also fails if `/usr/local/lib/ml-sd.sh` is missing, because SD mount and format share that selector.

## Boot services

The image boots into a working unit: USB networking and SSH, module coldplug, `/usrdata`, and the role-specific display/video services. Shared services live in `skeleton/etc/init.d/`; device-specific services live in `devices/<name>/overlay/etc/init.d/`; `scripts/make-rootfs.sh` enables them.

Three rules apply across all of them:

- **Enablement is file-presence-gated.** A device whose overlay omits a service never enables it.
- **The `boot` runlevel carries what must be early** (gadget/network, module coldplug, `/usrdata`, status LED, display bring-up and splash); the `default` runlevel carries the daemons on top of that.
- **Boot stays recoverable.** Noncritical failures log warnings and leave serial/SSH available.

The alternative development track for video is the dynamic GStreamer squashfs on the SD card (`../userspace/gstreamer/scripts/deploy.sh`); the rootfs track is fully static and needs no card.

## Module loading

Both flavors use the same module path: DT modalias coldplug through `mdev`/`hwdrivers`, plus `/etc/modules-load.d/*.conf` for force-loaded exceptions.

Two declarative files handle the exceptions:

- **`/etc/modules-load.d/ml.conf`** force-loads modules with no DT node, required parameters, or unreliable coldplug.
- **`/etc/modprobe.d/ml.conf`** blacklists modules that coldplug must leave to a service, especially `artosyn_sdio`.

## Device profiles

Each device profile lives in `devices/<name>/`:

- **`board.conf`** - hostname and root password, USB product string, the ECM addressing and MACs, feature flags (`HAS_SD`, `HAS_DISPLAY`, `RF_ROLE`), and the NAND/UBI geometry plus target partition. The build fails early if a required variable is missing.

  The build branches on these flags, not on device names. `RF_ROLE` selects the air or ground RF/video payload.
- **`overlay/`** - the device-specific OpenRC services and `modules-load.d`, layered on the shared `skeleton/`.

### Adding a device

The same device name is used here, by the root `Makefile`, and by `kernel/devices/<name>/`.

1. **`devices/<name>/board.conf`** - copy the nearest existing profile and change the values. The build fails early on a missing required variable, a `HAS_*` flag that is not `0`/`1`, or an `RF_ROLE` that is not `air`/`ground`, so a half-filled profile stops the build rather than producing a quietly wrong image.
2. **`devices/<name>/overlay/`** - only what differs from `skeleton/`: the board's OpenRC services and its `modules-load.d/ml.conf`. Files here are layered on the shared tree and override it at the same path. Optional; a board that needs nothing extra needs no overlay.
3. **A row in the supported-devices table** at the top of this README.

A board that reuses existing services needs nothing beyond those three steps. Two cases go further:

- **A new service name** needs an entry in the `BOOT_SERVICES` or `DEFAULT_SERVICES` list in `scripts/make-rootfs.sh`; run order comes from the service's own `depend()`, not from that list.
- **Staging that no flag can express** - a new firmware blob, or a binary no current board uses - needs a `scripts/stage-payload.sh` change. Anything a `HAS_*` flag or `RF_ROLE` already covers does not: the build branches on capability, never on device name.

Put overlay executables in `/usr/local/bin`; `make-rootfs.sh` force-sets executable bits there and on `/etc/init.d/*`.

## Flash

Use the wrapper repo for normal flashing; its guarded target writes slot-B `userapp1` only. Generic manual flow:

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

Everything here is free and open. The work behind it is unpaid nights and weekends: reverse engineering, bricked and recovered hardware, and a lot of time on a serial console. If it saved you some of your own, you can [buy me a coffee](https://buymeacoffee.com/stylesuxx).

Not bought the hardware yet? The [project README](https://github.com/Missing-Lynk/MissingLynk#support-this-project) has affiliate links that support the work at no extra cost to you.
