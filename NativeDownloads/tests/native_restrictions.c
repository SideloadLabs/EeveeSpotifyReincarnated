#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include "OfflineLimits.h"
void TestNativeSetter(void *, int32_t, int32_t, int32_t, int32_t, int32_t);
static int32_t result[5];
static void *manager;
void CaptureNativeSetter(void *p,int32_t duration,int32_t tracks,int32_t epDuration,int32_t episodes,int32_t abpDuration) {
    assert(p==manager);result[0]=duration;result[1]=tracks;result[2]=epDuration;result[3]=episodes;result[4]=abpDuration;
}
int main(void) {
    static const int32_t cases[][4]={{0,0,INT32_MAX,1000000},{1,4,INT32_MAX,1000000},{2592000,10000,INT32_MAX,1000000},
        {INT32_MAX,2000000,INT32_MAX,2000000},{0,2000000,INT32_MAX,2000000},{INT32_MAX,0,INT32_MAX,1000000},
        {-1,0,-1,0},{0,-1,0,-1},{INT32_MAX,INT32_MAX,INT32_MAX,INT32_MAX}};
    _Static_assert(SAPMinimumTrackLimit==1000000 && SAPMinimumMusicDurationSeconds==INT32_MAX,"tested quota constants changed");
    manager=&manager;
    for(unsigned i=0;i<sizeof(cases)/sizeof(cases[0]);i++) {
        TestNativeSetter(manager,cases[i][0],cases[i][1],777,888,999);
        assert(result[0]==cases[i][2] && result[1]==cases[i][3]);
        assert(result[2]==777 && result[3]==888 && result[4]==999);
    }
    puts("PASS: exact arm64 header trampoline runs with zero/small/higher/sentinel limits, preserves manager, other arguments and return address");
}
