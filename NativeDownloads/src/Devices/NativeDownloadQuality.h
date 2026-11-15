#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *const SAPNativeDownloadQualityOfferDidChangeNotification;

// Bootstrap once. Passive observation of the exact native download-quality setter.
void SAPInstallNativeDownloadQualityObservation(void);
// Main thread, on explicit Downloaded tracks entry. Unknown/unloaded may defer;
// every recognized value makes a cached persistent decision without future reads.
BOOL SAPShouldOfferNativeDownloadQuality(void);
// Main thread from the existing settings navigation. Saves suppression before routing,
// including when the native navigation bridge is unavailable or returns NO.
BOOL SAPDismissNativeDownloadQualityOfferAndOpenSettings(void);
