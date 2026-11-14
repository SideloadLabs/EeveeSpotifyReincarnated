#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "PixiePageController.h"
#include <assert.h>
#include <string.h>

@implementation UITableViewController
- (instancetype)initWithStyle:(UITableViewStyle)style { return [super init]; }
@end
#include "PageContractControllers.inc"

static Protocol *pageProtocol(const char *name,BOOL unsupported) {
    Protocol *page=objc_allocateProtocol(name);assert(page);
    protocol_addProtocol(page,@protocol(NSObject));
    protocol_addMethodDescription(page,@selector(spt_pageIdentifier),"@16@0:8",YES,YES);
    protocol_addMethodDescription(page,@selector(spt_pageURI),"@16@0:8",YES,YES);
    protocol_addMethodDescription(page,NSSelectorFromString(@"spt_pageContainer"),"@16@0:8",NO,YES);
    if(unsupported)protocol_addMethodDescription(page,NSSelectorFromString(@"futureRequiredPageMethod"),"@16@0:8",YES,YES);
    objc_registerProtocol(page);return page;
}
static BOOL inheritsProtocol(Class cls,Protocol *protocol) {
    for(;cls;cls=class_getSuperclass(cls))if(class_conformsToProtocol(cls,protocol))return YES;
    return NO;
}
int main(int argc,char **argv) { @autoreleasepool {
    assert(argc==2);NSString *scenario=@(argv[1]);
    const char *swift="_TtP19Tome_PageAttributes17SPTPageController_";
    Protocol *first=nil,*second=nil;
    if([scenario isEqual:@"late"]) {
        SAPOfflineLibraryController *early=[SAPOfflineLibraryController new];
        assert(early && !SAPRegisterPixiePageProtocols());
    }
    if([scenario isEqual:@"legacy"])first=pageProtocol("SPTPageController",NO);
    else if([scenario isEqual:@"lookalike"])first=pageProtocol("UnrelatedSPTPageControllerMarker",NO);
    else first=pageProtocol(swift,[scenario isEqual:@"unsupported"]);
    if([scenario isEqual:@"both"])second=pageProtocol("SPTPageController",NO);

    BOOL valid=![scenario isEqual:@"unsupported"] && ![scenario isEqual:@"lookalike"];
    assert(SAPRegisterPixiePageProtocols()==valid);
    assert(class_conformsToProtocol(SAPPixiePageController.class,first)==valid);
    // The native validation can occur at any later tab interaction; test the
    // class metadata as well as the ordinary instance conformance message.
    for(Class cls in @[SAPOfflineLibraryController.class,SAPSettingsTable.class]) {
        SAPPixiePageController *page=[cls new];
        assert(inheritsProtocol(cls,first)==valid);
        assert([page conformsToProtocol:first]==valid);
        if(second)assert(inheritsProtocol(cls,second));
        assert(page.spt_pageIdentifier.length && [page.spt_pageIdentifier isEqual:page.spt_pageIdentifier]);
        assert([page.spt_pageURI.scheme isEqual:@"spotify"] && page.spt_pageURI.absoluteString.length>8);
        assert([page respondsToSelector:@selector(spt_pageIdentifier)] && [page respondsToSelector:@selector(spt_pageURI)]);
    }
    // All nested Downloaded levels and settings detail pages inherit the
    // same real metadata, rather than a special case for the first page.
    Class nested=objc_allocateClassPair(SAPOfflineLibraryController.class,"NestedDownloadedPage",0);objc_registerClassPair(nested);
    assert(inheritsProtocol(nested,first)==valid);
    Protocol *lookalike=pageProtocol("AnotherSPTPageControllerLookalike",NO);
    assert(!inheritsProtocol(nested,lookalike));
    assert(![[nested new]conformsToProtocol:lookalike]);
    printf("PASS: real page contract %s; native validation, metadata and inherited pages\n",argv[1]);
}return 0;}
