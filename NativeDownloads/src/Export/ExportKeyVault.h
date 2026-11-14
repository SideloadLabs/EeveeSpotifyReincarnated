#pragma once
#import <Foundation/Foundation.h>
// Native observation callbacks enqueue work; Keychain is never accessed inline.
void SAPVaultObserveMedia(NSData *fileID,NSData *unsealedKey);
void SAPVaultObserveMapping(NSData *fileID,NSString *namespaceID);
void SAPVaultObserveStorage(NSString *namespaceID,NSData *storageKey);
// Only call from the export worker. Exact native storage namespace is mandatory.
BOOL SAPVaultCopyMedia(NSData *fileID,NSString *namespaceID,uint8_t output[16]);
BOOL SAPVaultCopyStorage(NSString *namespaceID,uint8_t output[16]);
NSDictionary *SAPExportKeyVaultReport(void);
#ifdef SAP_VAULT_TESTING
void SAPVaultSetBackendForTesting(BOOL (^write)(NSString *,NSData *),NSData *(^read)(NSString *));
void SAPVaultDrainForTesting(void);
void SAPVaultResetMemoryForTesting(void);
#endif
