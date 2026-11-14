#pragma once
// One state owner, initialized by SAPJournalSetup. Mutation remains confined to
// its existing serial queue; report readers use the same unfair lock as before.
#import "Localization.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "NativeErrorLog.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#import "JournalStorage.h"
#import "JournalNames.h"
#include <os/lock.h>
#include <stdatomic.h>

// Границы: журнал живёт внутри Spotify и не должен расти без предела.
static const NSUInteger maximumTracks = 20000, maximumTransitions = 400, maximumEvents = 120;
static const NSUInteger maximumEntities = 24, maximumTrackTransitions = 12;
static const NSUInteger chunkSize = 300, maximumChunks = 12, maximumReportedTracks = 3000;
static const double refreshThrottle = 2, pollInterval = 5, sessionIdleTimeout = 45;
static const double maximumSessionSeconds = 1800, stalledAfter = 45;

@interface SAPTrack : NSObject {
@public
    NSString *uri, *entity, *lastSource;
    NSUInteger state, videoState, progress, maxProgress, observations, rowQueries, addRequests, removeRequests;
    BOOL seen;
    NSInteger legacyState;
    double legacyAt, iconAt, wireAt;
    NSInteger uiStatus;              // значок строки: 0 нет, 1 ожидание, 2 идёт, 3 скачан, 4 ошибка
    double firstSeen, lastSeen, lastChange, enteredState, lastProgressAt, requestedAt;
    NSNumber *requestError;
    NSDictionary *nativeError;
    double nativeKeyAt, nativeDownloadAt;
    NSMutableArray *nativeEvents;
    NSMutableArray *history, *errors;
    NSMutableDictionary *timeInState;
}
@end

typedef struct {
    os_unfair_lock lock;
    dispatch_queue_t journal;
    void *journalKey;
    SAPJournalCaller caller;
    void (^quotaSampler)(void);
    atomic_bool callerAvailable;
    NSMutableDictionary *outstanding;
    NSMutableArray *transportEvents;
    NSString *focusedURI;
    NSMutableArray *unanswered;
    NSMutableArray *lifetimes;
    dispatch_source_t pollTimer;
    BOOL subscribed;
    double lastRefresh,lastQuotaSample;
    NSUInteger pollTicks,subscriptionGeneration,playerTraceSessionGeneration;
    atomic_uint playerTraceSinkPending,playerTraceSinkDropped;
    NSMutableDictionary *tracks;
    NSMutableArray *transitions,*errorEvents,*contextAddedEvents,*entityEvents;
    NSMutableDictionary *entities,*snapshots,*methodCalls;
    NSMutableArray *totalProgressSamples;
    NSDictionary *totalProgress;
    NSMutableDictionary *session;
    NSMutableArray *sessionHistory,*actionEvents;
    double journalStarted;
    NSMutableDictionary *reconciliationTimes;
} SAPJournalState;
extern SAPJournalState SAPJournalStateStorage __attribute__((visibility("hidden")));

static inline double rightNow(void) { return CFAbsoluteTimeGetCurrent(); }
static inline NSNumber *stamp(double value) { return value > 0 ? @(round((value + kCFAbsoluteTimeIntervalSince1970) * 1000) / 1000) : nil; }
static inline NSNumber *age(double value) { return value > 0 ? @(round((rightNow() - value) * 10) / 10) : nil; }

static inline NSString *contextStateName(NSUInteger state) {
    switch (state) {
        case 0: return @"not_downloaded"; case 1: return @"error"; case 2: return @"requested";
        case 3: return @"downloaded"; case 4: return @"downloading"; case 5: return @"waiting"; default: return @"unknown";
    }
}
static inline NSString *reasonName(uint64_t reason) {
    switch (reason) {
        case 0: return @"unspecified"; case 1: return @"user_local_device"; case 2: return @"user_remote_device";
        case 3: return @"auto_download"; default: return @"unknown";
    }
}
// Незавершённые состояния: трек ещё должен куда-то перейти.
static inline BOOL pendingState(NSUInteger state) { return state == 4 || state == 5 || state == 6; }
static inline BOOL failedState(NSUInteger state) { return state == 1 || state == 7; }
// Periodic GetItems polling covers only work in progress: tracks Spotify reports
// as queued/waiting/downloading, and tracks Pixie asked to download whose first
// native state has not arrived. Tracks merely seen in a catalog stream, already
// downloaded, failed or not requested are never re-queried.
static inline BOOL SAPJournalNeedsPoll(BOOL seen, NSUInteger state, NSUInteger addRequests) {
    return seen ? pendingState(state) : addRequests > 0;
}
static inline NSString *shortIdentifier(NSString *uri) {
    NSRange range = [uri rangeOfString:@":" options:NSBackwardsSearch];
    return range.location == NSNotFound ? uri : [uri substringFromIndex:range.location + 1];
}


static inline void trimEvents(NSMutableArray *list, NSUInteger limit) { while (list.count > limit) [list removeObjectAtIndex:0]; }

void SAPJournalSetup(void);
void SAPJournalOnQueue(void (^work)(void));
SAPTrack *SAPJournalRecordFor(NSString *uri);
void SAPJournalApplyState(NSString *uri,NSUInteger state,NSUInteger videoState,NSUInteger progress,BOOL hasProgress,NSString *source);
void SAPJournalBeginSession(NSString *reason,NSString *entity);
void SAPJournalEndSessionIfIdle(void);
void SAPJournalRequestReconciliation(NSString *uri);
void SAPJournalCancelLifetimes(void);
void SAPJournalStopPolling(void);
void SAPJournalDiagnosticsChanged(void);
NSDictionary *SAPJournalStateCountsLocked(NSUInteger *pendingOut);
NSDictionary *SAPJournalTrackDictionary(SAPTrack *record,double moment);
void SAPJournalDecodeCall(NSString *method,NSData *request,NSData *response,NSString *source);
NSArray *SAPJournalSubMessages(NSArray *fields,unsigned number);
NSArray *SAPJournalStringList(NSArray *fields,unsigned number);
