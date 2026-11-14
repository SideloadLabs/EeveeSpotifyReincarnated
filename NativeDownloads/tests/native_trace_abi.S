.text
.p2align 2
.globl _TestRequestCall
_TestRequestCall:
 stp x29,x30,[sp,#-16]!
 mov x29,sp
 adrp x9,_TestRequestTarget@PAGE
 add x9,x9,_TestRequestTarget@PAGEOFF
 mov x10,#0x1234
 fmov d0,x10
 msr fpcr,xzr
 msr fpsr,xzr
 cmp x0,x0
.globl _TestRequestSite
_TestRequestSite:
 mov w2,#0
 blr x9
 ldp x29,x30,[sp],#16
 ret
_TestRequestTarget:
 mrs x10,nzcv
 mov x11,#0x60000000
 cmp x10,x11
 b.ne Lfail
 fmov x10,d0
 mov x11,#0x1234
 cmp x10,x11
 b.ne Lfail
 mrs x10,fpcr
 cbnz x10,Lfail
 mrs x10,fpsr
 cbnz x10,Lfail
 cbnz x2,Lfail
 cmp x4,#55
 b.ne Lfail
 cmp x5,#66
 b.ne Lfail
 cmp x6,#77
 b.ne Lfail
 cmp x7,#88
 b.ne Lfail
 stp x0,x1,[x8]
 str x3,[x8,#16]
 ret

.globl _TestSuccess
_TestSuccess:
 sub sp,sp,#0x50
 stp x20,x19,[sp,#0x30]
 stp x29,x30,[sp,#0x40]
 add x29,sp,#0x40
 str x1,[x0]
 mov x0,#0xf00d
 ldp x29,x30,[sp,#0x40]
 ldp x20,x19,[sp,#0x30]
 add sp,sp,#0x50
 ret
.globl _TestFailure
_TestFailure:
 sub sp,sp,#0x50
 stp x20,x19,[sp,#0x30]
 stp x29,x30,[sp,#0x40]
 add x29,sp,#0x40
 stp x1,x2,[x0]
 mov x0,#0xbeef
 ldp x29,x30,[sp,#0x40]
 ldp x20,x19,[sp,#0x30]
 add sp,sp,#0x50
 ret
.globl _TestDlsym
_TestDlsym:
 adrp x8,_helperAvailable@PAGE
 ldr w8,[x8,_helperAvailable@PAGEOFF]
 cbz w8,Lmissing
 adrp x0,_SAPTraceNativeBoundary@PAGE
 add x0,x0,_SAPTraceNativeBoundary@PAGEOFF
 ret
Lmissing:
 mov x0,#0
 ret
Lfail:
 brk #0x777
