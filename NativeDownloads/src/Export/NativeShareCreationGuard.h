#pragma once
#include <stdint.h>
#include <stddef.h>
// Offsets, guard bytes and the target UUID are generated from targets/spotify-9.1.92.json.
#include "ShareCreationLayout.h"
static inline int SAPShareCreationHasFrames(const uintptr_t *frames,size_t count,uintptr_t image) {
    int wrapper=0,constructor=0;
    if(!frames||!image)return 0;if(count>64)count=64;
    for(size_t i=0;i<count;i++){
        wrapper|=frames[i]==image+SAPShareWrapperFrameOffset;
        constructor|=frames[i]==image+SAPShareConstructorFrameOffset;
    }
    return wrapper&&constructor;
}
