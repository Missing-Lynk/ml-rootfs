# shellcheck shell=sh  # sourced, not executed: no shebang of its own
# Shared microSD block-device selection. Sourced by ml-sdmount (which mounts the card) and by
# ml-sdformat (which wipes it). One rule in one place: when the two disagree, Format either cannot
# find the card the system just mounted, or writes over a device the mount never chose.
#
# The index is not fixed. The SoC has two MMC hosts: the AR8030 RF chip on mmc0 (an SDIO function,
# so it contributes no block device) and the microSD slot on mmc1. There is no DT alias pinning
# either, so mmc_alloc_host() takes host indices from an IDA in probe order, and the card is
# /dev/mmcblk0 when the RF host has not registered and /dev/mmcblk1 when it has. Any fixed index is
# therefore wrong in one of the two states.
#
# This board has no internal eMMC: every mmcblk node is the removable card. The card-type check
# below is there so that stays true by construction rather than by assumption, on a board that
# later grows soldered storage.
#
# Both sourcing scripts are #!/bin/sh, which on this image is busybox ash, where `local` is a
# builtin. shellcheck reports it against the POSIX subset instead.
# shellcheck disable=SC3043

# The whole-device node for the microSD (/dev/mmcblkN), or empty when no card is present. The glob
# is lexical, so the lowest index wins if a board ever presents two cards.
sd_card_device() {
	local sysdev
	local name
	for sysdev in /sys/block/mmcblk[0-9]; do
		[ -d "$sysdev" ] || continue
		# "SD" for a memory card; "MMC" is soldered eMMC and "SDIO"/"SDcombo" are not storage.
		[ "$(cat "$sysdev/device/type" 2>/dev/null)" = "SD" ] || continue
		name="${sysdev##*/}"
		if [ -b "/dev/$name" ]; then
			echo "/dev/$name"
			return
		fi
	done
}

# The node to mount for the card: its first partition when it has one, else the whole device (cards
# are sometimes formatted without a partition table). Empty when no card is present.
sd_mount_source() {
	local dev
	dev="$(sd_card_device)"
	[ -n "$dev" ] || return
	if [ -b "${dev}p1" ]; then
		echo "${dev}p1"
	else
		echo "$dev"
	fi
}

# The source mounted at $1 (last match wins, i.e. the top of any stack), or empty if nothing is.
sd_mounted_source() {
	awk -v mountpoint="$1" '$2 == mountpoint { source = $1 } END { print source }' /proc/mounts
}

# The whole device behind a mount source: /dev/mmcblk1p1 -> /dev/mmcblk1, and a whole-device source
# unchanged. Used to turn "what is mounted" into "what to format".
sd_whole_device() {
	echo "${1%%p[0-9]*}"
}
