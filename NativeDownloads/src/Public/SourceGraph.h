#pragma once
#include <stdint.h>
#include <stdbool.h>

typedef struct {
    uint64_t address, imageBase, preferredAddress;
    char image[256], symbol[128];
} SAPCodeLocation;

typedef struct {
    // 0: known source resolved, 1: no active native callback,
    // 2: unknown callback layout, 3: source not yet attached, 4: unreadable state.
    uint32_t status;
    SAPCodeLocation callback;
    uint64_t owner, source, vtable;
    SAPCodeLocation methods[8];
} SAPSourceGraph;

// Manual diagnostic, called only when the user opens the PCM panel. It reads
// pointer values with mach_vm_read_overwrite and never invokes private methods.
void SAPReadSourceGraph(SAPSourceGraph *out);
