#!/bin/bash
# write-boot-cmd.sh
# Writes the patched U-Boot script source to /root/boot.cmd.
# Does NOT compile or touch /boot/boot.scr - that's a separate step.

set -e

OUT="/root/boot.cmd"

cat > "$OUT" << 'BOOTCMD_EOF'
# flash-kernel: bootscr.chip
# CHIP NAND boot script (flash-kernel template; see /etc/flash-kernel/db).
# console=tty0 (composite/framebuffer)
# audit=0: disable kernel audit subsystem printk spam from PAM/login/sudo
#
# PATCHED: root now on USB (UUID 11a25e21-3cfc-49e2-b461-779f61fcafb8, ext4).
# Kernel/dtb/initrd still load from NAND UBI as before. Dropped ubi.mtd=4
# since root no longer needs UBI. Added initrd load + updated bootz call
# since original script booted with no initrd at all (bootz had "-" for
# the ramdisk arg) -- USB storage support is module-based, not built into
# vmlinuz, so it needs the initramfs stage to come up.
setenv bootargs 'console=tty0 console=ttyS0,115200 audit=0 root=UUID=11a25e21-3cfc-49e2-b461-779f61fcafb8 rootfstype=ext4 rw rootwait'

# --- Composite TV standard (NTSC vs PAL) ------------------------------------
setenv video-mode 'sunxi:640x480-24@60,monitor=composite-ntsc,overscan_x=40,overscan_y=20'
#setenv video-mode 'sunxi:720x576-24@50,monitor=composite-pal,overscan_x=40,overscan_y=20'

ubifsload 0x42000000 /boot/vmlinuz-6.12.94+deb13-chip
ubifsload 0x43000000 /boot/dtbs/6.12.94+deb13-chip/sun5i-r8-chip.dtb

# --- DIP device-tree overlay auto-select (project memory: dt-overlays-dip) ---
setenv dipdir /lib/firmware/nextthingco/chip/early
if test -z "${dipovl}" && w1 read 0 0 0 0x80 0x45000000; then
    if itest.l *0x45000000 == 0x50494843; then    # 'CHIP' magic (little-endian)
        echo "DIP id header (magic/ver/VID@5/PID@9):"
        md.b 0x45000000 0x10
        if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x01; then setenv dipovl ${dipdir}/x-chip-pocketchip.dtbo; fi
        if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x02; then setenv dipovl ${dipdir}/x-chip-dip-vga.dtbo;    fi
        if itest.b *0x45000009 == 0x00 && itest.b *0x4500000a == 0x03; then setenv dipovl ${dipdir}/x-chip-dip-hdmi.dtbo;   fi
        if test -n "${dipovl}"; then echo "DIP: selected ${dipovl}"; else echo "DIP: no overlay for this PID"; fi
    else
        echo "DIP: no CHIP header (no/foreign DIP)"
    fi
fi
if test -n "${dipovl}"; then
    echo "DIP: applying overlay ${dipovl}"
    fdt addr 0x43000000
    fdt resize 0x4000
    if ubifsload 0x44000000 ${dipovl} && fdt apply 0x44000000; then
        echo "DIP: overlay applied"
    else
        echo "DIP: overlay failed; booting base dtb"
        ubifsload 0x43000000 /boot/dtbs/6.12.94+deb13-chip/sun5i-r8-chip.dtb
    fi
fi

ubifsload 0x43100000 /boot/initrd.img-6.12.94+deb13-chip
setenv initrd_size ${filesize}

bootz 0x42000000 0x43100000:${initrd_size} 0x43000000
BOOTCMD_EOF

echo "Wrote $OUT"
wc -l "$OUT"
echo ""
echo "Now diff against the current live boot.scr:"
diff <(strings /boot/boot.scr) "$OUT" || true