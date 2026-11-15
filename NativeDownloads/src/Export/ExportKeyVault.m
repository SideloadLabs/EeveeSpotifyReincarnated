#import "ExportKeyVault.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <stdatomic.h>
static dispatch_queue_t queue;
static NSMutableDictionary *pending,*namespaces,*saved;
static NSString *service;
static atomic_uint_fast64_t writes,failures,hits,misses;
static atomic_int lastWriteStatus;
#ifdef SAP_VAULT_TESTING
static BOOL (^testWrite)(NSString *,NSData *);
static NSData *(^testRead)(NSString *);
#endif
static void initialize(void){static dispatch_once_t once;dispatch_once(&once,^{
    queue=dispatch_queue_create("com.pixie.export-key-vault",DISPATCH_QUEUE_SERIAL);
    pending=[NSMutableDictionary dictionary];namespaces=[NSMutableDictionary dictionary];saved=[NSMutableDictionary dictionary];
});}
static BOOL validNamespace(NSString *value){return [value isKindOfClass:NSString.class]&&value.length==40&&[value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet].location==NSNotFound;}
static NSString *identifier(NSData *file){if(file.length!=20)return nil;NSMutableString *s=[NSMutableString string];const uint8_t *p=file.bytes;for(unsigned i=0;i<20;i++)[s appendFormat:@"%02x",p[i]];return s;}
static NSDictionary *query(NSString *name){
    if(!service){
        NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;NSString *installation=[defaults stringForKey:@"PixieExportVaultInstallation"];
        if(!installation.length){installation=NSUUID.UUID.UUIDString;[defaults setObject:installation forKey:@"PixieExportVaultInstallation"];}
        // A new app container cannot read keys left by an earlier installation.
        service=[@"com.pixie.export.v1." stringByAppendingString:installation];
    }
    return @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword,(__bridge id)kSecAttrService:service,(__bridge id)kSecAttrAccount:name};
}
static void save(NSString *name,NSData *key){
    if(key.length!=16)return;
    // Retain only a one-way digest for deduplication after the Keychain write.
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(key.bytes,(CC_LONG)key.length,digest);NSData *fingerprint=[NSData dataWithBytes:digest length:sizeof(digest)];
    if([saved[name]isEqual:fingerprint])return;
    BOOL ok=NO;
#ifdef SAP_VAULT_TESTING
    if(testWrite)ok=testWrite(name,key);atomic_store(&lastWriteStatus,ok?0:errSecNotAvailable);
#else
    {
        NSDictionary *base=query(name),*value=@{(__bridge id)kSecValueData:key};
        OSStatus code=SecItemUpdate((__bridge CFDictionaryRef)base,(__bridge CFDictionaryRef)value);
        if(code==errSecItemNotFound){NSMutableDictionary *item=[base mutableCopy];[item addEntriesFromDictionary:value];item[(__bridge id)kSecAttrAccessible]=(__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;item[(__bridge id)kSecAttrSynchronizable]=@NO;code=SecItemAdd((__bridge CFDictionaryRef)item,NULL);}
        ok=code==errSecSuccess;atomic_store(&lastWriteStatus,code);
    }
#endif
    if(ok){if(saved.count>=2048)[saved removeObjectForKey:saved.allKeys.firstObject];saved[name]=fingerprint;atomic_fetch_add(&writes,1);}else atomic_fetch_add(&failures,1);
}
static void persistPending(NSString *file){NSData *key=pending[file];NSString *space=namespaces[file];if(key&&space)save([NSString stringWithFormat:@"media/%@/%@",space,file],key);}
void SAPVaultObserveMedia(NSData *fileID,NSData *key){NSString *file=identifier(fileID);if(!file||key.length!=16)return;initialize();key=[key copy];dispatch_async(queue,^{
    if(pending.count>=1024&&!pending[file])[pending removeObjectForKey:pending.allKeys.firstObject];pending[file]=key;persistPending(file);
});}
void SAPVaultObserveMapping(NSData *fileID,NSString *space){NSString *file=identifier(fileID);if(!file||!validNamespace(space))return;initialize();dispatch_async(queue,^{
    if(namespaces.count>=1024&&!namespaces[file])[namespaces removeObjectForKey:namespaces.allKeys.firstObject];namespaces[file]=space;persistPending(file);
});}
void SAPVaultObserveStorage(NSString *space,NSData *key){if(!validNamespace(space)||key.length!=16)return;initialize();key=[key copy];dispatch_async(queue,^{save([@"storage/" stringByAppendingString:space],key);});}
static BOOL copy(NSString *name,uint8_t output[16]){
    if(!name||!output)return NO;initialize();__block NSData *data=nil;
    dispatch_sync(queue,^{
#ifdef SAP_VAULT_TESTING
        if(testRead)data=testRead(name);
#else
        {
            NSMutableDictionary *q=[query(name)mutableCopy];q[(__bridge id)kSecReturnData]=@YES;q[(__bridge id)kSecMatchLimit]=(__bridge id)kSecMatchLimitOne;
            CFTypeRef result=NULL;OSStatus status=SecItemCopyMatching((__bridge CFDictionaryRef)q,&result);
            if(status==errSecSuccess&&result&&CFGetTypeID(result)==CFDataGetTypeID())data=CFBridgingRelease(result);else if(result)CFRelease(result);
        }
#endif
    });
    BOOL ok=data.length==16;if(ok){memcpy(output,data.bytes,16);atomic_fetch_add(&hits,1);}else atomic_fetch_add(&misses,1);return ok;
}
BOOL SAPVaultCopyMedia(NSData *fileID,NSString *space,uint8_t output[16]){NSString *file=identifier(fileID);return file&&validNamespace(space)&&copy([NSString stringWithFormat:@"media/%@/%@",space,file],output);}
BOOL SAPVaultCopyStorage(NSString *space,uint8_t output[16]){return validNamespace(space)&&copy([@"storage/" stringByAppendingString:space],output);}
NSDictionary *SAPExportKeyVaultReport(void){return @{@"successful_writes":@(atomic_load(&writes)),@"write_failures":@(atomic_load(&failures)),@"last_write_osstatus":atomic_load(&writes)+atomic_load(&failures)?@(atomic_load(&lastWriteStatus)):(id)NSNull.null,@"read_hits":@(atomic_load(&hits)),@"read_misses":@(atomic_load(&misses)),@"protection":@"device-only Keychain; installation and native storage namespace scoped",@"key_bytes_logged":@NO};}
#ifdef SAP_VAULT_TESTING
void SAPVaultSetBackendForTesting(BOOL (^write)(NSString *,NSData *),NSData *(^read)(NSString *)){initialize();dispatch_sync(queue,^{testWrite=[write copy];testRead=[read copy];});}
void SAPVaultDrainForTesting(void){initialize();dispatch_sync(queue,^{});}
void SAPVaultResetMemoryForTesting(void){initialize();dispatch_sync(queue,^{[pending removeAllObjects];[namespaces removeAllObjects];[saved removeAllObjects];});}
#endif
