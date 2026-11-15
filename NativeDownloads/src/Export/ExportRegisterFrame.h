// Shared ABI for the version-2 native observation thunks. Not a key format.
#pragma once
#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t x[31];
    uint64_t original_sp;
    uint8_t q[32][16];
    uint64_t nzcv;
    uint64_t fpcr;
    uint64_t fpsr;
    uint64_t reserved;
} SAPExportRegisterFrame;

_Static_assert(offsetof(SAPExportRegisterFrame, original_sp) == 248, "native SP ABI");
_Static_assert(offsetof(SAPExportRegisterFrame, q) == 256, "native vector ABI");
_Static_assert(offsetof(SAPExportRegisterFrame, nzcv) == 768, "native flags ABI");
_Static_assert(sizeof(SAPExportRegisterFrame) == 800, "native observation frame ABI");
