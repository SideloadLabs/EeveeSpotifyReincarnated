#import <os/lock.h>
#import "SGFlagForce.h"
#import "SGPrefs.h"

@interface SGFlagForcerEntry : NSObject
@property (nonatomic) BOOL beatsOverride;
@property (nonatomic, copy) SGFlagForcer atLaunch, locked;
@end

@implementation SGFlagForcerEntry
@end

// Swapped whole under the lock, so a reader walks an immutable array.
static os_unfair_lock sg_lock = OS_UNFAIR_LOCK_INIT;
static NSArray<SGFlagForcerEntry *> *sg_forcers;

void SGRegisterFlagForcer(BOOL beatsOverride, SGFlagForcer atLaunch, SGFlagForcer locked) {
    if (!atLaunch) return;
    SGFlagForcerEntry *entry = [SGFlagForcerEntry new];
    entry.beatsOverride = beatsOverride;
    entry.atLaunch = atLaunch;
    entry.locked = locked;
    os_unfair_lock_lock(&sg_lock);
    sg_forcers = [(sg_forcers ?: @[]) arrayByAddingObject:entry];
    os_unfair_lock_unlock(&sg_lock);
}

static NSArray<SGFlagForcerEntry *> *forcers(void) {
    os_unfair_lock_lock(&sg_lock);
    NSArray *list = sg_forcers;
    os_unfair_lock_unlock(&sg_lock);
    return list;
}

id SGForcedFlagValue(NSString *key) {
    if (!key) return nil;
    NSArray<SGFlagForcerEntry *> *list = forcers();
    for (SGFlagForcerEntry *entry in list) {
        if (!entry.beatsOverride) continue;
        id value = entry.atLaunch(key);
        if (value) return value;
    }
    id value = SGFlagOverride(key);
    if (value) return value;
    for (SGFlagForcerEntry *entry in list) {
        if (entry.beatsOverride) continue;
        value = entry.atLaunch(key);
        if (value) return value;
    }
    return nil;
}

id SGLockedFlagValue(NSString *key, BOOL *beatsOverride) {
    if (beatsOverride) *beatsOverride = NO;
    if (!key) return nil;
    NSArray<SGFlagForcerEntry *> *list = forcers();
    for (int pass = 0; pass < 2; pass++) {
        BOOL first = pass == 0;
        for (SGFlagForcerEntry *entry in list) {
            if (entry.beatsOverride != first || !entry.locked) continue;
            id value = entry.locked(key);
            if (!value) continue;
            if (beatsOverride) *beatsOverride = first;
            return value;
        }
    }
    return nil;
}
