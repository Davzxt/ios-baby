#!/usr/bin/env python3
"""Build the Galaxy A01 Core (SM-A013F/G/M, MediaTek MT6739) ADT for the
A01CORE XNU config.

Derived from mkadt_herolte.py. Hardware addresses come from the A01 Core
boot DTB and dtbo (firmware M013FDDU4AUG1, see docs/A01CORE_HARDWARE.md);
none is verified under XNU on the phone yet. The values that LK chooses at
run time (framebuffer address and pitch, free RAM) must come from the
shim/a01core probe screen and be passed here AND to the kernel build
(xnu workflow inputs a01core_fb_pa / a01core_fb_stride).

Example (defaults shown):
  python3 tools/mkadt_a01core.py a01core.adt --ram-base 0x80000000 --ram-mb 511 \\
      --fb-pa 0x76740000 --fb-stride 2944
"""
import argparse
import os
from pathlib import Path

import adt
import mkadt

RAM_BASE = 0x80000000        # free 511 MiB window on the 2 GB A01 Core (probe 2026-11-01)
RAM_MB = 511
SOC_BASE = 0x0c000000        # arm-io ranges base (GIC); child regs are relative
SOC_SIZE = 0x34000000        # up to the DRAM at 0x40000000
GICD, GICD_SIZE = 0x0c000000, 0x40000
GICR, GICR_SIZE = 0x0c080000, 0x80000   # 4 redistributors x 0x20000
TIMEBASE = 13000000          # DTB timer clock-frequency = 0xc65d40
CPU_HZ = 1500000000
NCPUS = 4                    # MPIDR Aff0 0..3, PSCI 0.2 via smc
MSDC0 = (0x11230000, 0x10000)
FB_W, FB_H = 720, 1480


def set_prop(node, name, value):
    for i, (key, flags, _) in enumerate(node.props):
        if key == name:
            node.props[i] = (key, flags, value)
            return
    node.props.append((name, 0, value))


def child(node, name):
    for candidate in node.children:
        if candidate.prop('name') == mkadt.cstr(name):
            return candidate
    raise ValueError(f'missing donor ADT node {name}')


def build(ram, fb_pa, fb_stride, canvas_mode):
    root = mkadt.build(seed=os.urandom(64), qemu=True)
    try:
        product = child(root, 'product')
    except ValueError:
        # No research/ipsw-x/d22ap.adt: fine for a kernel-only test boot,
        # but MobileGestalt needs the real /product for the iOS GUI.
        product = mkadt.node('product', [])
        root.children.append(product)
    if canvas_mode == 'xr':
        # iPhone XR screen, 414x896 points @2x = 828x1792: close to the
        # panel's aspect (720x1520) and 2.5x fewer pixels than an iPhone X
        # canvas for the CPU renderer. See mkadt_herolte.py --scale2.
        set_prop(child(root, 'chosen'), 'display-scale', mkadt.u32(2))
        set_prop(product, 'artwork-device-subtype', mkadt.u32(1792))
        set_prop(product, 'artwork-scale-factor', mkadt.u32(2))
        canvas = (828, 1792)
    elif canvas_mode == 'iphone8':
        # iPhone 8 screen with a Home button (map it with a01keys_home=1).
        # It is 16:9, so the kernel stretches it 19 % vertically.
        set_prop(child(root, 'chosen'), 'display-scale', mkadt.u32(2))
        set_prop(product, 'artwork-device-subtype', mkadt.u32(1334))
        set_prop(product, 'artwork-scale-factor', mkadt.u32(2))
        set_prop(child(root, 'buttons'), 'home-button-type', mkadt.u32(1))
        canvas = (750, 1334)
    else:
        canvas = (1125, 2436)   # iPhone X native canvas, slowest
    # Userland: the iPhone X IPSW (iPhone10,3 / D22AP), like the donors.
    # 'samsung,a5xelte' keeps the shared SweetPlatformExpert IONameMatch.
    set_prop(root, 'compatible', mkadt.cstr('D22AP') + mkadt.cstr('iPhone10,3') +
             mkadt.cstr('samsung,a5xelte') + mkadt.cstr('samsung,a01core') +
             mkadt.cstr('mediatek,mt6739') + mkadt.cstr('AppleARM'))
    chosen = child(root, 'chosen')
    set_prop(chosen, 'dram-base', mkadt.u64(ram[0]))
    set_prop(chosen, 'dram-size', mkadt.u64(ram[1]))
    set_prop(chosen, 'firmware-version', mkadt.cstr('a01core-entry'))
    set_prop(chosen, 'system-firmware-version', mkadt.cstr('a01core-entry'))
    # Synthetic, locally administered addresses (see mkadt_herolte.py: without
    # them MobileGestalt waits for a Wi-Fi/Bluetooth driver forever).
    for name, last in (('wifi0', 1), ('bluetooth0', 2), ('ethernet0', 3)):
        set_prop(chosen, f'mac-address-{name}', bytes((0x02, 0x41, 0x30, 0x31, 0x43, last)))
    cpus = child(root, 'cpus')
    cpu0 = child(cpus, 'cpu0')
    set_prop(cpu0, 'compatible', mkadt.cstr('arm,cortex-a53') + mkadt.cstr('ARM,v8'))
    set_prop(cpu0, 'reg', mkadt.u32(0))
    for key in ('timebase-frequency', 'peripheral-frequency', 'fixed-frequency'):
        set_prop(cpu0, key, mkadt.u32(TIMEBASE))
    set_prop(cpu0, 'clock-frequency', mkadt.u32(CPU_HZ))
    for logical in range(1, NCPUS):
        cpus.children.append(mkadt.node(f'cpu{logical}', [
            ('device_type', mkadt.cstr('cpu')),
            ('compatible', mkadt.cstr('arm,cortex-a53') + mkadt.cstr('ARM,v8')),
            ('reg', mkadt.u32(logical)),
            ('cpu-id', mkadt.u32(logical)),
            ('cluster-id', mkadt.u32(0)),
            ('cluster-type', mkadt.u32(0)),
            ('die-cluster-id', mkadt.u32(0)),
            ('cluster-core-id', mkadt.u32(logical)),
            ('l2-cache-id', mkadt.u32(0)),
            ('l3-cache-id', mkadt.u32(0)),
            ('state', mkadt.cstr('stopped')),
            ('timebase-frequency', mkadt.u32(TIMEBASE)),
            ('clock-frequency', mkadt.u32(CPU_HZ)),
            ('bus-frequency', mkadt.u32(100000000)),
            ('memory-frequency', mkadt.u32(1600000000)),
            ('peripheral-frequency', mkadt.u32(TIMEBASE)),
            ('fixed-frequency', mkadt.u32(TIMEBASE)),
        ]))
    arm_io = child(root, 'arm-io')
    set_prop(arm_io, 'device_type', mkadt.cstr('a01core-io'))
    set_prop(arm_io, 'compatible', mkadt.cstr('mediatek,mt6739-io') + mkadt.cstr('arm-io'))
    set_prop(arm_io, 'ranges', mkadt.u64(0, SOC_BASE, SOC_SIZE))
    arm_io.children = [n for n in arm_io.children if n.prop('name') == mkadt.cstr('wdt')]
    # GIC-500 (GICv3): pexpert/arm/pe_fiq.c reads <GICD, size, GICR, size>.
    arm_io.children.append(mkadt.node('gic', [
        ('compatible', mkadt.cstr('arm,gic-v3')),
        ('interrupt-controller', mkadt.cstr('master')),
        ('virtual-timer-intid', mkadt.u32(27)),
        ('reg', mkadt.u64(GICD - SOC_BASE, GICD_SIZE, GICR - SOC_BASE, GICR_SIZE)),
    ]))
    arm_io.children.append(mkadt.node('disp0', [
        ('device_type', mkadt.cstr('display-subsystem')),
        # AppleCLCD matches 'samsung,a5xelte-display' (KernelConfigTables.cpp).
        ('compatible', mkadt.cstr('samsung,a5xelte-display') +
         mkadt.cstr('samsung,a01core-display')),
        ('canvas-width', mkadt.u32(canvas[0])),
        ('canvas-height', mkadt.u32(canvas[1])),
    ]))
    root.children = [n for n in root.children if n.prop('name') not in
                     (mkadt.cstr('sweet-fbcon'), mkadt.cstr('sweet-ufs'))]
    # MSDC0, absolute address (bsd/dev/a01core_msdc.h; rd=emmcroot0).
    root.children.append(mkadt.node('a01core-emmc', [('reg', mkadt.u64(*MSDC0))]))
    # pe_serial.c looks this node up by name for the kprintf console.
    root.children.append(mkadt.node('a5xelte-fbcon', [
        ('reg', mkadt.u64(fb_pa, fb_stride * FB_H)),
        ('width', mkadt.u32(FB_W)),
        ('height', mkadt.u32(FB_H)),
        ('stride', mkadt.u32(fb_stride)),
    ]))
    return root, canvas


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('output', type=Path)
    parser.add_argument('--ram-base', type=lambda v: int(v, 0), default=RAM_BASE)
    parser.add_argument('--ram-mb', type=int, default=RAM_MB)
    parser.add_argument('--fb-pa', type=lambda v: int(v, 0), default=0x76740000,
                        help='framebuffer address from the probe screen')
    parser.add_argument('--fb-stride', type=int, default=2944,
                        help='framebuffer row bytes from the probe screen')
    parser.add_argument('--canvas', choices=('xr', 'iphone8', 'x'), default='xr',
                        help='iOS screen: xr 828x1792 (default), iphone8 750x1334 with Home, x 1125x2436')
    args = parser.parse_args()
    ram = (args.ram_base, args.ram_mb << 20)
    if ram[0] < 0x40000000 or ram[0] + ram[1] > 0xc0000000 or ram[0] & 0x1fffff:
        raise SystemExit('RAM window must be 2 MiB aligned inside 0x40000000..0xc0000000')
    root, canvas = build(ram, args.fb_pa, args.fb_stride, args.canvas)
    blob = adt.serialize(root)
    args.output.write_bytes(blob)
    print(f'{args.output}: {len(blob)} bytes, RAM {ram[0]:#x}+{ram[1] >> 20} MiB, '
          f'canvas {canvas[0]}x{canvas[1]} (boot-args sweetfb_lw={canvas[0]} sweetfb_lh={canvas[1]}), '
          f'fb {args.fb_pa:#x} stride {args.fb_stride}')


if __name__ == '__main__':
    main()
