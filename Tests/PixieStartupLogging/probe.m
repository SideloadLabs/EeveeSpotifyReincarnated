#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <assert.h>
#include <string.h>
#include <stdint.h>

NSString *EeveePixieStartupSummary(void);
static BOOL hasFactory,hasReport,imageLoaded;
static NSString *state,*frameworks;
static NSUInteger factoryCalls,reportCalls;
static id factory(void){factoryCalls++;return nil;}
static NSDictionary *report(void){reportCalls++;return @{ @"version":@"test-pixie",@"state":state };}
void *SAPTestDlsym(void *handle,const char *symbol){
    if(!strcmp(symbol,"SAPCreateDownloadsSettings"))return hasFactory?(void *)factory:NULL;
    if(!strcmp(symbol,"SAPStartupReport"))return hasReport?(void *)report:NULL;
    return NULL;
}
uint32_t SAPTestImageCount(void){return imageLoaded?1:0;}
const char *SAPTestImageName(uint32_t index){return "/test/Frameworks/SpotifyAudioProbe.dylib";}
static NSString *frameworkPath(id object,SEL selector){return frameworks;}
static void expect(BOOL error,NSString *detail){
    NSUInteger before=reportCalls;
    NSString *line=EeveePixieStartupSummary();
    assert([line hasPrefix:@"[ERROR]"]==error && [line containsString:detail]);
    assert(![line containsString:@"\n"] && factoryCalls==0);
    assert(reportCalls-before==(hasReport?1:0));
}
int main(int argc,const char **argv){@autoreleasepool{
    assert(argc==2);frameworks=@(argv[1]);
    Method method=class_getInstanceMethod(NSBundle.class,@selector(privateFrameworksPath));
    IMP original=method_setImplementation(method,(IMP)frameworkPath);
    // The optional module's absence and older loaded companions are not errors.
    expect(NO,@"not bundled");
    hasFactory=YES;expect(NO,@"older companion");
    hasReport=YES;state=@"complete";expect(NO,@"bootstrap=complete");
    // Every observable incomplete/failed status is explicitly an error.
    for(NSString *value in @[@"not_started",@"initializing",@"native_setup_unavailable",@"unknown"]){state=value;expect(YES,value);}
    state=@"complete";hasFactory=NO;expect(YES,@"entry point missing");
    hasReport=NO;imageLoaded=YES;expect(YES,@"library loaded but settings entry point missing");
    imageLoaded=NO;
    NSURL *file=[NSURL fileURLWithPath:[frameworks stringByAppendingPathComponent:@"SpotifyAudioProbe.dylib"]];
    assert([NSData.data writeToURL:file atomically:YES]);
    expect(YES,@"bundled but not loaded");
    [NSFileManager.defaultManager removeItemAtURL:file error:NULL];
    expect(NO,@"not bundled");
    method_setImplementation(method,original);
    puts("PASS: real startup probe reports observable load/API/bootstrap failures, preserves legacy/optional-module behavior and never instantiates the module");
}return 0;}
