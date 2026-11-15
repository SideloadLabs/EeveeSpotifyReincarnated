#import "NativeErrorLog.h"
#import "TrackJournal.h"
#import "Diagnostics.h"
#import "DiagnosticTrace.h"
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdatomic.h>
#include <string.h>
static atomic_bool wanted,installed;
static id nativeLog,observer;
static void parseLine(NSString *line,NSDictionary *sourceContext) {
    // The Swift logger's NSData includes the trailing C terminator on device.
    while(line.length && [line characterAtIndex:line.length-1]==0)line=[line substringToIndex:line.length-1];
    static NSRegularExpression *error,*key,*success;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        error=[NSRegularExpression regularExpressionWithPattern:@"^Offline track error: ([a-zA-Z0-9_]+) \\(([0-9]+)\\) \\((spotify:track:[a-zA-Z0-9]{22})\\)" options:0 error:NULL];
        key=[NSRegularExpression regularExpressionWithPattern:@"^Track (spotify:track:[a-zA-Z0-9]{22}): Key failed: ([a-zA-Z0-9_]+)" options:0 error:NULL];
        success=[NSRegularExpression regularExpressionWithPattern:@"^Track (spotify:track:[a-zA-Z0-9]{22})(: Got key| downloaded)$" options:0 error:NULL];
    });
    NSTextCheckingResult *match=[error firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
    if(match) {
        NSString *uri=[line substringWithRange:[match rangeAtIndex:3]],*name=[line substringWithRange:[match rangeAtIndex:1]];NSNumber *code=@([[line substringWithRange:[match rangeAtIndex:2]]longLongValue]);
        SAPTraceID observation=SAPTraceIsActive()?SAPTraceBegin(@"native_error_source_line",@"SPTLog",@{@"uri":uri,@"name":name,@"code":code,@"source_context":sourceContext?:@{}}):0;
        SAPTraceWithOperation(observation,^{SAPJournalNoteNativeError(uri,code,name);});return;
    }
    match=[key firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
    if(match) {NSString *uri=[line substringWithRange:[match rangeAtIndex:1]],*name=[line substringWithRange:[match rangeAtIndex:2]];
        SAPTraceID observation=SAPTraceIsActive()?SAPTraceBegin(@"native_key_error_source_line",@"SPTLog",@{@"uri":uri,@"name":name,@"code":NSNull.null,@"source_context":sourceContext?:@{}}):0;
        SAPTraceWithOperation(observation,^{SAPJournalNoteNativeError(uri,nil,name);});return;}
    match=[success firstMatchInString:line options:0 range:NSMakeRange(0,line.length)];
    if(match){NSString *uri=[line substringWithRange:[match rangeAtIndex:1]],*event=[[line substringWithRange:[match rangeAtIndex:2]]isEqual:@": Got key"]?@"key_received":@"downloaded";
        SAPTraceID observation=SAPTraceIsActive()?SAPTraceBegin(@"native_success_source_line",@"SPTLog",@{@"uri":uri,@"event":event,@"source_context":sourceContext?:@{}}):0;
        SAPTraceWithOperation(observation,^{SAPJournalNoteNativeSuccess(uri,event);});}
}
@interface SAPNativeOfflineErrorObserver : NSObject @end
@implementation SAPNativeOfflineErrorObserver
- (void)log:(id)log wroteLine:(const char *)line fromModule:(const char *)module file:(const char *)file line:(NSInteger)number threadId:(NSUInteger)thread at:(id)date logLevel:(int)level isBreadcrumb:(BOOL)crumb {
    if(!SAPDiagnosticsEnabled()||!atomic_load(&wanted)||!line)return;
    // Fast prefix filter before any allocation. No URLs, keys or general log lines are kept.
    if(strncmp(line,"Offline track error: ",21) && strncmp(line,"Track spotify:track:",20))return;
    size_t length=strnlen(line,1025);if(length>1024)return;
    NSString *value=[[NSString alloc]initWithBytes:line length:length encoding:NSUTF8StringEncoding];
    if(value)parseLine(value,SAPTraceIsActive()?@{@"module":module?@(module):@"unknown",@"file":file?@(file):@"unknown",@"line":@(number),@"native_thread_id":@(thread),@"native_event_epoch_seconds":[date isKindOfClass:NSDate.class]?@([date timeIntervalSince1970]):NSNull.null}:nil);
}
- (void)logSwift:(id)log line:(NSData *)data module:(NSString *)module file:(NSString *)file line:(NSInteger)number threadId:(NSUInteger)thread at:(id)date logLevel:(int)level isBreadcrumb:(BOOL)crumb {
    if(!SAPDiagnosticsEnabled()||!atomic_load(&wanted)||![data isKindOfClass:NSData.class]||data.length>1024||data.length<20)return;
    const char *bytes=data.bytes;
    if(memcmp(bytes,"Track spotify:track:",20) && (data.length<21||memcmp(bytes,"Offline track error: ",21)))return;
    NSString *value=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];if(value)parseLine(value,SAPTraceIsActive()?@{@"module":module?:@"unknown",@"file":file?:@"unknown",@"line":@(number),@"native_thread_id":@(thread),@"native_event_epoch_seconds":[date isKindOfClass:NSDate.class]?@([date timeIntervalSince1970]):NSNull.null}:nil);
}
@end
void SAPNativeErrorLogSetActive(BOOL active) {
    active=(active||SAPTraceIsActive()) && SAPDiagnosticsEnabled();
    atomic_store(&wanted,active);
    dispatch_async(dispatch_get_main_queue(),^{
        if(!atomic_load(&wanted)) {
            if(nativeLog) {
                ((void(*)(id,SEL,id))objc_msgSend)(nativeLog,NSSelectorFromString(@"removeObserver:"),observer);
                ((void(*)(id,SEL))objc_msgSend)(nativeLog,NSSelectorFromString(@"uninstall"));
            }
            nativeLog=nil;observer=nil;atomic_store(&installed,false);return;
        }
        if(nativeLog)return;
        Class cls=NSClassFromString(@"SPTLog");SEL create=NSSelectorFromString(@"createAndInstallLogWithObserver:identificator:");
        if(![cls respondsToSelector:create])return;
        Protocol *protocol=objc_getProtocol("SPTLogObserver");if(protocol)class_addProtocol(SAPNativeOfflineErrorObserver.class,protocol);
        observer=[SAPNativeOfflineErrorObserver new];
        nativeLog=((id(*)(id,SEL,id,id))objc_msgSend)(cls,create,observer,@"SAPNativeOfflineErrors");
        atomic_store(&installed,nativeLog!=nil);
        SAP_TRACE("observer","native_error_log_install_result",0,@{@"requested":@(atomic_load(&wanted)),@"installed":@(nativeLog!=nil),@"source":@"SPTLog"});
    });
}
NSDictionary *SAPNativeErrorLogReport(void) {return @{@"requested":@(atomic_load(&wanted)),@"installed":@(atomic_load(&installed))};}
#ifdef SAP_TESTING
void SAPNativeErrorLogParseForTesting(NSString *line) {if(line.length<=1024)parseLine(line,nil);}
#endif
