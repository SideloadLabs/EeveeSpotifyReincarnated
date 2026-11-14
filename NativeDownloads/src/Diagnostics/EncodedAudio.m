#import "EncodedAudio.h"
#import "AudioProbe.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/loader.h>
#import <os/lock.h>
#include <stdatomic.h>

#ifndef SAP_PROBE_MEDIA_CACHE
#define SAP_PROBE_MEDIA_CACHE 0
#endif

static os_unfair_lock keyLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSData *, NSData *> *observedKeys;
static const uint8_t expectedUUID[] = {0xf5,0x1d,0xbd,0x93,0x3b,0x8f,0x3a,0x12,
                                       0x94,0x31,0x96,0xc6,0x06,0xe3,0xaf,0xc2};

#if SAP_PROBE_MEDIA_CACHE
static atomic_uint sampledCache;
static dispatch_queue_t probeQueue;
static NSString *hexIdentifier(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSMutableString *text = [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger i = 0; i < data.length; ++i) [text appendFormat:@"%02x", bytes[i]];
    return text;
}
static void inspectCachedAudio(NSData *fileID, NSData *key, uintptr_t image) {
    NSString *hex = hexIdentifier(fileID);
    NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Library/Application Support/PersistentCache/Storage/%@/%@.file",
                                   [hex substringToIndex:2], hex]];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *encrypted = [handle readDataOfLength:8192];
    [handle closeFile];
    NSMutableDictionary *finding = [@{@"file_id_prefix": [hex substringToIndex:8],
                                      @"cache_size": attributes[NSFileSize] ?: @0,
                                      @"observed_keys": @(SAPObservedAudioKeyCount())} mutableCopy];
    if (!encrypted.length) {
        finding[@"result"] = @"cache_unavailable";
    } else {
    typedef void *(*Initialize)(void *, int);
    typedef void (*SetKey)(void *, const void *);
    typedef void (*Transform)(void *, uint64_t, void *, const void *, size_t);
    typedef void (*Destroy)(void *);
    uint8_t context[0x330] __attribute__((aligned(16))) = {0};
    NSMutableData *plain = [NSMutableData dataWithLength:encrypted.length];
    ((Initialize)(image + 0x49080a8))(context, 1);
    ((SetKey)(image + 0x5bfed98))(context, key.bytes);
    int status = 0;
    memcpy(&status, context + 4, sizeof(status));
    if (!status) ((Transform)(image + 0x7f271a4))(context, 0, plain.mutableBytes, encrypted.bytes, encrypted.length);
    ((Destroy)(image + 0x6b9aefc))(context);
    const uint8_t *bytes = plain.bytes;
    NSUInteger ogg = NSNotFound;
    for (NSUInteger i = 0; i + 4 <= plain.length; ++i) {
        if (!memcmp(bytes + i, "OggS", 4)) { ogg = i; break; }
    }
    NSUInteger id3 = NSNotFound;
    for (NSUInteger i = 0; i + 3 <= plain.length; ++i) {
        if (!memcmp(bytes + i, "ID3", 3)) { id3 = i; break; }
    }
    finding[@"result"] = status ? @"native_key_rejected" : @"decrypted";
    finding[@"native_key_status"] = @(status);
    finding[@"ogg_offset"] = ogg == NSNotFound ? [NSNull null] : @(ogg);
    finding[@"id3_offset"] = id3 == NSNotFound ? [NSNull null] : @(id3);
    NSMutableString *head = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(16, plain.length); ++i) [head appendFormat:@"%02x", bytes[i]];
    finding[@"first_16_decrypted_bytes"] = head;
    }
    NSString *reportPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/SpotifyAudioProbeCache.json"];
    NSData *oldReport = [NSData dataWithContentsOfFile:reportPath];
    NSArray *previous = oldReport ? [NSJSONSerialization JSONObjectWithData:oldReport options:0 error:nil] : nil;
    NSMutableArray *events = [previous isKindOfClass:NSArray.class] ? [previous mutableCopy] : [NSMutableArray array];
    [events addObject:finding];
    NSData *report = [NSJSONSerialization dataWithJSONObject:events options:NSJSONWritingPrettyPrinted error:nil];
    [report writeToFile:reportPath atomically:YES];
    NSLog(@"[SAPExportProbe] %@", finding);
}
#endif

static BOOL readBytes(uintptr_t source, void *destination, size_t count) {
    vm_size_t copied = 0;
    return source && vm_read_overwrite(mach_task_self(), source, count,
                                       (vm_address_t)destination, &copied) == KERN_SUCCESS && copied == count;
}

static BOOL supportedSpotifyImage(uintptr_t image) {
    struct mach_header_64 header;
    if (!readBytes(image, &header, sizeof(header)) || header.magic != MH_MAGIC_64 ||
        header.ncmds > 1024 || header.sizeofcmds > 1048576) return NO;
    uintptr_t cursor = image + sizeof(header), end = cursor + header.sizeofcmds;
    for (unsigned i = 0; i < header.ncmds; ++i) {
        struct load_command command;
        if (cursor > end || end - cursor < sizeof(command) ||
            !readBytes(cursor, &command, sizeof(command)) ||
            command.cmdsize < sizeof(command) || command.cmdsize > end - cursor) return NO;
        if (command.cmd == LC_UUID) {
            struct uuid_command uuid;
            return command.cmdsize >= sizeof(uuid) && readBytes(cursor, &uuid, sizeof(uuid)) &&
                   memcmp(uuid.uuid, expectedUUID, sizeof(expectedUUID)) == 0;
        }
        cursor += command.cmdsize;
    }
    return NO;
}

SAP_EXPORT void SpotifyAudioProbeObserveOfflineKey(const void *functionStorage, const void *result) {
    // Invoked once by the guarded native completion trampoline before Spotify's
    // original instructions. Never modifies the request or native result.
    Dl_info imageInfo = {0};
    if (!dladdr(__builtin_return_address(0), &imageInfo) ||
        !supportedSpotifyImage((uintptr_t)imageInfo.dli_fbase)) return;
    uintptr_t functor = 0, wrapper = 0, owner = 0, descriptor = 0;
    uint8_t fileID[20], key[16];
    if (!readBytes((uintptr_t)functionStorage, &functor, sizeof(functor)) ||
        !readBytes(functor, &wrapper, sizeof(wrapper)) ||
        !readBytes(wrapper + 8, &owner, sizeof(owner)) ||
        !readBytes(owner + 0xc8, &descriptor, sizeof(descriptor)) ||
        !readBytes(descriptor + 4, fileID, sizeof(fileID)) ||
        !readBytes((uintptr_t)result, key, sizeof(key))) return;
    NSData *identifier = [NSData dataWithBytes:fileID length:sizeof(fileID)];
    NSData *secret = [NSData dataWithBytes:key length:sizeof(key)];
    memset(key, 0, sizeof(key));
    os_unfair_lock_lock(&keyLock);
    if (!observedKeys) observedKeys = [NSMutableDictionary dictionary];
    observedKeys[identifier] = secret;
    os_unfair_lock_unlock(&keyLock);
#if SAP_PROBE_MEDIA_CACHE
    unsigned sample = atomic_fetch_add(&sampledCache, 1);
    if (sample < 3) {
        static dispatch_once_t probeOnce;
        dispatch_once(&probeOnce, ^{ probeQueue = dispatch_queue_create("com.spotify.probe.cache", DISPATCH_QUEUE_SERIAL); });
        uintptr_t image = (uintptr_t)imageInfo.dli_fbase;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (sample ? 25 : 10) * NSEC_PER_SEC), probeQueue, ^{
            inspectCachedAudio(identifier, secret, image);
        });
    }
#endif
}

void SAPWithObservedAudioKey(NSData *fileID, void (^block)(NSData *key)) {
    if (!block || fileID.length != 20) return;
    os_unfair_lock_lock(&keyLock);
    NSData *key = observedKeys[fileID];
    os_unfair_lock_unlock(&keyLock);
    block(key);
}

NSUInteger SAPObservedAudioKeyCount(void) {
    os_unfair_lock_lock(&keyLock);
    NSUInteger count = observedKeys.count;
    os_unfair_lock_unlock(&keyLock);
    return count;
}
