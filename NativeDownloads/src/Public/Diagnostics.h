#pragma once
#include <stdbool.h>

// The audio callback reads only an atomic flag. Preferences and notifications
// are handled outside the render thread.
bool SAPDiagnosticsEnabled(void);
void SAPDiagnosticsInitialize(void);
__attribute__((visibility("default"))) void SAPDiagnosticsSetEnabled(bool enabled);
#ifdef __OBJC__
#import <Foundation/Foundation.h>
FOUNDATION_EXPORT NSNotificationName const SAPDiagnosticsDidChangeNotification;
#endif
