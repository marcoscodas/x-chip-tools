#!/bin/bash -e

# one-shot NAND flash over FEL + gadget-eth: rewrite SPL+u-boot, boot the
# installer, then format + stream the rootfs. no serial needed.
#   ./flash-live.sh <rootfs.tar[.gz]>

HERE=$(cd "$(dirname "$0")" && pwd); cd "$HERE"

ROOTFS_TAR=${1:?usage: flash-live.sh <rootfs.tar[.gz]>}

UBOOT=${UBOOT:-../x-chip-uboot/build/u-boot/u-boot-sunxi-with-spl.bin}
INITRD=${INITRD:-build/initrd.uimage}
KEY=${KEY:-assets/installer_key}
DEV_IP=${DEV_IP:-192.168.81.1}
BOOTARGS=${BOOTARGS:-'console=ttyS0,115200'}

source "$HERE/lib-nand.sh"

resolve_kernel() {
  if [ -z "${ZIMAGE:-}" ] || [ -z "${DTB:-}" ]; then
    rm -rf build/kernel && mkdir -p build/kernel
    local z=; case "$ROOTFS_TAR" in *.gz) z=z ;; esac
    tar -C build/kernel "-x${z}f" "$ROOTFS_TAR" --wildcards \
        './boot/vmlinuz-*-chip' \
        './boot/dtbs/*/sun5i-r8-chip.dtb' \
        './usr/lib/linux-image-*/sun5i-r8-chip.dtb' 2>/dev/null || true
  fi
  ZIMAGE=${ZIMAGE:-$(ls -1 build/kernel/boot/vmlinuz-*-chip 2>/dev/null | head -1)}
  DTB=${DTB:-$(find build/kernel -name sun5i-r8-chip.dtb 2>/dev/null | head -1)}
  [ -n "$ZIMAGE" ] && [ -n "$DTB" ] || {
    echo "could not extract installer kernel+dtb from $ROOTFS_TAR; set ZIMAGE and DTB" >&2; exit 1; }
}

wait_for_device() {
  local iface=""
  echo -n ">> waiting for gadget NIC"
  for _ in $(seq 120); do
    for candidate in $(ls /sys/class/net/); do
      [ "$candidate" = "lo" ] && continue
      echo "$_IFACES_BEFORE" | grep -qx "$candidate" && continue
      iface=$candidate
      break
    done
    [ -n "$iface" ] && break
    echo -n "."; sleep 1
  done
  [ -n "$iface" ] || { echo " not found"; echo "gadget NIC never appeared" >&2; exit 1; }
  echo " $iface"
  echo -n ">> waiting for $DEV_IP"
  until ping -c1 -w1 "$DEV_IP" >/dev/null 2>&1; do echo -n "."; sleep 1; done
  echo " ok"
}

install_rootfs() {
  chmod og-rw "$KEY"
  local ssh="ssh -i $KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@$DEV_IP"

  echo ">> formatting SLC UBI volume"
  $ssh 'sh -seux' <<'REMOTE'
cat /proc/mtd
umount -l /rootfs 2>/dev/null || true
ubidetach -m 4 2>/dev/null || true
ubiformat /dev/mtd4 -y
ubiattach -m 4
ubimkvol /dev/ubi0 --name rootfs -m
mkfs.ubifs /dev/ubi0_0
mkdir -p /rootfs
mount -t ubifs /dev/ubi0_0 /rootfs
REMOTE

  $ssh "date -s @$(date +%s)" || true

  echo ">> streaming rootfs into UBIFS"
  local tarflags
  case "$ROOTFS_TAR" in
    *.gz) tarflags=xzf ;;
    *)    tarflags=xf  ;;
  esac
  dd if="$ROOTFS_TAR" bs=1M status=progress | $ssh "tar -C /rootfs -$tarflags -"

  echo ">> syncing + tearing down"
  $ssh 'sh -seux' <<'REMOTE'
sync
for _ in $(seq 60); do
  grep -q ' /rootfs ' /proc/mounts || break
  umount /rootfs || sleep 1
done
if grep -q ' /rootfs ' /proc/mounts; then
  echo "ERROR: /rootfs still mounted; refusing to detach UBI" >&2
  exit 1
fi
ubidetach -m 4
REMOTE

  echo ">> flash complete -- remove the FEL jumper and reboot into NAND"
}

resolve_kernel
build_bootloader_images build/bootloader

mk_uboot_script build/boot.scr <<EOF
echo == erasing CHIP boot region ==
nand erase 0x0 0x1000000
$(bootloader_write_cmds)
echo == booting installer ==
setenv bootargs '$BOOTARGS'
bootz 0x42000000 0x43300000 0x43000000
EOF

_IFACES_BEFORE=$(ls /sys/class/net/)

echo ">> FEL loading"
sunxi-fel -v -p uboot "$UBOOT" \
  write 0x42000000             "$ZIMAGE" \
  write 0x43000000             "$DTB" \
  write 0x43100000             build/boot.scr \
  write 0x43300000             "$INITRD" \
  write "$SPLNAND_HYNIX_ADDR"   "$SPLNAND_HYNIX" \
  write "$SPLNAND_TOSHIBA_ADDR" "$SPLNAND_TOSHIBA" \
  write "$UBOOT_ADDR"           "$UBOOTPAD"

wait_for_device
install_rootfs
