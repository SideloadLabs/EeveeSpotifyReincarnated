#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

// Called only by the UUID-verified native trampoline at 0x101daf0d0.
// registers[0] is the storage owner; registers[1] is its file descriptor.
void SAPNativeCacheObserve(const uint64_t *registers,uintptr_t imageBase);
NSArray<NSDictionary *> *SAPNativeCacheCandidates(NSData *fileID);
NSDictionary *SAPNativeCacheMapReport(void);

#ifdef SAP_TESTING
void SAPNativeCacheMapResetForTesting(void);
#endif
