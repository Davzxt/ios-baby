/* SPDX-License-Identifier: GPL-2.0-only
 * Galaxy A01 Core (MT6739) loader entry, packed as the "kernel" of an
 * Android boot image (tools/a01core-pack-boot.py). Structure follows
 * shim/herolte/xnu_boot.S.
 *
 * MediaTek LK starts a 64-bit kernel through the ATF when the boot image
 * command line carries bootopt=64S3,32N2,64N2 (the stock A01 Core kernel is
 * 32-bit: bootopt=64S3,32S1,32S1). We may arrive at EL2 or EL1 with the
 * MMU off and x0 = the FDT that LK patched (memory, reserved-memory, the
 * atag,videolfb-* framebuffer properties). At EL2 we drop to EL1 with the
 * same EL2 setup as XNU's start.s, including the GICv3 system-register
 * enable that XNU's GIC driver needs.
 */
.section .text.head, "ax"
.global _start
_start:
    b entry
    .long 0
    .quad 0x80000            /* text_offset: replaced by the packer */
    .quad 0                  /* image_size: replaced by the packer */
    .quad 0                  /* flags: replaced by the packer */
    .quad 0, 0, 0
    .byte 0x41, 0x52, 0x4d, 0x64   /* "ARMd" */
    .long 0

entry:
    msr daifset, #15
    mov x19, x0              /* FDT from LK */
    mrs x20, CurrentEL
    lsr x20, x20, #2
    and x20, x20, #3
    cmp x20, #2
    b.ne at_el1

    /* EL2 -> EL1: AArch64 EL1, no stage 2, no EL2 traps. */
    mov x1, #(1 << 31)
    msr hcr_el2, x1
    msr vttbr_el2, xzr
    mov x1, #0x33ff          /* CPTR_EL2 RES1 bits, no FP/SIMD trap */
    msr cptr_el2, x1
    msr mdcr_el2, xzr
    mov x1, #3               /* EL1 may use the physical counter/timer */
    msr cnthctl_el2, x1
    msr cntvoff_el2, xzr
    mrs x1, id_aa64pfr0_el1
    ubfx x1, x1, #24, #4     /* GIC system-register interface present? */
    cbz x1, 1f
    mrs x1, s3_4_c12_c9_5    /* ICC_SRE_EL2 */
    mov x2, #0x9             /* SRE | Enable (EL1 may use ICC_SRE_EL1); 0x9 is */
    orr x1, x1, x2           /* not encodable as a logical immediate */
    msr s3_4_c12_c9_5, x1
    isb
    msr s3_4_c12_c11_0, xzr  /* ICH_HCR_EL2: no virtual CPU interface */
1:
    ldr x1, =0x30d00800      /* SCTLR_EL1: RES1 bits, MMU/caches off */
    msr sctlr_el1, x1
    mov x1, #0x3c5           /* EL1h, all exceptions masked */
    msr spsr_el2, x1
    adr x1, at_el1
    msr elr_el2, x1
    isb
    eret

at_el1:
    /* x20 keeps the EL we were entered at. LK hands over with the MMU off;
     * make sure of it (and of the caches) before C runs. */
    mrs x21, sctlr_el1
    bic x1, x21, #1
    bic x1, x1, #4
    bic x1, x1, #0x1000
    msr sctlr_el1, x1
    isb
    adr x1, a01_stack_top
    mov sp, x1
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl a01_main
    cbz x0, halt
    mov x16, x0
    adr x1, a01_boot_args_pa
    ldr x0, [x1]
    ic iallu
    dsb sy
    isb
    br x16                   /* XNU start_first_cpu: x0 = boot_args PA */
halt:
    wfe
    b halt
    .ltorg

.section .data, "aw"
.balign 8
.global a01_boot_args_pa
a01_boot_args_pa:
    .quad 0
.balign 16
a01_stack:
    .space 16384
a01_stack_top:
