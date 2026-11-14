// Offsets derived from the verified Spotify 9.2.0 export windows.
#pragma once
#include <stdint.h>
static const uintptr_t SAPExportOwnerDescriptorOffset=0x120;
static const uintptr_t SAPExportCacheNamespaceOffset=0x2b8;
static const uintptr_t SAPExportUnsealCallerReturnOffset=0x7741414;
static const uintptr_t SAPExportCacheKeyBodyOffset=0x559a714;
static const uint8_t SAPExportCacheKeyBody[]={0x08,0xc8,0x42,0xb9,0xe8,0x13,0x00,0xb9,0x08,0xe0,0x0a,0x91,0x00,0x01,0xc0,0x3d,0xe0,0x03,0x80,0x3d,0x20,0x00,0xc0,0x3d,0xe0,0x43,0x81,0x3c};
static const uintptr_t SAPCacheStorageOwnerReturnA=0xa5c82ac;
static const uintptr_t SAPCacheStorageOwnerReturnB=0xa5c82b8;
static const uintptr_t SAPExportMediaContextOffset=0x503253c;
