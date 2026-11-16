#import <dlfcn.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <stdatomic.h>
#import <string.h>
#import "Rebind.h"
#import "SpeedPitchPrivate.h"

// the slide from the image's own __TEXT, so it can't come from a different dyld index than the header.
static BOOL imageSlide(const struct mach_header_64 *header, intptr_t *slide) {
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64 || strcmp(((const struct segment_command_64 *)command)->segname, SEG_TEXT) != 0) continue;
        *slide = (intptr_t)header - (intptr_t)((const struct segment_command_64 *)command)->vmaddr;
        return YES;
    }
    return NO;
}

// Spotify's binary: the image named Spotify (a dylib under LiveContainer), else the one named as the
// bundle's executable (an install whose executable was renamed). the first lookup is logged, so a missing
// image isn't mistaken for a missing import.
static const struct mach_header_64 *spotifyImage(intptr_t *slide) {
    static BOOL logged;
    NSString *executable = NSBundle.mainBundle.infoDictionary[@"CFBundleExecutable"];
    const char *names[] = {"Spotify", executable.UTF8String};
    for (int n = 0; n < 2; n++) {
        if (!names[n]) continue;
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const struct mach_header *header = _dyld_get_image_header(i);
            const char *name = _dyld_get_image_name(i);
            const char *slash = name ? strrchr(name, '/') : NULL;
            if (!header || header->magic != MH_MAGIC_64 || !slash || strcmp(slash + 1, names[n]) != 0) continue;
            if (!imageSlide((const struct mach_header_64 *)header, slide)) continue;
            if (!logged) SPLog(@"rebind: Spotify's binary is %s", name);
            logged = YES;
            return (const struct mach_header_64 *)header;
        }
    }
    if (!logged) SPLog(@"rebind: no image named Spotify or %@ is loaded, nothing is rebound", executable);
    logged = YES;
    return NULL;
}

// the page's current and maximum protection, for the log when a write is refused.
static NSString *protectionOf(vm_address_t address) {
    vm_address_t region = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &region, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS) return @"unknown";
    // vm_region_64 moves on to the next mapping when there is none at `address`.
    if (region > address) return @"unmapped";
    return [NSString stringWithFormat:@"now %d, at most %d, shared %d", info.protection, info.max_protection, info.shared];
}

// writes one pointer, making its page writable first. a page dyld made read only after binding (__DATA_CONST,
// __AUTH_CONST) is copied, then made read only again; if the copy is refused it is made writable without one,
// and failing that the slot is left alone. don't map a copy of the page over it with vm_remap instead: on a
// jailbroken iPhone 11 (iOS 17.5.1), where both were refused, that left the range unmapped and Spotify died
// of SIGBUS at launch.
static BOOL writeSlot(void **slot, void *value, BOOL readOnly) {
    vm_size_t page = vm_page_size;
    vm_address_t start = (vm_address_t)slot & ~(page - 1);
    kern_return_t result = vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    // a page an earlier slot already copied refuses a second copy; it only needs to be writable again.
    if (result == KERN_PROTECTION_FAILURE) {
        kern_return_t retry = vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ | VM_PROT_WRITE);
        if (retry == KERN_SUCCESS) result = KERN_SUCCESS;
    }
    if (result != KERN_SUCCESS) {
        static atomic_int logged;
        if (atomic_fetch_add(&logged, 1) < 3) SPLog(@"rebind: vm_protect failed (%d), the page %@", result, protectionOf(start));
        return NO;
    }
    *slot = value;
    if (readOnly) vm_protect(mach_task_self(), start, page, FALSE, VM_PROT_READ);
    return YES;
}

BOOL EeveeRebindImport(const char *symbol, void *replacement, void **original) {
    intptr_t slide = 0;
    const struct mach_header_64 *header = spotifyImage(&slide);
    if (!header) return NO;

    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0) {
            linkedit = (const struct segment_command_64 *)command;
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_DYSYMTAB) {
            dysymtab = (const struct dysymtab_command *)command;
        }
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return NO;

    uintptr_t base = (uintptr_t)slide + (uintptr_t)(linkedit->vmaddr - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab->indirectsymoff);

    // the symbol's index among the undefined ones, found once instead of comparing names per slot.
    uint32_t wanted = UINT32_MAX;
    for (uint32_t i = dysymtab->iundefsym; i < dysymtab->iundefsym + dysymtab->nundefsym && i < symtab->nsyms; i++) {
        uint32_t offset = symbols[i].n_un.n_strx;
        if (offset >= symtab->strsize) continue;
        const char *name = strings + offset;
        if (name[0] == '_' && strcmp(name + 1, symbol) == 0) {
            wanted = i;
            break;
        }
    }
    if (wanted == UINT32_MAX) return NO;

    BOOL rebound = NO, unbound = NO;
    command = (const struct load_command *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const struct load_command *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
        BOOL readOnly = strcmp(segment->segname, "__DATA_CONST") == 0 || strcmp(segment->segname, "__AUTH_CONST") == 0;
        const struct section_64 *section = (const struct section_64 *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **slots = (void **)((uintptr_t)slide + section->addr);
            uint64_t count = section->size / sizeof(void *);
            for (uint64_t k = 0; k < count; k++) {
                uint64_t entry = (uint64_t)section->reserved1 + k;
                if (entry >= dysymtab->nindirectsyms || indirect[entry] != wanted) continue;
                if (slots[k] == replacement) continue;
                void *held = slots[k];
                // bit 63 marks a chained-fixup bind dyld hasn't applied yet; it would overwrite the slot later.
                if ((uintptr_t)held >> 63) {
                    unbound = YES;
                    continue;
                }
                if (!writeSlot(&slots[k], replacement, readOnly)) continue;
                if (original && !*original) *original = held;
                rebound = YES;
            }
        }
    }
    if (unbound) SPLog(@"rebind: %s is not bound yet, left as it is", symbol);
    return rebound;
}

#pragma mark - the jailbreak's hooker

typedef void (*MSHookFunctionPointer)(void *symbol, void *replace, void **result);

// MSHookFunction from ElleKit's or Substrate's library where a rootless or rootful jailbreak keeps it, else
// as the process already has it.
static MSHookFunctionPointer hooker(void) {
    static MSHookFunctionPointer found;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // the jailbreak's paths first: an IPA can bundle its own substrate, which is in the process on any phone.
        const char *paths[] = {"/var/jb/usr/lib/libellekit.dylib", "/var/jb/usr/lib/libsubstrate.dylib",
                               "/usr/lib/libellekit.dylib", "/usr/lib/libsubstrate.dylib"};
        for (size_t i = 0; !found && i < sizeof paths / sizeof *paths; i++) {
            void *handle = dlopen(paths[i], RTLD_NOW);
            if (handle) found = (MSHookFunctionPointer)dlsym(handle, "MSHookFunction");
        }
        if (!found) found = (MSHookFunctionPointer)dlsym(RTLD_DEFAULT, "MSHookFunction");
        SPLog(@"rebind: MSHookFunction %@", found ? @"is there" : @"is not there");
    });
    return found;
}

// a hooker bundled inside the IPA is no jailbreak: only one loaded from outside the app's bundle counts.
BOOL EeveeJailbroken(void) {
    static BOOL jailbroken;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        MSHookFunctionPointer hook = hooker();
        Dl_info info;
        if (!hook || !dladdr((const void *)hook, &info) || !info.dli_fname) return;
        NSString *image = [NSString stringWithUTF8String:info.dli_fname];
        // the app's bundle, or its folder under LiveContainer (/var/mobile/Containers/...). not every
        // /var/containers path: roothide keeps the jailbreak's files in /var/containers/Bundle/Application/.jbroot-*.
        NSString *bundle = NSBundle.mainBundle.bundlePath;
        jailbroken = !(bundle.length && [image hasPrefix:bundle]) && ![image containsString:@"/mobile/Containers/"];
        SPLog(@"rebind: MSHookFunction comes from %@, %@", image, jailbroken ? @"the jailbreak's" : @"the app's own: no jailbreak");
    });
    return jailbroken;
}

BOOL EeveeHookFunctionInline(void *function, void *replacement, void **original) {
    if (!EeveeJailbroken()) return NO;
    // finds Spotify's code now rather than on the first hooked call, which can come on an audio thread.
    EeveeCalledFromSpotify(NULL);
    hooker()(function, replacement, original);
    return *original != NULL;
}

BOOL EeveeCalledFromSpotify(void *returnAddress) {
    static uintptr_t start, end;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        intptr_t slide = 0;
        const struct mach_header_64 *header = spotifyImage(&slide);
        if (!header) return;
        unsigned long size = 0;
        start = (uintptr_t)getsegmentdata(header, SEG_TEXT, &size);
        end = start + size;
    });
    // on arm64e a return address carries a pointer authentication code in its top bits.
#if __has_feature(ptrauth_calls)
    returnAddress = ptrauth_strip(returnAddress, ptrauth_key_return_address);
#endif
    uintptr_t address = (uintptr_t)returnAddress;
    return address >= start && address < end;
}
