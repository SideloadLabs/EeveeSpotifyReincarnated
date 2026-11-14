#import "PixiePageController.h"
#import <objc/runtime.h>
#include <stdlib.h>

static BOOL SAPPageImplementsProtocol(Class page,Protocol *protocol) {
    for(unsigned kind=0;kind<2;kind++) {
        unsigned count=0;
        struct objc_method_description *methods=protocol_copyMethodDescriptionList(protocol,YES,kind==0,&count);
        BOOL complete=YES;
        for(unsigned i=0;i<count;i++) {
            Method method=kind==0?class_getInstanceMethod(page,methods[i].name):class_getClassMethod(page,methods[i].name);
            if(!method){complete=NO;break;}
        }
        free(methods);if(!complete)return NO;
    }
    unsigned count=0;Protocol *__unsafe_unretained *parents=protocol_copyProtocolList(protocol,&count);
    BOOL complete=YES;
    for(unsigned i=0;i<count;i++)if(!SAPPageImplementsProtocol(page,parents[i])){complete=NO;break;}
    free(parents);return complete;
}

BOOL SAPRegisterPixiePageProtocols(void) {
    Class page=SAPPixiePageController.class;
    BOOL found=NO,complete=YES;
    // The first is the exact protocol in supported Spotify 9.1.90. Some older
    // hosts expose the Objective-C name instead. Do not claim lookalike names.
    const char *names[]={"_TtP19Tome_PageAttributes17SPTPageController_","SPTPageController"};
    for(unsigned i=0;i<sizeof(names)/sizeof(*names);i++) {
        Protocol *protocol=objc_getProtocol(names[i]);if(!protocol)continue;
        found=YES;
        if(!SAPPageImplementsProtocol(page,protocol)){complete=NO;continue;}
        if(!class_conformsToProtocol(page,protocol))class_addProtocol(page,protocol);
        complete=class_conformsToProtocol(page,protocol)&&complete;
    }
    return found&&complete;
}

@implementation SAPPixiePageController
- (instancetype)initWithStyle:(UITableViewStyle)style {
    SAPRegisterPixiePageProtocols();
    return [super initWithStyle:style];
}
- (NSString *)spt_pageIdentifier {return NSStringFromClass(self.class);}
- (NSURL *)spt_pageURI {
    return [NSURL URLWithString:[@"spotify:internal:pixie:" stringByAppendingString:self.spt_pageIdentifier]];
}
@end
