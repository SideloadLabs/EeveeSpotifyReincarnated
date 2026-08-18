#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import "Tweak.h"

#if THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

NSString *EeveeJBRootPath(NSString *path) {
#if THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

// Patches Spotify's own executable image in memory to report it was built against
// (at least) the iOS 26.0 SDK, by editing the `sdk` field of its LC_BUILD_VERSION
// load command. This mirrors exactly what Impactor's `replace_sdk_version("26.0.0")`
// does to the on-disk binary at sideload/resign time - same field, same encoding
// ((major<<16)|(minor<<8)|patch) - just applied to the loaded image at runtime
// instead of the file on disk, since a tweak dylib can't re-sign the host app.
//
// This exists because some UIKit-driven automatic behaviors (icon-button and
// control chrome adopting Liquid Glass) are gated on the linked SDK version read
// from this load command, not on the `UIDesignRequiresCompatibility` Info.plist key
// alone - flipping only the plist key (done via the NSBundle hook in
// LiquidGlass.x.swift) was enough for nav-bar-level chrome but left toggles/icon
// buttons on the legacy style. Must run before UIKit reads it, so it's called from
// this constructor rather than later Swift-side setup.
//
// This writes into the loaded __TEXT-adjacent header of Spotify's own executable,
// which is more invasive than the ObjC-level hooks elsewhere in this tweak - it's
// gated behind the same forceLiquidGlass default and gets skipped entirely if the
// load command isn't found or the page can't be made writable, so a failure here
// just leaves this specific patch inert rather than crashing.
static void patchSDKVersion(void) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!header || header->magic != MH_MAGIC_64) {
        writeDebugLog(@"[LiquidGlass] SDK patch skipped: no valid mach_header_64 for image 0");
        return;
    }

    uintptr_t cursor = (uintptr_t)header + sizeof(struct mach_header_64);
    uint32_t found = 0;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cursor;

        if (lc->cmd == LC_BUILD_VERSION) {
            struct build_version_command *bv = (struct build_version_command *)lc;

            uint32_t newSdk = (26u << 16) | (0u << 8) | 0u;
            if (bv->sdk >= newSdk) {
                writeDebugLog([NSString stringWithFormat:
                    @"[LiquidGlass] SDK patch skipped: existing sdk 0x%x already >= 26.0.0", bv->sdk]);
                return;
            }

            void *sdkFieldPage = (void *)((uintptr_t)&bv->sdk & ~(uintptr_t)(vm_page_size - 1));
            vm_size_t pageSpan = ((uintptr_t)&bv->sdk + sizeof(bv->sdk)) - (uintptr_t)sdkFieldPage;

            kern_return_t kr = vm_protect(
                mach_task_self(), (vm_address_t)sdkFieldPage, pageSpan, false,
                VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY
            );

            if (kr != KERN_SUCCESS) {
                writeDebugLog([NSString stringWithFormat:
                    @"[LiquidGlass] SDK patch skipped: vm_protect failed (%d)", kr]);
                return;
            }

            uint32_t oldSdk = bv->sdk;
            bv->sdk = newSdk;
            found = 1;

            writeDebugLog([NSString stringWithFormat:
                @"[LiquidGlass] Patched LC_BUILD_VERSION sdk 0x%x -> 0x%x", oldSdk, newSdk]);
            break;
        }

        cursor += lc->cmdsize;
    }

    if (!found) {
        writeDebugLog(@"[LiquidGlass] SDK patch skipped: no LC_BUILD_VERSION command found");
    }
}

void EeveePatchSpotifySDKVersion(void) {
    @try {
        patchSDKVersion();
    }
    @catch (NSException *exception) {
        writeDebugLog([NSString stringWithFormat:
            @"[LiquidGlass] SDK patch threw: %@, Reason: %@", exception, [exception reason]]);
    }
}

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Must happen before UIKit reads the executable's linked SDK version, so
        // this runs first, ahead of orion_init() and any Swift-side setup.
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"forceLiquidGlass"]) {
            if (@available(iOS 26.0, *)) {
                EeveePatchSpotifySDKVersion();
            }
        }

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}
