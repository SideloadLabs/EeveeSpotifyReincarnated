#import "Diagnostics.h"
#include <stdatomic.h>

NSNotificationName const SAPDiagnosticsDidChangeNotification=@"SAPDiagnosticsDidChange";
static NSString *const preferenceKey=@"SAPDiagnosticsEnabled";
static atomic_bool enabled;
extern void SAPTraceSetEnabled(bool,const char *) __attribute__((weak_import));
extern void SAPTracePlatformSetActive(bool) __attribute__((weak_import));

bool SAPDiagnosticsEnabled(void) {return atomic_load_explicit(&enabled,memory_order_relaxed);}
void SAPDiagnosticsInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        bool value=[NSUserDefaults.standardUserDefaults boolForKey:preferenceKey];atomic_store(&enabled,value);
        if(value&&SAPTraceSetEnabled)SAPTraceSetEnabled(true,"persisted_on_library_load");
        if(value&&SAPTracePlatformSetActive)SAPTracePlatformSetActive(true);
    });
}
void SAPDiagnosticsSetEnabled(bool value) {
    SAPDiagnosticsInitialize();
    if(atomic_exchange(&enabled,value)==value)return;
    if(SAPTraceSetEnabled)SAPTraceSetEnabled(value,"user_changed_diagnostics");
    if(SAPTracePlatformSetActive)SAPTracePlatformSetActive(value);
    [NSUserDefaults.standardUserDefaults setBool:value forKey:preferenceKey];
    [NSNotificationCenter.defaultCenter postNotificationName:SAPDiagnosticsDidChangeNotification object:nil];
}
