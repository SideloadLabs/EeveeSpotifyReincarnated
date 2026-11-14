.text
.p2align 2
.globl _sap_key_mode_trampoline
_sap_key_mode_trampoline:
    // The original call site has live C++ arguments in x0-x5 and a hidden
    // return-object pointer in x8. dlsym and the selector may clobber x0-x18.
    sub sp, sp, #176
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x9, [sp, #64]
    stp x10, x11, [sp, #80]
    stp x12, x13, [sp, #96]
    stp x14, x15, [sp, #112]
    stp x16, x17, [sp, #128]
    stp x18, x30, [sp, #144]
    mrs x17, nzcv
    str x17, [sp, #168]

    movn x0, #1                    // RTLD_DEFAULT = (void *)-2
    adr x1, Lselector_name
L_dlsym_page:
    .long 0x90000010                // adrp x16; builder fills its signed page delta
L_dlsym_offset:
    add x16, x16, #0               // builder substitutes its page offset
    blr x16
    cbz x0, L_default_mode
    blr x0                         // exported C getter; no allocation or lock
    b L_mode_ready
L_default_mode:
    mov w0, #0
L_mode_ready:
    cmp w0, #1
    csel w0, w0, wzr, ls           // invalid result falls back to zero
    str w0, [sp, #160]

    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldp x8, x9, [sp, #64]
    ldp x10, x11, [sp, #80]
    ldp x12, x13, [sp, #96]
    ldp x14, x15, [sp, #112]
    ldr x17, [sp, #168]
    msr nzcv, x17
    ldp x16, x17, [sp, #128]
    ldp x18, x30, [sp, #144]
    ldr w2, [sp, #160]
    add sp, sp, #176
L_return:
    b L_return                     // builder redirects to the original blr x9

Lselector_name:
    .asciz "SAPCurrentKeyRequestMode"
