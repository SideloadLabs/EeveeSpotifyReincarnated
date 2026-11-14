#pragma once
#include <stdbool.h>
#include <stdint.h>

// A saved preference alone is never evidence of an executing mode-1 selector.
// kind 1 is a verified direct instruction; kind 2 is the verified trampoline.
static inline bool SAPModeOneConfirmed(int kind,bool symbolMatches,int configured,int lastReturned,uint64_t readsOne) {
    return kind==1 || (kind==2 && symbolMatches && configured==1 && lastReturned==1 && readsOne>0);
}
static inline bool SAPCanRestoreZero(int kind,bool symbolMatches,int configured,int lastReturned,uint64_t readsOne) {
    return kind==2 && SAPModeOneConfirmed(kind,symbolMatches,configured,lastReturned,readsOne);
}
