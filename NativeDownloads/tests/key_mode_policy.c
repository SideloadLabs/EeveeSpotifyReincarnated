#include "KeyModePolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(!SAPCanRestoreZero(0,true,0,1,100));
    assert(SAPModeOneConfirmed(1,false,1,-1,0));
    assert(!SAPCanRestoreZero(1,true,1,1,1)); // Fixed executable has no runtime setter.
    assert(!SAPCanRestoreZero(-1,true,1,1,1));
    assert(!SAPCanRestoreZero(2,false,1,1,1));
    assert(!SAPCanRestoreZero(2,true,1,-1,0)); // Merely saved 1.
    assert(!SAPCanRestoreZero(2,true,0,1,1)); // Stale observation after restoring 0.
    assert(!SAPCanRestoreZero(2,true,1,0,1));
    assert(SAPCanRestoreZero(2,true,1,1,1));
    puts("PASS: only a verified mode-1 selector observed returning 1 can offer restoration to 0; saved, stale, fixed and unknown states cannot");
}
