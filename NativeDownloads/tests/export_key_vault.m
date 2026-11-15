#import <Foundation/Foundation.h>
#import "ExportKeyVault.h"
#include <assert.h>
int main(void){@autoreleasepool {
 NSMutableDictionary *disk=[NSMutableDictionary dictionary];__block NSUInteger writes=0;
 SAPVaultSetBackendForTesting(^BOOL(NSString *name,NSData *key){disk[name]=key;writes++;return YES;},^NSData *(NSString *name){return disk[name];});
 NSData *file=[NSMutableData dataWithLength:20],*key=[@"0123456789abcdef" dataUsingEncoding:NSUTF8StringEncoding];
 NSString *space=@"0123456789abcdef0123456789abcdef01234567",*other=@"1123456789abcdef0123456789abcdef01234567";
 SAPVaultObserveMedia(file,key);SAPVaultDrainForTesting();assert(writes==0);
 SAPVaultObserveMapping(file,space);SAPVaultDrainForTesting();assert(writes==1);
 SAPVaultObserveMedia(file,key);SAPVaultObserveMapping(file,space);SAPVaultDrainForTesting();assert(writes==1);
 uint8_t bytes[16];assert(SAPVaultCopyMedia(file,space,bytes)&&!memcmp(bytes,key.bytes,16));
 assert(!SAPVaultCopyMedia(file,other,bytes));assert(!SAPVaultCopyMedia(file,@"",bytes));
 SAPVaultResetMemoryForTesting();assert(SAPVaultCopyMedia(file,space,bytes));
 SAPVaultObserveStorage(space,key);SAPVaultDrainForTesting();assert(SAPVaultCopyStorage(space,bytes));
 assert(!SAPVaultCopyStorage(other,bytes));
 SAPVaultObserveMedia(file,[NSMutableData dataWithLength:3]);SAPVaultDrainForTesting();assert(writes==2);
 puts("PASS vault namespace isolation, restart reuse, duplicate write coalescing, invalid length rejection");
}return 0;}
