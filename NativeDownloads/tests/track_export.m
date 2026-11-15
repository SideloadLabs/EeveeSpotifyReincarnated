#import <Foundation/Foundation.h>
#import "../src/Generated/CacheStorageLayout.h"
#import "../src/Generated/ExportSites.h"
NSString *SAPExportTestHome;
#define SAP_EXPORT_TESTING 1
#import "../src/Export/TrackExport.m"
#import "../src/Export/ExportKeyStore.m"
#import "../src/Export/TrackCacheExport.m"
NSDictionary *SAPExportObservationReport(void){return @{@"test_fixture":@YES};}
static BOOL traceActive;
static NSMutableArray *traceEvents;
BOOL SAPTraceIsActive(void){return traceActive;}
SAPTraceID SAPTraceCurrentOperation(void){return 0;}
static uint64_t testGeneration=1;
uint64_t SAPTraceGeneration(void){return testGeneration;}
void SAPTraceEvent(const char *category,const char *stage,SAPTraceID op,NSDictionary *facts){NSCAssert(traceActive,@"diagnostics emitted while disabled");[traceEvents addObject:@{@"category":@(category),@"stage":@(stage),@"facts":facts}];}
void SAPTraceEventAtGeneration(const char *category,const char *stage,SAPTraceID op,NSDictionary *facts,uint64_t generation){if(traceActive&&generation==SAPTraceGeneration())SAPTraceEvent(category,stage,op,facts);}
dispatch_block_t SAPLoadExportArtwork(NSString *uri,void (^completion)(NSDictionary *)){dispatch_async(dispatch_get_main_queue(),^{completion(nil);});return ^{};}
NSDictionary *SAPCurrentExportTrack(void){return @{};}
void SAPFetchExportAlbumMetadata(NSString *uri,void (^completion)(NSDictionary *,NSString *)){completion(nil,@"fixture");}
void SAPInvokeServiceOnce(NSString *service,NSString *method,NSData *payload,void (^reply)(NSData *,NSString *,SAPCommandInvocationDisposition)){reply(nil,@"fixture",SAPCommandNotInvoked);}
#ifndef SAP_EXPORT_WORKFLOW_TEST
void SAPCallReadOnlyService(NSString *service,NSString *method,NSData *payload,void (^completion)(NSData *,NSString *)){completion(nil,@"fixture");}
void SAPCallOfflineCommandOnce(NSString *method,NSData *payload,void (^completion)(NSData *,NSString *)){completion(nil,@"fixture");}
void SAPPrepareNativeOffline(BOOL (^requested)(void),void (^completion)(BOOL,NSString *)){completion(NO,@"fixture");}
#endif
void SAPMakeEntityAvailableOffline(NSString *uri,NSArray<NSString *> *tracks,void (^reply)(BOOL,NSString *)) {
    SAPCallOfflineCommandOnce(@"AddDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        reply(data && SAPProtoNumber(SAPProtoFields(data),1,0)==0,error);
    });
}
void SAPResetEntityOffline(NSString *uri,void (^reply)(BOOL,NSString *)){reply(YES,nil);}
static int keepTwoBlocks(void *value){NSUInteger *polls=value;return (*polls)++<2;}
static NSData *fixture(void){return [NSData dataWithContentsOfFile:[NSString stringWithUTF8String:getenv("SAP_OGG_FIXTURE")]];}
static NSString *cachePath(NSData *id,NSString *root){NSString *s=hex(id);return [[SAPExportTestHome stringByAppendingPathComponent:root] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[s substringToIndex:2],s]];}
static void store(NSString *path,NSData *data){[NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];NSCAssert([data writeToFile:path atomically:YES],@"fixture write");}
#ifndef SAP_EXPORT_WORKFLOW_TEST
int main(void){@autoreleasepool {
    SAPExportTestHome=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSMutableDictionary *protectedDisk=[NSMutableDictionary dictionary];
    SAPVaultSetBackendForTesting(^BOOL(NSString *name,NSData *value){protectedDisk[name]=value;return YES;},^NSData *(NSString *name){return protectedDisk[name];});

    NSURL *folder=[NSURL fileURLWithPath:[SAPExportTestHome stringByAppendingPathComponent:@"out"]];[NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:nil];
    uint8_t file[20]={1},key[16]={2};NSData *identifier=[NSData dataWithBytes:file length:20];
    uint8_t descriptor[24]={0},owner[SAPExportOwnerDescriptorOffset+8];memset(owner,0,sizeof(owner));memcpy(descriptor+4,file,20);uintptr_t p=(uintptr_t)descriptor;memcpy(owner+SAPExportOwnerDescriptorOffset,&p,8);
    uintptr_t wrapper[2]={0,(uintptr_t)owner},functor[1]={(uintptr_t)wrapper},storage=(uintptr_t)functor;uint64_t r[20]={0};r[0]=(uintptr_t)&storage;r[1]=(uintptr_t)key;
    SAPExportObserveOfflineSuccess(r,0);
    uint8_t streamCapture[28]={0};memcpy(streamCapture+8,file,20);uintptr_t streamStorage=(uintptr_t)streamCapture;r[0]=(uintptr_t)&streamStorage;
    SAPExportObserveStreamSuccess(r,0);NSCAssert([SAPTrackExportReport()[@"stream_key_callbacks_stored"]unsignedLongLongValue]==1,@"stream success not captured");
    uint8_t copied[16];NSCAssert(SAPExportKeyStoreCopyKey(identifier,copied)&&!memcmp(copied,key,16),@"native success association");
    uint8_t blob[28];for(unsigned i=0;i<sizeof(blob);i++)blob[i]=(uint8_t)(0x60+i);
    uint64_t blobFrame[20]={1,(uintptr_t)file,(uintptr_t)blob};SAPExportObserveMediaKeyBlob(blobFrame,0x100000000);
    uint8_t copiedBlob[28];NSCAssert(SAPExportKeyStoreCopyBlob(identifier,copiedBlob)&&!memcmp(copiedBlob,blob,28),@"media key blob association");
    NSCAssert([SAPTrackExportReport()[@"media_key_blobs_stored"]unsignedLongLongValue]==1,@"blob counter");
    // The protected 28-byte value and later success callbacks must not replace
    // the actual native unsealing result for this file identifier.
    SAPExportRegisterFrame unsealFrame={0};
    uintptr_t nativeSavedFrame[4]={(uintptr_t)file,0,0,0x100000000ULL+SAPExportUnsealCallerReturnOffset};
    unsealFrame.x[29]=(uintptr_t)&nativeSavedFrame[2];
    memcpy(unsealFrame.q[0],key,16);
    uint8_t protectedCandidate[16];memset(protectedCandidate,0xa7,16);
    storeKey(file,protectedCandidate);
    SAPExportObserveUnsealedMediaKey(&unsealFrame,0x100000000);
    NSCAssert(SAPExportKeyStoreCopyKey(identifier,copied)&&!memcmp(copied,key,16),@"unsealed key/file association failed");
    storeKey(file,protectedCandidate);
    NSCAssert(SAPExportKeyStoreCopyKey(identifier,copied)&&!memcmp(copied,key,16),@"protected callback overwrote unsealed key");
    memcpy(unsealFrame.q[0],protectedCandidate,16);nativeSavedFrame[3]++;
    SAPExportObserveUnsealedMediaKey(&unsealFrame,0x100000000);
    unsealFrame.x[29]=1;SAPExportObserveUnsealedMediaKey(&unsealFrame,0x100000000);
    NSCAssert(SAPExportKeyStoreCopyKey(identifier,copied)&&!memcmp(copied,key,16),@"invalid caller/frame replaced key");
    NSCAssert([SAPTrackExportReport()[@"native_unsealed_keys_observed"]unsignedIntValue]==1,@"unseal count");
    NSCAssert([SAPTrackExportReport()[@"native_unsealed_scope_rejections"]unsignedIntValue]==2,@"scope rejection count");
    // Discovery observes scalar shapes even with an unreadable key pointer.
    // It emits once per caller, is bounded, resets with diagnostics, and is off
    // entirely while Diagnostics is disabled.
    uint8_t key24[24];for(unsigned i=0;i<sizeof(key24);i++)key24[i]=(uint8_t)(0x30+i);
    uint64_t key24Frame[31]={0};key24Frame[1]=(uintptr_t)key24;key24Frame[2]=24;key24Frame[30]=0x100000000ULL+SAPExportMediaContextOffset;
    SAPObserveCacheStorageKey(key24Frame,0x100000000);
    uint8_t recentKey[24],recentContext[64],recentLength[1];NSCAssert(SAPCopyRecentMediaKeys24(recentKey,recentContext,recentLength,1)==1&&!memcmp(recentKey,key24,24),@"24-byte media key capture");
    uint64_t cipherFrame[31]={0};cipherFrame[1]=1;cipherFrame[2]=16;cipherFrame[30]=0x2000;
    traceEvents=[NSMutableArray array];traceActive=NO;
    SAPObserveCacheStorageKey(cipherFrame,0x1000);NSCAssert(!traceEvents.count,@"cipher diagnostics ran while disabled");
    traceActive=YES;SAPObserveCacheStorageKey(cipherFrame,0x1000);SAPObserveCacheStorageKey(cipherFrame,0x1000);
    NSCAssert(traceEvents.count==1,@"cipher caller was not deduplicated");
    NSDictionary *cipherFacts=traceEvents[0][@"facts"];
    NSCAssert(![cipherFacts[@"key_bytes_read"]boolValue]&&![cipherFacts[@"track_association_proven"]boolValue],@"cipher observation overstated evidence");
    for(unsigned i=0;i<40;i++){cipherFrame[30]=0x3000+i*4;SAPObserveCacheStorageKey(cipherFrame,0x1000);}
    NSCAssert(traceEvents.count==32,@"cipher caller observations were not bounded");
    testGeneration++;cipherFrame[30]=0x2000;SAPObserveCacheStorageKey(cipherFrame,0x1000);
    NSCAssert(traceEvents.count==33,@"new diagnostic generation did not refresh coverage");
    traceActive=NO;traceEvents=nil;
    NSData *plain=fixture();NSCAssert(plain.length>0,@"fixture missing");
    uint8_t cacheOwner[SAPExportCacheNamespaceOffset+20];memset(cacheOwner,0,sizeof(cacheOwner));uint8_t cacheDescriptor[24]={0};memcpy(cacheDescriptor,file,20);cacheDescriptor[20]=7;cacheDescriptor[22]=0x34;cacheDescriptor[23]=0x12;
    uint8_t *image=calloc(1,SAPExportCacheKeyBodyOffset+0x100);const uint8_t *mapGuard=SAPExportCacheKeyBody;memcpy(image+SAPExportCacheKeyBodyOffset,mapGuard,sizeof(SAPExportCacheKeyBody));
    uint64_t cacheFrame[2]={(uintptr_t)cacheOwner,(uintptr_t)cacheDescriptor};SAPNativeCacheObserve(cacheFrame,(uintptr_t)image);free(image);
    NSString *digest=SAPNativeCacheCandidates(identifier)[0][@"cache_id_hex"];
    NSString *path=[[SAPExportTestHome stringByAppendingPathComponent:@"Library/Caches/VolatileCache"]stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[digest substringToIndex:2],digest]];NSString *source=[SAPExportTestHome stringByAppendingPathComponent:@"plain"],*encrypted=[SAPExportTestHome stringByAppendingPathComponent:@"cipher"];store(source,plain);
    FILE *in=fopen(source.fileSystemRepresentation,"rb"),*out=fopen(encrypted.fileSystemRepresentation,"wb");NSCAssert(transform(in,out,key),@"encrypt");fclose(in);fclose(out);NSData *cipher=[NSData dataWithContentsOfFile:encrypted];store(path,cipher);
    NSDictionary *track=@{@"uri":@"spotify:track:0123456789012345678901",@"files":@[identifier],@"duration_ms":@10000,@"name":@"Test / track"};NSURL *result=nil;NSString *error=nil;
    // Review regression: cancelled workers stop within bounded I/O chunks.
    FILE *large=tmpfile(),*partial=tmpfile();NSMutableData *largeBytes=[NSMutableData dataWithLength:1024*1024];
    NSCAssert(large && partial,@"tmpfile");fwrite(largeBytes.bytes,1,largeBytes.length,large);rewind(large);
    __block NSUInteger copyChecks=0;
    NSCAssert(!transformCancellable(large,partial,NULL,^BOOL{return copyChecks++>=2;}),@"copy ignored cancellation");
    NSCAssert(ftello(partial)<(off_t)largeBytes.length,@"cancelled copy processed entire input");
    rewind(large);fclose(partial);partial=tmpfile();NSCAssert(partial,@"tmpfile");SAPMediaVariant cancelVariant={.keyLength=16};NSUInteger decryptChecks=0;
    NSCAssert(!SAPMediaDecryptFileCancellable(large,partial,&cancelVariant,keepTwoBlocks,&decryptChecks),@"decrypt ignored cancellation");
    NSCAssert(ftello(partial)<(off_t)largeBytes.length,@"cancelled decrypt processed entire input");fclose(large);fclose(partial);
    __block NSUInteger workerChecks=0;NSURL *cancelledResult=nil;NSString *cancelledError=nil;
    NSCAssert(!SAPExportTrackFromCache(track,folder,99,&cancelledResult,&cancelledError,NULL,^BOOL{return workerChecks++>=2;}),@"worker ignored cancellation");
    NSCAssert(!cancelledResult && [cancelledError containsString:@"cancelled"],@"cancelled worker reported cache/key failure");
    __block BOOL midWorkerCancelled=NO;NSString *midWorkerError=nil;NSDictionary *midWorkerEvidence=nil;
    NSURL *midWorkerResult=nil;NSString *workingPath=[folder URLByAppendingPathComponent:@".working"].path;
    NSCAssert(!SAPExportTrackFromCache(track,folder,100,&midWorkerResult,&midWorkerError,&midWorkerEvidence,^BOOL{
        midWorkerCancelled=midWorkerCancelled || [[NSFileManager.defaultManager attributesOfItemAtPath:workingPath error:nil][NSFileSize]unsignedLongLongValue]>0;
        return midWorkerCancelled;
    }),@"mid-candidate cancellation was ignored");
    NSCAssert(midWorkerCancelled && !midWorkerResult && !midWorkerEvidence && [midWorkerError containsString:@"cancelled"],@"mid-candidate cancel became missing key/cache failure");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:workingPath],@"mid-candidate cancel left working scratch");
    NSCAssert([[NSData dataWithContentsOfFile:path]isEqual:cipher],@"cancel changed Spotify cache");
    NSCAssert(exportTrack(track,folder,1,&result,&error,NULL),@"encrypted volatile export: %@",error);
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:[plain subdataWithRange:NSMakeRange(167,plain.length-167)]],@"payload changed");NSCAssert([[NSData dataWithContentsOfFile:path]isEqual:cipher],@"cache changed");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:cachePath(identifier,@"Library/Caches/VolatileCache")],@"hashed path test accidentally used raw ID");
    NSData *originalExport=[NSData dataWithContentsOfURL:result];
    NSCAssert(!embedExportArtwork(result,track),@"missing artwork should keep valid audio");
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:originalExport],@"missing art changed audio");
    const uint8_t jpegBytes[]={0xff,0xd8,0xff,0xd9};
    NSMutableDictionary *withArt=[track mutableCopy];withArt[@"export_artwork"]=@{@"jpeg":[NSData dataWithBytes:jpegBytes length:4],@"width":@640,@"height":@640};
    NSCAssert(!SAPExportEmbedArtwork(result,withArt,@"m4a",YES,nil),@"intermediate Ogg must not embed JPEG before M4A");
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:originalExport],@"deferred M4A unnecessarily rewrote Ogg");
    FILE *validation=fopen(result.path.fileSystemRepresentation,"rb");NSUInteger validationChecks=0;uint64_t validationOffset=0,validationLength=0;SAPOggExportDiagnostics cancelledValidation={0};
    NSCAssert(!SAPValidateOggExportDetailedCancellable(validation,10000,&validationOffset,&validationLength,&cancelledValidation,keepTwoBlocks,&validationChecks),@"validator ignored cancellation");
    NSCAssert(cancelledValidation.status==SAPOggExportInspectionCancelled,@"validator hid cancellation");fclose(validation);
    NSCAssert(embedExportArtwork(result,withArt),@"production artwork replacement failed");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:[result.path stringByAppendingString:@".artwork-tmp"]],@"artwork scratch file leaked");
    FILE *tagged=fopen(result.path.fileSystemRepresentation,"rb");uint64_t taggedAt=0,taggedLength=0;
    NSCAssert(SAPValidateOggExport(tagged,10000,&taggedAt,&taggedLength)&&taggedAt==0,@"tagged output invalid");fclose(tagged);
    NSData *taggedAudio=[NSData dataWithContentsOfURL:result];withArt[@"export_artwork"]=@{@"jpeg":[NSData dataWithBytes:"bad" length:3],@"width":@640,@"height":@640};
    NSCAssert(!embedExportArtwork(result,withArt),@"invalid art accepted");
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:taggedAudio],@"invalid art destroyed export");

    [NSFileManager.defaultManager removeItemAtPath:path error:nil];NSString *persistent=cachePath(identifier,@"Library/Application Support/PersistentCache/Storage");store(persistent,plain);
    NSCAssert(exportTrack(track,folder,2,&result,&error,NULL),@"plaintext persistent export");
    traceActive=YES;traceEvents=[NSMutableArray array];
    NSCAssert(exportTrack(track,folder,4,&result,&error,NULL),@"export with diagnostic details");
    BOOL sawDetails=NO;
    for(NSDictionary *event in traceEvents)if([event[@"stage"]isEqual:@"cache_candidate_validated"]&&[event[@"facts"][@"complete_ogg_validated"]boolValue]){
        NSDictionary *facts=event[@"facts"];sawDetails=YES;
        NSCAssert([facts[@"validation_status"]isEqual:@"ok"]&&[facts[@"pages_validated"]unsignedLongLongValue]>0,@"missing validation evidence");
        NSCAssert([facts[@"stream_offset"]unsignedLongLongValue]==167&&[facts[@"input_bytes"]unsignedLongLongValue]==plain.length,@"incorrect validation size/offset");
        NSCAssert(![facts[@"key_in_log"]boolValue]&&!facts[@"key_bytes"],@"key material in validation report");
    }
    NSCAssert(sawDetails,@"no successful detailed validation event");[traceEvents removeAllObjects];
    NSMutableData *aligned=[plain mutableCopy];NSUInteger padding=(4-plain.length%4)%4;
    NSCAssert(padding>0,@"fixture must exercise nonempty alignment");[aligned increaseLengthBy:padding];store(persistent,aligned);
    NSCAssert(exportTrack(track,folder,5,&result,&error,NULL),@"zero-aligned payload rejected: %@",error);
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:[plain subdataWithRange:NSMakeRange(167,plain.length-167)]],@"alignment leaked into exported audio");
    NSCAssert([[NSData dataWithContentsOfFile:persistent]isEqual:aligned],@"aligned source cache was changed");[traceEvents removeAllObjects];
    store(persistent,[plain subdataWithRange:NSMakeRange(0,plain.length-1)]);NSCAssert(!exportTrack(track,folder,3,&result,&error,NULL),@"truncated accepted");
    BOOL sawRejection=NO;for(NSDictionary *event in traceEvents)if([event[@"stage"]isEqual:@"cache_candidate_validated"]&&[event[@"facts"][@"validation_status"]isEqual:@"truncated_page_body"])sawRejection=YES;
    NSCAssert(sawRejection,@"truncated export reason missing");traceActive=NO;traceEvents=nil;
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:[[folder URLByAppendingPathComponent:@"003 - Test _ track.ogg"]path]],@"partial output retained");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:[[folder URLByAppendingPathComponent:@".working"]path]],@"scratch retained");
    NSCAssert([safeName([@"😀" stringByPaddingToLength:500 withString:@"😀" startingAtIndex:0]) lengthOfBytesUsingEncoding:NSUTF8StringEncoding]<=180,@"filename too long");
    // A complete plaintext payload must export without prompting for a key refresh.
    store(persistent,plain);memset(keys,0,sizeof(keys));
    __block BOOL replied=NO,askedForRefresh=NO;
    SAPExportJob *job=[SAPExportJob new];job.name=@"Plain fixture";job.resolved=[@[track] mutableCopy];
    job.confirmRefresh=^(NSUInteger count,void (^decide)(BOOL)){askedForRefresh=YES;decide(NO);};
    job.completion=^(NSArray *files,NSString *error){NSCAssert(files.count==1&&!error,@"plain cache job rejected: %@",error);replied=YES;};
    [job beginWrite];
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!replied && limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    NSCAssert(replied&&!askedForRefresh,@"plaintext export unnecessarily requested a new key");
    replied=NO;SAPExportJob *m4aJob=[SAPExportJob new];m4aJob.name=@"M4A fixture";m4aJob.format=@"m4a";m4aJob.resolved=[@[track]mutableCopy];
    m4aJob.completion=^(NSArray *files,NSString *error){NSCAssert(files.count==1&&!error,@"M4A job failed: %@",error);NSCAssert([files[0]pathExtension]&&[[files[0]pathExtension]isEqual:@"m4a"],@"wrong format");NSCAssert(SAPExportValidExistingAudio(files[0],track,@"m4a",nil),@"M4A reuse validation failed");replied=YES;};
    [m4aJob beginWrite];limit=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!replied&&limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    NSCAssert(replied,@"M4A job timed out");

    // Sharing uses validated cached audio without publication or native requests.
    __block NSArray *shared=nil;__block BOOL sharedDone=NO;
    NSMutableDictionary *shareTrack=[track mutableCopy];shareTrack[@"uri"]=@"spotify:track:0123456789012345678909";
    SAPExportJob *shareJob=[SAPExportJob new];shareJob.shareOnly=YES;shareJob.format=@"m4a";shareJob.resolved=[@[shareTrack]mutableCopy];
    shareJob.completion=^(NSArray *files,NSString *error){NSCAssert(files.count==1&&!error,@"temporary share failed: %@",error);shared=files;sharedDone=YES;};
    [shareJob beginWrite];limit=[NSDate dateWithTimeIntervalSinceNow:5];
    while(!sharedDone&&limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.005]];
    NSCAssert(sharedDone&&!shareJob.commandRequested,@"cache-only sharing requested a download");
    NSCAssert(!SAPExportLibraryExisting(exportLibraryRoot(),shareTrack,@"m4a"),@"sharing permanently published a file");
    NSCAssert([NSFileManager.defaultManager fileExistsAtPath:[shared[0]path]],@"temporary audio removed before consumption");
    shared=nil;

    storeKey(file,key);
    // Match an independently generated two-layer encrypted native cache fixture.
    const uint8_t namespaceBytes[]={0xed,0x2a,0x9b,0x1f,0x0c,0x6d,0xc8,0xd0,0x91,0x4d,0x7e,0x23,0xb0,0x6b,0x92,0x33,0x59,0xa4,0x47,0x4a};
    memcpy(cacheOwner+SAPExportCacheNamespaceOffset,namespaceBytes,20);cacheDescriptor[20]=0;
    image=calloc(1,SAPCacheStorageOwnerOffset+0x200);NSCAssert(image,@"test image allocation");
    memcpy(image+SAPExportCacheKeyBodyOffset,mapGuard,sizeof(SAPExportCacheKeyBody));
    memcpy(image+SAPCacheStorageOwnerOffset,SAPCacheStorageOwnerCode,sizeof(SAPCacheStorageOwnerCode));
    uint8_t storageSource[20];for(unsigned i=0;i<20;i++)storageSource[i]=(uint8_t)(i+1);
    uint64_t storageFrame[31]={0};storageFrame[1]=(uintptr_t)storageSource;storageFrame[2]=16;
    storageFrame[30]=(uintptr_t)image+SAPCacheStorageOwnerReturnA;SAPObserveCacheStorageKey(storageFrame,(uintptr_t)image);
    SAPNativeCacheObserve(cacheFrame,(uintptr_t)image);free(image);
    NSDictionary *wrappedCandidate=[SAPNativeCacheCandidates(identifier)lastObject];
    NSString *wrappedDigest=wrappedCandidate[@"cache_id_hex"];
    NSString *wrappedPath=[[SAPExportTestHome stringByAppendingPathComponent:@"Library/Caches/VolatileCache"]stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[wrappedDigest substringToIndex:2],wrappedDigest]];
    NSData *wrapped=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:getenv("SAP_NATIVE_CACHE_FIXTURE")]];
    [NSFileManager.defaultManager removeItemAtPath:persistent error:nil];[NSFileManager.defaultManager removeItemAtPath:path error:nil];
    NSCAssert(wrapped.length>0,@"native cache fixture missing");store(wrappedPath,wrapped);
    FILE *envelopeInput=fopen(wrappedPath.fileSystemRepresentation,"rb"),*envelopeOutput=tmpfile();NSUInteger envelopeChecks=0;SAPCacheEnvelopeDetails cancelledEnvelope={0};
    NSCAssert(!SAPExtractCacheEnvelopeCancellable(envelopeInput,envelopeOutput,storageSource,cacheDescriptor,&cancelledEnvelope,keepTwoBlocks,&envelopeChecks),@"cache envelope ignored cancellation");
    NSCAssert(cancelledEnvelope.status && !strcmp(cancelledEnvelope.status,"cancelled"),@"cache cancellation misreported as corrupt data");fclose(envelopeInput);fclose(envelopeOutput);
    NSCAssert(exportTrack(track,folder,5,&result,&error,NULL),@"native cache envelope export failed: %@",error);
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:[plain subdataWithRange:NSMakeRange(167,plain.length-167)]],@"decoded audio changed");
    NSCAssert([[NSData dataWithContentsOfFile:wrappedPath]isEqual:wrapped],@"native cache was changed");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:[[folder URLByAppendingPathComponent:@".cache-payload"]path]],@"container scratch retained");
    SAPVaultDrainForTesting();
    memset(keys,0,sizeof(keys));memset(keyBlobs,0,sizeof(keyBlobs));SAPNativeCacheMapResetForTesting();SAPCacheStorageResetForTesting();SAPVaultResetMemoryForTesting();
    NSCAssert(exportTrack(track,folder,6,&result,&error,NULL),@"cold cache/key restore failed: %@",error);
    NSCAssert([SAPExportKeyVaultReport()[@"read_hits"]unsignedLongLongValue]>=2,@"cold fixture did not restore media and storage keys");
    NSCAssert([[NSData dataWithContentsOfURL:result]isEqual:[plain subdataWithRange:NSMakeRange(167,plain.length-167)]],@"cold restored audio changed");

    [NSFileManager.defaultManager removeItemAtPath:SAPExportTestHome error:nil];puts("PASS encrypted/plaintext exports; original cache unchanged; truncation rejected; scratch cleanup; filename bounds; diagnostics off/on with exact reasons");
}return 0;}

#endif
