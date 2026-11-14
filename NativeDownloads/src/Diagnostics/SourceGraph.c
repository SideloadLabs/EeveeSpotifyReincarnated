#include "TargetProfile.h"
#include "SourceGraph.h"
#include "AudioProbeBackend.h"
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

static bool readPointer(uint64_t address, uint64_t *value) {
    vm_size_t copied = 0;
    if (!address) return false;
    return vm_read_overwrite(mach_task_self(), address, sizeof(*value),
        (vm_address_t)value, &copied) == KERN_SUCCESS && copied == sizeof(*value);
}

static void locate(uint64_t address, SAPCodeLocation *out) {
    memset(out, 0, sizeof(*out)); out->address = address;
    Dl_info info = {0};
    if (!address || !dladdr((const void *)(uintptr_t)address, &info) || !info.dli_fbase) return;
    out->imageBase = (uintptr_t)info.dli_fbase;
    if (info.dli_fname) snprintf(out->image, sizeof(out->image), "%s", info.dli_fname);
    if (info.dli_sname) snprintf(out->symbol, sizeof(out->symbol), "%s", info.dli_sname);
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64 || header->ncmds > 1024 || header->sizeofcmds > 1048576) return;
    const char *cursor = (const char *)(header + 1), *end = cursor + header->sizeofcmds;
    for (uint32_t i = 0; i < header->ncmds && cursor + sizeof(struct load_command) <= end; ++i) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmdsize < sizeof(*command) || cursor + command->cmdsize > end) break;
        if (command->cmd == LC_SEGMENT_64 && command->cmdsize >= sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (!strncmp(segment->segname, "__TEXT", sizeof(segment->segname))) {
                out->preferredAddress = address - out->imageBase + segment->vmaddr;
                break;
            }
        }
        cursor += command->cmdsize;
    }
}

void SAPReadSourceGraph(SAPSourceGraph *out) {
    if (!out) return;
    memset(out, 0, sizeof(*out));
    uint64_t proc = 0, owner = 0;
    if (!SAPCopyActiveNativeCallback(&proc, &owner)) { out->status = 1; return; }
    locate(proc, &out->callback); out->owner = owner;
    // Verified in the supplied Spotify 9.1.92 executable: this callback loads
    // owner+0x78 and retains the native source/vtable layout.
    // Never apply this layout speculatively to a different callback/build.
    if (out->callback.preferredAddress != SAP_TARGET_RENDER_CALLBACK) { out->status = 2; return; }
    if (!readPointer(owner + 0x78, &out->source)) { out->status = 4; return; }
    if (!out->source) { out->status = 3; return; }
    if (!readPointer(out->source, &out->vtable) || !out->vtable) { out->status = 4; return; }
    for (unsigned i = 0; i < 8; ++i) {
        uint64_t method = 0;
        if (!readPointer(out->vtable + i * sizeof(method), &method)) { out->status = 4; return; }
        locate(method, &out->methods[i]);
    }
}
