// lifts Spotify's core mixer limit with the speed, so the core keeps up above 1.2x.
//
// the list player's mixer hands audio out through a token bucket: 10 s of frames up front, refilled at
// sample rate x 1.2 / 1000 frames per ms (52 at 44.1 kHz). at 1.5x the engine drains it in about 30 s, then
// the core runs at 1.2x and the sound pauses to catch up. the bucket reads time through Spotify's import of
// std::chrono::steady_clock::now() (a pointer the core copies when it starts), so that import is rebound
// and the bucket's two reads get a clock that runs max(1, speed) times as fast. every other caller gets the
// real time. see README.md, "Spotify's mixer limit".
#import <dlfcn.h>
#import <stdatomic.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif
#import "Rebind.h"
#import "SpeedPitchPrivate.h"

static const char *kSteadyNow = "_ZNSt3__16chrono12steady_clock3nowEv";

// a time_point in nanoseconds, returned in x0.
typedef int64_t (*SteadyNow)(void);
static SteadyNow sg_realNow;

// the bucket's timeline: `warpedBase` at `base`, running `rate` times as fast since. a seqlock, written on
// the main thread only.
static atomic_uint sg_seq;
static _Atomic int64_t sg_base, sg_warpedBase;
static _Atomic float sg_rate = 1;
static atomic_bool sg_bucketSeen;

static int64_t warped(int64_t now) {
    for (;;) {
        unsigned seq = atomic_load_explicit(&sg_seq, memory_order_acquire);
        if (seq & 1) continue;
        int64_t base = atomic_load_explicit(&sg_base, memory_order_relaxed);
        int64_t warpedBase = atomic_load_explicit(&sg_warpedBase, memory_order_relaxed);
        float rate = atomic_load_explicit(&sg_rate, memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&sg_seq, memory_order_relaxed) == seq) return warpedBase + (int64_t)((double)(now - base) * rate);
    }
}

// the bucket's two reads, told by the code they return to (both reach the clock through tail calls):
// - elapsed time: ldp of the tokens and the last read from [bucket + 0x30], then a divide by 1,000,000
// - the last read: str x0 to [bucket + 0x38], after add x0, bucket, #0x10 (its clock) and the bl
static BOOL fromBucket(void *returnAddress) {
#if __has_feature(ptrauth_calls)
    returnAddress = ptrauth_strip(returnAddress, ptrauth_key_return_address);
#endif
    const uint32_t *ret = returnAddress;
    uint32_t next = ret[0];
    if ((next & 0xFFC00000) == 0xA9400000 && ((next >> 15) & 0x7F) == 0x30 / 8) {
        // mov wN, #0x4240 then movk wN, #0xf, lsl #16
        for (int i = 1; i < 5; i++) {
            if ((ret[i] & 0x7FFFFFE0) == 0x52884800 && (ret[i + 1] & 0x7FFFFFE0) == 0x72A001E0) return YES;
        }
        return NO;
    }
    if ((next & 0xFFFFFC1F) == 0xF9000000 + ((0x38 / 8) << 10)) {
        uint32_t add = ret[-2];
        return (add & 0xFFFFFC1F) == 0x91000000 + (0x10 << 10) && ((add >> 5) & 31) == ((next >> 5) & 31);
    }
    return NO;
}

// any thread, the render threads included: no locks, no allocation, no log.
static int64_t now(void *returnAddress) {
    int64_t real = sg_realNow();
    if (!fromBucket(returnAddress)) return real;
    if (!atomic_load_explicit(&sg_bucketSeen, memory_order_relaxed)) atomic_store_explicit(&sg_bucketSeen, true, memory_order_relaxed);
    return warped(real);
}

static int64_t reboundNow(void) {
    return now(__builtin_return_address(0));
}

// the inline hook catches every caller in the process; only Spotify's are looked at.
static int64_t inlineNow(void) {
    void *returnAddress = __builtin_return_address(0);
    return EeveeCalledFromSpotify(returnAddress) ? now(returnAddress) : sg_realNow();
}

BOOL SpeedPitchMixerLimitInstall(void) {
    BOOL taken = EeveeRebindImport(kSteadyNow, (void *)reboundNow, (void **)&sg_realNow) && sg_realNow;
    if (!taken) {
        sg_realNow = NULL;
        void *function = dlsym(RTLD_DEFAULT, kSteadyNow);
        taken = function && EeveeHookFunctionInline(function, (void *)inlineNow, (void **)&sg_realNow) && sg_realNow;
    }
    if (!taken) {
        sg_realNow = NULL;
        SPLog(@"mixer limit: Spotify's steady_clock::now could be neither rebound nor hooked, above 1.2x the sound pauses");
        return NO;
    }
    int64_t start = sg_realNow();
    atomic_store(&sg_base, start);
    atomic_store(&sg_warpedBase, start);
    return YES;
}

void SpeedPitchMixerLimitSetSpeed(float speed) {
    if (!sg_realNow) return;
    float rate = fmaxf(1, speed);
    if (rate == atomic_load(&sg_rate)) return;
    int64_t real = sg_realNow();
    // rebased at the old rate, so the timeline never jumps.
    int64_t at = warped(real);
    atomic_fetch_add_explicit(&sg_seq, 1, memory_order_acq_rel);
    atomic_store_explicit(&sg_base, real, memory_order_relaxed);
    atomic_store_explicit(&sg_warpedBase, at, memory_order_relaxed);
    atomic_store_explicit(&sg_rate, rate, memory_order_relaxed);
    atomic_fetch_add_explicit(&sg_seq, 1, memory_order_release);
    SPLog(@"mixer limit: follows %.2fx (Spotify's mixer %@)", rate, atomic_load(&sg_bucketSeen) ? @"seen" : @"not seen yet");
}
