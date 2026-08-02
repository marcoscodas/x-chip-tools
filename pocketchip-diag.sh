#!/bin/bash
# pocketchip-diag.sh
# Read-only diagnostic collector for planning a NAND -> USB rootfs migration
# on a PocketCHIP / Allwinner (sunxi) ARM SBC running Debian.
#
# This script makes NO changes to the system. It just gathers info and
# writes it to a single log file you can paste back for building the
# actual migration script.
#
# Run as root: sudo sh pocketchip-diag.sh

OUT="/root/pocketchip-diag-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee "$OUT") 2>&1

section() {
    echo ""
    echo "=================================================================="
    echo "== $1"
    echo "=================================================================="
}

run() {
    echo "+ $*"
    "$@" 2>&1
    echo ""
}

echo "PocketCHIP / Allwinner diagnostic collection"
echo "Started: $(date)"
echo "Output file: $OUT"

section "Basic system info"
run uname -a
run cat /etc/os-release
run cat /etc/debian_version
run cat /proc/version
run cat /proc/cmdline
run hostnamectl 2>/dev/null || true

section "CPU / SoC info"
run cat /proc/cpuinfo
run cat /proc/device-tree/model 2>/dev/null; echo ""
run cat /proc/device-tree/compatible 2>/dev/null; echo ""
run ls -la /proc/device-tree/ 2>/dev/null

section "Block devices"
run lsblk -a -o NAME,KNAME,MAJ:MIN,FSTYPE,SIZE,MOUNTPOINT,LABEL,UUID,PARTUUID,MODEL,TRAN
run cat /proc/partitions
run blkid
run fdisk -l 2>/dev/null
run parted -l 2>/dev/null

section "NAND / MTD info (sunxi typically uses raw NAND, not always /dev/mtd)"
run cat /proc/mtd
run ls -la /dev/mtd* 2>/dev/null
run ls -la /dev/nand* 2>/dev/null
run ls -la /dev/block/by-name/ 2>/dev/null
run cat /proc/mounts
run mount
run df -hT

section "UBI (if NAND is UBI-based, common on sunxi NAND images)"
run cat /proc/fs/ubifs/version 2>/dev/null
run ls -la /dev/ubi* 2>/dev/null
run ubinfo -a 2>/dev/null
run cat /sys/class/ubi/*/dev 2>/dev/null

section "Filesystem table and mounts"
run cat /etc/fstab
run findmnt

section "Kernel, initrd, dtb present on the system"
run ls -la /boot
run ls -la /boot/dtbs 2>/dev/null
run find /boot -iname "*.dtb" 2>/dev/null
run find / -maxdepth 3 -iname "*.dtb" 2>/dev/null

section "extlinux / syslinux boot config (if used)"
run find / -maxdepth 4 -iname "extlinux.conf" 2>/dev/null
for f in $(find / -maxdepth 4 -iname "extlinux.conf" 2>/dev/null); do
    echo "--- contents of $f ---"
    cat "$f"
    echo ""
done

section "boot.scr / boot script (if used)"
run find / -maxdepth 4 -iname "boot.scr" 2>/dev/null
run find / -maxdepth 4 -iname "boot.cmd" 2>/dev/null
for f in $(find / -maxdepth 4 -iname "boot.cmd" 2>/dev/null); do
    echo "--- contents of $f ---"
    cat "$f"
    echo ""
done

section "U-Boot environment (fw_printenv, if fw_env.config present)"
run cat /etc/fw_env.config 2>/dev/null
run fw_printenv 2>/dev/null
which fw_printenv 2>/dev/null

section "U-Boot version string (search for it in NAND-visible mtd/ubi, best effort)"
run strings /dev/mtd0 2>/dev/null | grep -i "u-boot" | head -20
run dmesg | grep -i "u-boot"
run dmesg | grep -i "uboot"

section "Sunxi-specific: script.bin / script.fex (old-style sunxi boards)"
run find / -maxdepth 4 -iname "script.bin" 2>/dev/null
run find / -maxdepth 4 -iname "*.fex" 2>/dev/null

section "dmesg boot log (full) - look for NAND, MMC, USB, root mount messages"
run dmesg

section "USB subsystem"
run lsusb
run lsusb -t
run ls -la /sys/bus/usb/devices/ 2>/dev/null
run cat /sys/kernel/debug/usb/devices 2>/dev/null

section "USB storage / host controller kernel modules currently loaded"
run lsmod
run lsmod | grep -Ei "usb|xhci|ehci|ohci|storage|sunxi|musb"

section "Initrd contents - check if usb storage/hcd modules are present"
INITRD=$(ls /boot/initrd.img-* 2>/dev/null | head -1)
if [ -n "$INITRD" ]; then
    echo "Checking initrd: $INITRD"
    run lsinitramfs "$INITRD"
else
    echo "No /boot/initrd.img-* found"
fi

section "Kernel modules available on disk related to USB/storage/sunxi"
run find /lib/modules -iname "*usb-storage*"
run find /lib/modules -iname "*xhci*"
run find /lib/modules -iname "*ehci*"
run find /lib/modules -iname "*ohci*"
run find /lib/modules -iname "*musb*"
run find /lib/modules -iname "*sunxi*"

section "Currently attached USB drive detection (plug your target USB drive in before running this if possible)"
run udevadm info --query=all --name=/dev/sda 2>/dev/null
run udevadm info --query=all --name=/dev/sda1 2>/dev/null

section "root filesystem details (currently running rootfs)"
run mount | grep " / "
run stat -f /
run df -h /

section "Disk space / size check (target must fit)"
run du -sxh /

section "systemd-boot / other boot managers, just in case"
run ls -la /boot/efi 2>/dev/null
run bootctl status 2>/dev/null

section "Existing swap (relevant if swap is on NAND partition)"
run cat /proc/swaps
run swapon --show

section "Environment summary for U-Boot (env tool paths, boot device hints)"
run cat /etc/u-boot/config 2>/dev/null
run find / -maxdepth 3 -iname "*u-boot*" 2>/dev/null

echo ""
echo "=================================================================="
echo "Diagnostic collection complete: $(date)"
echo "Log saved to: $OUT"
echo "=================================================================="
echo ""
echo "Please copy/paste the contents of $OUT back for building the"
echo "automated NAND -> USB migration script."
