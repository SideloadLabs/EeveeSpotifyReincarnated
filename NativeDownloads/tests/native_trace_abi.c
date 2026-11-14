#include <assert.h>
#include <stdint.h>
#include <stdio.h>
typedef struct {uint64_t words[3];} Result;
extern Result TestRequestCall(uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t,uint64_t);
extern uint64_t TestSuccess(uint64_t *,const void *);
extern uint64_t TestFailure(uint64_t *,uint64_t,const void *);
unsigned helperAvailable=1;
static unsigned diagnostics,observed[3];
__attribute__((visibility("default"))) void SAPTraceNativeBoundary(unsigned kind,const uint64_t *frame) {
    if(!diagnostics)return;
    assert(kind<=2);observed[kind]++;
    if(kind==0){assert(frame[0]==11 && frame[1]==22 && frame[2]==0 && frame[3]==44 && frame[8]);}
    if(kind==1)assert(frame[1]==1); // Must never dereference the key/result pointer.
    if(kind==2)assert(frame[1]==8001 && frame[2]==2);
    __asm__ volatile(
        "mov x0,#100\n mov x1,#101\n mov x2,#102\n mov x3,#103\n mov x4,#104\n mov x5,#105\n"
        "mov x6,#106\n mov x7,#107\n mov x8,#108\n mov x9,#109\n mov x10,#110\n mov x11,#111\n"
        "mov x12,#112\n mov x13,#113\n mov x14,#114\n mov x15,#115\n mov x16,#0x10\n mov x17,#0x400000\n"
        "msr fpsr,x16\n msr fpcr,x17\n cmp x0,x1\n movi v0.16b,#0\n movi v1.16b,#0\n movi v2.16b,#0\n movi v3.16b,#0\n"
        "movi v4.16b,#0\n movi v5.16b,#0\n movi v6.16b,#0\n movi v7.16b,#0\n"
        :::"x0","x1","x2","x3","x4","x5","x6","x7","x8","x9","x10","x11","x12","x13","x14","x15","x16","x17","v0","v1","v2","v3","v4","v5","v6","v7","cc");
}
int main(int argc,char **argv) {
    unsigned patched=argc>1;
    for(unsigned enabled=0;enabled<2;enabled++){
        diagnostics=enabled;
        Result result=TestRequestCall(11,22,99,44,55,66,77,88);
        assert(result.words[0]==11&&result.words[1]==22&&result.words[2]==44);
        uint64_t context[2]={0};
        assert(TestSuccess(context,(void *)1)==0xf00d && context[0]==1);
        assert(TestFailure(context,8001,(void *)2)==0xbeef && context[0]==8001 && context[1]==2);
        assert(observed[0]==patched*enabled && observed[1]==patched*enabled && observed[2]==patched*enabled);
    }
    helperAvailable=0;
    Result result=TestRequestCall(11,22,99,44,55,66,77,88);assert(result.words[0]==11);
    uint64_t context[2]={0};assert(TestSuccess(context,(void *)1)==0xf00d);assert(TestFailure(context,8001,(void *)2)==0xbeef);
    assert(observed[0]==patched && observed[1]==patched && observed[2]==patched);
    puts("PASS native ABI: original calls/results, fixed mode 0, x0-x8/hidden result, vectors, FP/condition state; diagnostics off and missing helper preserve native flow");
}
