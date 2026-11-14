#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

// Observes only the verified cache-owner initialization call, not general crypto.
void SAPObserveCacheStorageKey(const uint64_t *registers, uintptr_t image);
BOOL SAPCopyCacheStorageKey(NSString *namespaceIdentifier, uint8_t output[16]);
NSDictionary *SAPCacheStorageKeyReport(void);

// 24-byte media AES key captured at the guarded setter when its verified
// caller is the 24-byte media cipher setup. Process memory only.
NSUInteger SAPMediaKey24Count(void);
BOOL SAPCopyMediaKey24(NSUInteger index, uint8_t output[24]);
NSUInteger SAPCopyRecentMediaKeys24(uint8_t *keys, uint8_t *contexts, uint8_t *contextLengths, size_t maximum);

// Context string observed immediately after the 24-byte media key setter.
// Used to derive the native IV without logging or persisting key bytes.
void SAPObserveMediaContext(const uint64_t *registers, uintptr_t image);
NSUInteger SAPCopyRecentMediaContexts(uint8_t *contexts, uint8_t *lengths, size_t maximum);

// 32-byte result of the verified native key-store derivation. The first 16
// bytes are the IV candidate; the helper never logs the bytes themselves.
__attribute__((visibility("default"))) void SAPObserveMediaOutput(uintptr_t output);
NSUInteger SAPCopyRecentMediaOutputs(uint8_t *outputs, uint8_t *lengths, size_t maximum);

// Exact 36-byte native record appended by the key setter. Its encoding is
// unproven; do not describe its first bytes as a media IV. Captured at the tail.
__attribute__((visibility("default"))) void SAPObserveMediaRecord(const uint64_t *registers, uintptr_t image);
NSUInteger SAPCopyRecentMediaRecords(uint8_t *records, size_t maximum);

// Every 16/24/32-byte key passed to the two verified native AES setters,
// with its caller. Process memory only; used by the research build.
NSUInteger SAPCopyRecentAesKeys(uint8_t *records, size_t maximum);

// CommonCrypto create calls (key, IV, mode, algorithm, options).
void SAPCaptureCCCrypto(const void *key, size_t keyLength, const void *iv, size_t ivLength,
                        uint32_t mode, uint32_t algorithm, uint32_t options);
NSUInteger SAPCopyRecentCCCryptos(uint8_t *records, size_t maximum);

// Native AES-CTR core key schedule + counter.
__attribute__((visibility("default"))) void SAPObserveAesCtr(const uint64_t *registers, uintptr_t image);
NSUInteger SAPCopyRecentAesCtrs(uint8_t *records, size_t maximum);

// Native block-AES core key schedule/object.
__attribute__((visibility("default"))) void SAPObserveAesBlock(const uint64_t *registers, uintptr_t image);
NSUInteger SAPCopyRecentAesBlocks(uint8_t *records, size_t maximum);


#ifdef SAP_TESTING
void SAPCacheStorageResetForTesting(void);
#endif
