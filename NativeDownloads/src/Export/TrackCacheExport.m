#import "TrackCacheExport.h"
#import "ExportKeyVault.h"
#import "ExportKeyStore.h"
#import "NativeCacheMap.h"
#import "CacheEnvelope.h"
#import "CacheStorageKey.h"
#import "MediaDecode.h"
#import "OggExport.h"
#import "OggArtwork.h"
#import "OggValidationTrace.h"
#import "DiagnosticTrace.h"
#import <AVFoundation/AVFoundation.h>
#import <CommonCrypto/CommonCryptor.h>
#ifdef SAP_EXPORT_TESTING
extern NSString *SAPExportTestHome;
#define NSHomeDirectory() SAPExportTestHome
#endif
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

// One track: native cache file -> storage envelope -> media layer -> complete,
// validated Ogg in the export folder. Also file-level helpers the export job
// needs for reuse, artwork and share metadata. No queues, state or UI here.
static NSString *statusName(SAPOggExportStatus status){const char *name=SAPOggExportStatusName(status);return name?[NSString stringWithUTF8String:name]:@"unknown";}
static NSString *hex(NSData *data){NSMutableString *s=[NSMutableString string];for(NSUInteger i=0;i<data.length;i++)[s appendFormat:@"%02x",((const uint8_t *)data.bytes)[i]];return s;}
static NSString *safeName(NSString *name) {
    NSCharacterSet *bad=[NSCharacterSet characterSetWithCharactersInString:@"/\\:\n\r\t"];NSString *result=[[name componentsSeparatedByCharactersInSet:bad] componentsJoinedByString:@"_"];
    result=[result stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(result.length>100)result=[result substringToIndex:[result rangeOfComposedCharacterSequencesForRange:NSMakeRange(0,100)].length];
    while([result lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>180){NSRange last=[result rangeOfComposedCharacterSequenceAtIndex:result.length-1];result=[result substringToIndex:last.location];}
    return result.length&&![result isEqual:@"."]&&![result isEqual:@".."]?result:@"Track";
}
#ifndef SAP_RESEARCH_DUMP
#define SAP_RESEARCH_DUMP 0
#endif
#if SAP_RESEARCH_DUMP
// Research-only artifact. Writes the storage-decoded media payload and the
// opaque 28-byte key record to the guest app's Documents so it can be pulled
// locally. This code is compiled out of normal builds.
static void researchDump(FILE *payload,NSString *fileID,NSString *cacheID,unsigned kind,unsigned index,
                         const uint8_t *blob,BOOL haveBlob,const uint8_t *callback,BOOL haveCallback,
                         uint64_t expected,size_t candidates,NSUInteger previewHits) {
    if(!payload||!fileID.length||!cacheID.length)return;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *root=[[NSURL fileURLWithPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] isDirectory:YES] URLByAppendingPathComponent:@"Pixie Research" isDirectory:YES];
    if(![fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil])return;
    NSString *base=[NSString stringWithFormat:@"%@-%@",fileID,cacheID];
    NSURL *payloadURL=[root URLByAppendingPathComponent:[base stringByAppendingString:@".payload"]];
    FILE *out=fopen(payloadURL.path.fileSystemRepresentation,"wb");
    if(out){if(fseeko(payload,0,SEEK_SET)){}uint8_t buffer[65536];size_t n;while((n=fread(buffer,1,sizeof(buffer),payload)))if(fwrite(buffer,1,n,out)!=n)break;fclose(out);}
    NSMutableData *keys=[NSMutableData data];uint8_t flags=(haveBlob?1:0)|(haveCallback?2:0);[keys appendBytes:&flags length:1];
    if(haveBlob)[keys appendBytes:blob length:28];if(haveCallback)[keys appendBytes:callback length:16];
    [keys writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".keys"]] atomically:YES];
    uint8_t recentKeys[4*24]={0},recentContexts[4*64]={0},recentLengths[4]={0};
    NSUInteger recentCount=SAPCopyRecentMediaKeys24(recentKeys,recentContexts,recentLengths,4);
    NSMutableData *keys24=[NSMutableData data];uint8_t count=(uint8_t)recentCount;[keys24 appendBytes:&count length:1];
    for(NSUInteger i=0;i<recentCount;i++){[keys24 appendBytes:recentKeys+i*24 length:24];[keys24 appendBytes:&recentLengths[i] length:1];[keys24 appendBytes:recentContexts+i*64 length:64];}
    [keys24 writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".keys24"]] atomically:YES];
    uint8_t mediaOutputs[4*32]={0},mediaOutputLengths[4]={0};
    NSUInteger mediaOutputCount=SAPCopyRecentMediaOutputs(mediaOutputs,mediaOutputLengths,4);
    NSMutableData *outputs=[NSMutableData data];uint8_t outputCount=(uint8_t)mediaOutputCount;[outputs appendBytes:&outputCount length:1];
    for(NSUInteger i=0;i<mediaOutputCount;i++){[outputs appendBytes:&mediaOutputLengths[i] length:1];[outputs appendBytes:mediaOutputs+i*32 length:32];}
    [outputs writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".mediaout"]] atomically:YES];
    memset_s(mediaOutputs,sizeof(mediaOutputs),0,sizeof(mediaOutputs));
    uint8_t mediaRecords[8*56]={0};
    NSUInteger mediaRecordCount=SAPCopyRecentMediaRecords(mediaRecords,8);
    NSMutableData *recordData=[NSMutableData data];uint8_t recordCount=(uint8_t)mediaRecordCount;[recordData appendBytes:&recordCount length:1];
    for(NSUInteger i=0;i<mediaRecordCount;i++)[recordData appendBytes:mediaRecords+i*56 length:56];
    [recordData writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".mediarec"]] atomically:YES];
    memset_s(mediaRecords,sizeof(mediaRecords),0,sizeof(mediaRecords));
    uint8_t aesKeyRecords[16*41]={0};
    NSUInteger aesKeyCount=SAPCopyRecentAesKeys(aesKeyRecords,16);
    NSMutableData *aesKeyData=[NSMutableData data];uint8_t aesKeyByte=(uint8_t)aesKeyCount;[aesKeyData appendBytes:&aesKeyByte length:1];
    for(NSUInteger i=0;i<aesKeyCount;i++)[aesKeyData appendBytes:aesKeyRecords+i*41 length:41];
    [aesKeyData writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".aeskeys"]] atomically:YES];
    memset_s(aesKeyRecords,sizeof(aesKeyRecords),0,sizeof(aesKeyRecords));
    uint8_t ccRecords[16*62]={0};
    NSUInteger ccCount=SAPCopyRecentCCCryptos(ccRecords,16);
    NSMutableData *ccData=[NSMutableData data];uint8_t ccByte=(uint8_t)ccCount;[ccData appendBytes:&ccByte length:1];
    for(NSUInteger i=0;i<ccCount;i++)[ccData appendBytes:ccRecords+i*62 length:62];
    [ccData writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".cccryptos"]] atomically:YES];
    memset_s(ccRecords,sizeof(ccRecords),0,sizeof(ccRecords));
    uint8_t ctrRecords[8*56]={0};
    NSUInteger ctrCount=SAPCopyRecentAesCtrs(ctrRecords,8);
    NSMutableData *ctrData=[NSMutableData data];uint8_t ctrByte=(uint8_t)ctrCount;[ctrData appendBytes:&ctrByte length:1];
    for(NSUInteger i=0;i<ctrCount;i++)[ctrData appendBytes:ctrRecords+i*56 length:56];
    [ctrData writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".aesctr"]] atomically:YES];
    memset_s(ctrRecords,sizeof(ctrRecords),0,sizeof(ctrRecords));
    uint8_t blockRecords[8*338]={0};
    NSUInteger blockCount=SAPCopyRecentAesBlocks(blockRecords,8);
    NSMutableData *blockData=[NSMutableData data];uint8_t blockByte=(uint8_t)blockCount;[blockData appendBytes:&blockByte length:1];
    for(NSUInteger i=0;i<blockCount;i++)[blockData appendBytes:blockRecords+i*338 length:338];
    [blockData writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".aesblock"]] atomically:YES];
    memset_s(blockRecords,sizeof(blockRecords),0,sizeof(blockRecords));
    memset_s(recentKeys,sizeof(recentKeys),0,sizeof(recentKeys));memset_s(recentContexts,sizeof(recentContexts),0,sizeof(recentContexts));
    NSDictionary *meta=@{@"file_identifier":fileID,@"cache_id":cacheID,@"descriptor_kind":@(kind),@"descriptor_index":@(index),
        @"have_blob":@(haveBlob),@"have_callback_key":@(haveCallback),@"expected_duration_ms":@(expected),
        @"candidates":@(candidates),@"preview_hits":@(previewHits),@"created":@(NSDate.date.timeIntervalSince1970)};
    NSData *json=[NSJSONSerialization dataWithJSONObject:meta options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToURL:[root URLByAppendingPathComponent:[base stringByAppendingString:@".json"]] atomically:YES];
}
#endif
static int exportContinue(void *context) {
    BOOL (^cancelled)(void)=(__bridge id)context;
    return !cancelled || !cancelled();
}
static BOOL exportWasCancelled(BOOL (^cancelled)(void),NSString **failure) {
    if(!cancelled || !cancelled())return NO;
    if(failure)*failure=@"Audio export cancelled.";return YES;
}
static BOOL transformCancellable(FILE *input,FILE *output,const uint8_t *key,BOOL (^cancelled)(void)) {
    static const uint8_t iv[]={0x72,0xe0,0x67,0xfb,0xdd,0xcb,0xcf,0x77,0xeb,0xe8,0xbc,0x64,0x3f,0x63,0x0d,0x93};
    CCCryptorRef cipher=NULL;
    if(key&&CCCryptorCreateWithMode(kCCDecrypt,kCCModeCTR,kCCAlgorithmAES,ccNoPadding,iv,key,16,NULL,0,0,kCCModeOptionCTR_BE,&cipher)!=kCCSuccess)return NO;
    uint8_t in[65536],out[65536+16];BOOL ok=YES;size_t n;
    for(;;){if(cancelled&&cancelled()){ok=NO;break;}n=fread(in,1,sizeof(in),input);if(!n)break;size_t written=n;if(cipher){if(CCCryptorUpdate(cipher,in,n,out,sizeof(out),&written)!=kCCSuccess){ok=NO;break;}}else memcpy(out,in,n);
        if(fwrite(out,1,written,output)!=written){ok=NO;break;}}
    if(ferror(input))ok=NO;if(cipher)CCCryptorRelease(cipher);memset_s(in,sizeof(in),0,sizeof(in));memset_s(out,sizeof(out),0,sizeof(out));return ok&&!fflush(output);
}
static BOOL __attribute__((unused)) transform(FILE *input,FILE *output,const uint8_t *key) {return transformCancellable(input,output,key,nil);}
static unsigned long long cachedFileSize(NSString *cacheID) {
    unsigned long long best=0;
    if(cacheID.length!=40)return 0;
    for(NSString *root in @[@"Library/Application Support/PersistentCache/Storage",@"Library/Caches/VolatileCache"]) {
        NSString *path=[[NSHomeDirectory() stringByAppendingPathComponent:root] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[cacheID substringToIndex:2],cacheID]];
        struct stat st;
        if(!stat(path.fileSystemRepresentation,&st)&&S_ISREG(st.st_mode)&&st.st_size>0)best=MAX(best,(unsigned long long)st.st_size);
    }
    return best;
}
// A track can map to a small streaming chunk and to the complete file. Try the
// larger candidate first; a 128 KiB chunk is never a complete export.
static NSArray *orderedCandidates(NSArray *observed,NSString *legacyIdentifier) {
    NSMutableArray *list=[NSMutableArray arrayWithCapacity:observed.count+1];
    for(NSDictionary *candidate in observed) {
        NSMutableDictionary *entry=[candidate mutableCopy];
        entry[@"_cached_size"]=@(cachedFileSize(candidate[@"cache_id_hex"]));
        [list addObject:entry];
    }
    [list addObject:[@{@"cache_id_hex":legacyIdentifier,@"mapping_source":@"legacy_raw_identifier",@"_cached_size":@(cachedFileSize(legacyIdentifier))} mutableCopy]];
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        unsigned long long left=[a[@"_cached_size"]unsignedLongLongValue],right=[b[@"_cached_size"]unsignedLongLongValue];
        if(left==right)return NSOrderedSame;
        return left>right?NSOrderedAscending:NSOrderedDescending;
    }];
    return list;
}
static BOOL writeExportFile(FILE *temporary,NSURL *folder,NSUInteger number,NSString *title,
                            uint64_t start,uint64_t length,NSURL **result,BOOL (^cancelled)(void)) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *name=[NSString stringWithFormat:@"%@.ogg",safeName(title)];
    NSURL *destination=[folder URLByAppendingPathComponent:name];
    FILE *out=fopen(destination.path.fileSystemRepresentation,"wb");
    if(!out)return NO;
    BOOL ok=!fseeko(temporary,(off_t)start,SEEK_SET);uint64_t remaining=length;uint8_t buffer[65536];
    while(ok&&remaining) {
        if(cancelled&&cancelled()){ok=NO;break;}
        size_t count=remaining>sizeof(buffer)?sizeof(buffer):(size_t)remaining;
        ok=fread(buffer,1,count,temporary)==count&&fwrite(buffer,1,count,out)==count;
        if(ok)remaining-=count;
    }
    memset_s(buffer,sizeof(buffer),0,sizeof(buffer));
    if(fclose(out))ok=NO;
    NSDictionary *attributes=[fm attributesOfItemAtPath:destination.path error:nil];
    ok=ok&&[attributes[NSFileSize]unsignedLongLongValue]==length;
    if(!ok){[fm removeItemAtURL:destination error:nil];return NO;}
    [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:destination.path error:nil];
    *result=destination;return YES;
}
BOOL SAPExportValidExistingAudio(NSURL *file,NSDictionary *track,NSString *format,BOOL (^cancelled)(void)) {
    if(cancelled&&cancelled())return NO;
    BOOL valid=NO;
    if([format isEqual:@"m4a"]) {
        AVURLAsset *asset=[AVURLAsset URLAssetWithURL:file options:nil];double seconds=CMTimeGetSeconds(asset.duration);
        valid=asset.playable&&isfinite(seconds)&&fabs(seconds-[track[@"duration_ms"]doubleValue]/1000.0)<1;
    }else {
        FILE *input=fopen(file.path.fileSystemRepresentation,"rb");uint64_t start=0,length=0;
        valid=input&&SAPValidateOggExportDetailedCancellable(input,[track[@"duration_ms"]unsignedLongLongValue],&start,&length,NULL,exportContinue,(__bridge void *)cancelled)&&start==0;if(input)fclose(input);
    }
    return valid;
}
NSDictionary *SAPExportShareMetadata(NSDictionary *track,NSURL *file) {
    NSMutableDictionary *art=[track[@"export_artwork"]mutableCopy]?:[NSMutableDictionary dictionary];
    art[@"album_name"]=track[@"album_name"]?:@"Album";
    art[@"share_filename"]=[NSString stringWithFormat:@"%@.%@",safeName(track[@"name"]),file.pathExtension];
    art[@"track_uri"]=track[@"uri"]?:@"";
    if([track[@"album_skipped"]count])art[@"album_skipped"]=track[@"album_skipped"];
    NSMutableDictionary *encoding=NSMutableDictionary.dictionary;
    for(NSString *key in @[@"uri",@"name",@"artist_name",@"artist_uri",@"album_name",@"album_uri",@"category",@"number",@"disc",@"year"])
        if(track[key])encoding[key]=track[key];
    art[@"encoding_metadata"]=encoding;
    return art;
}
static BOOL embedExportArtworkCancellable(NSURL *url,NSDictionary *track,BOOL (^cancelled)(void)) {
    NSDictionary *art=track[@"export_artwork"];NSData *jpeg=art[@"jpeg"];if(!jpeg.length || (cancelled&&cancelled()))return NO;
    NSURL *temporary=[url URLByAppendingPathExtension:@"artwork-tmp"];
    FILE *source=fopen(url.path.fileSystemRepresentation,"rb"),*output=fopen(temporary.path.fileSystemRepresentation,"w+b");
    uint64_t start=0,length=0;BOOL ok=NO;
    if(source&&output&&SAPValidateOggExportDetailedCancellable(source,[track[@"duration_ms"]unsignedLongLongValue],&start,&length,NULL,exportContinue,(__bridge void *)cancelled)) {
        ok=SAPWriteOggWithArtworkCancellable(source,start,length,output,jpeg.bytes,jpeg.length,[art[@"width"]unsignedIntValue],[art[@"height"]unsignedIntValue],exportContinue,(__bridge void *)cancelled);
        uint64_t taggedStart=0,taggedLength=0;
        ok=ok&&SAPValidateOggExportDetailedCancellable(output,[track[@"duration_ms"]unsignedLongLongValue],&taggedStart,&taggedLength,NULL,exportContinue,(__bridge void *)cancelled)&&taggedStart==0;
    }
    if(source)fclose(source);if(output&&fclose(output))ok=NO;
    if(ok)ok=rename(temporary.path.fileSystemRepresentation,url.path.fileSystemRepresentation)==0;
    if(!ok)[NSFileManager.defaultManager removeItemAtURL:temporary error:nil];
    else [NSFileManager.defaultManager setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:url.path error:nil];
    return ok;
}
static BOOL __attribute__((unused)) embedExportArtwork(NSURL *url,NSDictionary *track) {return embedExportArtworkCancellable(url,track,nil);}
BOOL SAPExportEmbedArtwork(NSURL *url,NSDictionary *track,NSString *format,BOOL deferred,BOOL (^cancelled)(void)) {
    // Intermediate Ogg is decoded next; JPEG is supplied to AAC separately.
    if(deferred && [format isEqual:@"m4a"])return NO;
    return embedExportArtworkCancellable(url,track,cancelled);
}
static BOOL oggPageFields(const uint8_t *bytes,size_t length,size_t *offset,uint32_t *serial,uint32_t *sequence,int *bos,uint64_t *granule) {
    for(size_t i=0;i+27<=length;i++) {
        if(memcmp(bytes+i,"OggS",4)||bytes[i+4])continue;
        unsigned laces=bytes[i+26];
        if(i+27+laces>length)continue;
        if(offset)*offset=i;
        if(serial)*serial=(uint32_t)bytes[i+14]|(uint32_t)bytes[i+15]<<8|(uint32_t)bytes[i+16]<<16|(uint32_t)bytes[i+17]<<24;
        if(sequence)*sequence=(uint32_t)bytes[i+18]|(uint32_t)bytes[i+19]<<8|(uint32_t)bytes[i+20]<<16|(uint32_t)bytes[i+21]<<24;
        if(bos)*bos=(bytes[i+5]&2)!=0;
        if(granule){uint64_t g=0;for(int b=0;b<8;b++)g|=(uint64_t)bytes[i+6+b]<<(8*b);*granule=g;}
        return YES;
    }
    return NO;
}
// Streaming chunks in VolatileCache are stored as plaintext Ogg after the
// storage layer. A complete offline file can stay media-encrypted while these
// chunks are readable. Assemble every observed kind-7 chunk in page-sequence
// order and validate the result; nothing is accepted without a full Ogg check.
static BOOL tryChunkAssembly(NSData *identifier,NSArray *candidates,NSURL *folder,NSUInteger number,
                             NSDictionary *track,NSURL **result,NSString **failure,BOOL (^cancelled)(void)) {
    NSString *idHex=hex(identifier);NSMutableArray *chunks=[NSMutableArray array];
    NSFileManager *fm=NSFileManager.defaultManager;
    for(NSDictionary *candidate in candidates) {
        if(exportWasCancelled(cancelled,failure))return NO;
        if([candidate[@"descriptor_kind"]unsignedIntValue]!=7)continue;
        NSString *cacheID=candidate[@"cache_id_hex"];if(cacheID.length!=40)continue;
        for(NSString *cacheRoot in @[@"Library/Application Support/PersistentCache/Storage",@"Library/Caches/VolatileCache"]) {
            if(exportWasCancelled(cancelled,failure))return NO;
            NSString *path=[[NSHomeDirectory() stringByAppendingPathComponent:cacheRoot] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[cacheID substringToIndex:2],cacheID]];
            int descriptor=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);if(descriptor<0)continue;
            struct stat before;if(fstat(descriptor,&before)||!S_ISREG(before.st_mode)||before.st_size<30||before.st_size>1024LL*1024*1024){close(descriptor);continue;}
            FILE *physical=fdopen(descriptor,"rb");if(!physical){close(descriptor);continue;}
            uint8_t storageKey[16]={0};BOOL haveStorageKey=SAPCopyCacheStorageKey(candidate[@"namespace_id_hex"],storageKey);
        if(!haveStorageKey)haveStorageKey=SAPVaultCopyStorage(candidate[@"namespace_id_hex"],storageKey);
            uint8_t nativeDescriptor[24]={0};memcpy(nativeDescriptor,identifier.bytes,20);
            nativeDescriptor[20]=[candidate[@"descriptor_kind"]unsignedIntValue];
            unsigned index=[candidate[@"index"]unsignedIntValue];nativeDescriptor[22]=(uint8_t)index;nativeDescriptor[23]=(uint8_t)(index>>8);
            NSURL *payloadURL=[folder URLByAppendingPathComponent:[NSString stringWithFormat:@".chunk-%lu",(unsigned long)chunks.count]];
            FILE *payload=fopen(payloadURL.path.fileSystemRepresentation,"w+b");
            SAPCacheEnvelopeDetails envelope={0};
            BOOL decoded=payload&&SAPExtractCacheEnvelopeCancellable(physical,payload,haveStorageKey?storageKey:NULL,nativeDescriptor,&envelope,exportContinue,(__bridge void *)cancelled);
            memset_s(storageKey,sizeof(storageKey),0,sizeof(storageKey));
            fclose(physical);
            if(!decoded){if(payload)fclose(payload);[fm removeItemAtURL:payloadURL error:nil];continue;}
            fflush(payload);
            uint8_t *head=malloc(262144);size_t n=0;
            if(head){rewind(payload);n=fread(head,1,262144,payload);}
            size_t off=0;uint32_t serial=0,seq=0;int bos=0;uint64_t granule=0;
            BOOL page=head&&oggPageFields(head,n,&off,&serial,&seq,&bos,&granule);
            if(head)free(head);
            fclose(payload);
            SAP_TRACE("export","chunk_candidate",0,@{@"file_identifier":idHex,@"cache_id_hex":cacheID,@"cache_root":cacheRoot,
                @"descriptor_kind":@(7),@"descriptor_index":@(index),@"payload_bytes":@(envelope.payload_bytes),
                @"storage_decoded":@YES,@"first_page_offset":page?@(off):NSNull.null,@"first_page_sequence":page?@(seq):NSNull.null,
                @"first_page_serial":page?@(serial):NSNull.null,@"first_page_bos":page?@(bos):NSNull.null,@"key_in_log":@NO});
            if(!page){[fm removeItemAtURL:payloadURL error:nil];continue;}
            [chunks addObject:@{@"index":@(index),@"path":payloadURL.path,@"sequence":@(seq),@"serial":@(serial),
                @"bos":@(bos),@"offset":@(off),@"bytes":@(envelope.payload_bytes)}];
        }
    }
    if(chunks.count<2){for(NSDictionary *c in chunks)[fm removeItemAtURL:[NSURL fileURLWithPath:c[@"path"]] error:nil];return NO;}
    [chunks sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        unsigned long long sa=[a[@"sequence"]unsignedLongLongValue],sb=[b[@"sequence"]unsignedLongLongValue];
        if(sa==sb){unsigned long long ia=[a[@"index"]unsignedLongLongValue],ib=[b[@"index"]unsignedLongLongValue];if(ia==ib)return NSOrderedSame;return ia<ib?NSOrderedAscending:NSOrderedDescending;}
        return sa<sb?NSOrderedAscending:NSOrderedDescending;
    }];
    NSURL *assembled=[folder URLByAppendingPathComponent:@".assembled"];
    FILE *out=fopen(assembled.path.fileSystemRepresentation,"w+b");
    BOOL copied=out!=NULL;uint64_t total=0;
    for(NSUInteger i=0;copied&&i<chunks.count;i++) {
        NSDictionary *chunk=chunks[i];FILE *in=fopen([chunk[@"path"]fileSystemRepresentation],"rb");if(!in){copied=NO;break;}
        uint64_t strip=0;BOOL isBos=[chunk[@"bos"]boolValue];uint64_t offset=[chunk[@"offset"]unsignedLongLongValue];
        if(i==0)strip=isBos?offset:0;
        else if(isBos&&offset<=200)strip=offset; // repeated Spotify prefix on a chunk
        if(strip>=[chunk[@"bytes"]unsignedLongLongValue]){fclose(in);copied=NO;break;}
        if(fseeko(in,(off_t)strip,SEEK_SET)){fclose(in);copied=NO;break;}
        uint8_t buffer[65536];size_t got;while((got=fread(buffer,1,sizeof(buffer),in))>0){if(cancelled&&cancelled()){copied=NO;break;}if(fwrite(buffer,1,got,out)!=got){copied=NO;break;}total+=got;}
        if(ferror(in))copied=NO;fclose(in);
    }
    if(out&&fclose(out))copied=NO;
    uint64_t start=0,length=0;SAPOggExportDiagnostics details={0};
    FILE *assembledFile=copied?fopen(assembled.path.fileSystemRepresentation,"rb"):NULL;
    BOOL valid=assembledFile&&SAPValidateOggExportDetailedCancellable(assembledFile,[track[@"duration_ms"]unsignedLongLongValue],&start,&length,SAPTraceIsActive()?&details:NULL,exportContinue,(__bridge void *)cancelled);
    SAP_TRACE("export","chunk_assembly",0,@{@"file_identifier":idHex,@"chunks":@(chunks.count),@"assembled_bytes":@(total),
        @"copy_completed":@(copied),@"complete_ogg_validated":@(valid),@"validation_status":SAPTraceIsActive()?statusName(details.status):NSNull.null,
        @"stream_offset":details.has_stream_offset?@(details.stream_offset):NSNull.null,@"pages_validated":@(details.pages_validated),
        @"failure_offset":@(details.failure_offset),@"observed_duration_ms":@(details.observed_duration_ms),
        @"expected_duration_ms":track[@"duration_ms"]?:NSNull.null,@"key_in_log":@NO});
    BOOL success=valid&&writeExportFile(assembledFile,folder,number,track[@"name"],start,length,result,cancelled);
    if(assembledFile)fclose(assembledFile);
    for(NSDictionary *c in chunks)[fm removeItemAtURL:[NSURL fileURLWithPath:c[@"path"]] error:nil];
    [fm removeItemAtURL:assembled error:nil];
    if(!success&&!valid)*failure=@"The streamed cache chunks could not be assembled into a complete Ogg track.";
    return success;
}
BOOL SAPExportTrackFromCache(NSDictionary *track,NSURL *folder,NSUInteger number,NSURL **result,NSString **failure,NSDictionary **evidence,BOOL (^cancelled)(void)) {
    if(evidence)*evidence=nil;
    if(exportWasCancelled(cancelled,failure))return NO;
    NSFileManager *fm=NSFileManager.defaultManager;BOOL cacheSeen=NO,keySeen=NO,anyMediaKey=NO;NSUInteger openedCount=0,decodedCount=0,matrixTotal=0,matrixHits=0;NSString *lastID=nil;
    for(NSData *identifier in track[@"files"]) {
        if(exportWasCancelled(cancelled,failure))return NO;
        NSString *idHex=hex(identifier);lastID=idHex;
        NSArray *observed=SAPNativeCacheCandidates(identifier);
        if(tryChunkAssembly(identifier,observed,folder,number,track,result,failure,cancelled))return YES;
        if(exportWasCancelled(cancelled,failure))return NO;
        NSArray *candidates=orderedCandidates(observed,idHex);
        NSUInteger lookupCount=0,openFailureCount=0;NSMutableArray *lookupFailures=SAPTraceIsActive()?[NSMutableArray array]:nil;
        for(NSDictionary *candidate in candidates) {
        if(exportWasCancelled(cancelled,failure))return NO;
        NSString *cacheID=candidate[@"cache_id_hex"];
        if(cacheID.length!=40)continue;
        for(NSString *cacheRoot in @[@"Library/Application Support/PersistentCache/Storage",@"Library/Caches/VolatileCache"]) {
            if(exportWasCancelled(cancelled,failure))return NO;
        NSString *path=[[NSHomeDirectory() stringByAppendingPathComponent:cacheRoot] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[cacheID substringToIndex:2],cacheID]];
        // Reject symlinks, non-regular files and unreasonable sizes before reading.
        int descriptor=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);lookupCount++;
        if(descriptor<0){int saved=errno;openFailureCount++;if(lookupFailures&&lookupFailures.count<32)[lookupFailures addObject:@{@"cache_id_hex":cacheID,@"root":cacheRoot,@"errno":@(saved)}];continue;}struct stat before;
        if(fstat(descriptor,&before)||!S_ISREG(before.st_mode)||before.st_size<30||before.st_size>1024LL*1024*1024){close(descriptor);continue;}cacheSeen=YES;openedCount++;
        SAP_TRACE("export","cache_candidate_opened",0,@{@"file_identifier":idHex,@"cache_root":cacheRoot,@"cache_id_hex":cacheID,@"native_mapping":@(candidate[@"namespace_id_hex"]!=nil),@"descriptor_kind":candidate[@"descriptor_kind"]?:NSNull.null,@"descriptor_index":candidate[@"index"]?:NSNull.null,@"bytes":@(before.st_size)});
        FILE *physical=fdopen(descriptor,"rb");if(!physical){close(descriptor);continue;}
        FILE *input=physical,*payload=NULL;uint8_t key[16]={0},storageKey[16]={0},nativeDescriptor[24]={0};
        BOOL haveKey=SAPExportKeyStoreCopyKey(identifier,key);BOOL nativeUnsealed=haveKey&&SAPExportKeyStoreIsUnsealed(identifier);
        if(!nativeUnsealed&&SAPVaultCopyMedia(identifier,candidate[@"namespace_id_hex"],key)){haveKey=YES;nativeUnsealed=YES;}
        keySeen|=haveKey;
        BOOL haveStorageKey=SAPCopyCacheStorageKey(candidate[@"namespace_id_hex"],storageKey);
        if(!haveStorageKey)haveStorageKey=SAPVaultCopyStorage(candidate[@"namespace_id_hex"],storageKey);
        NSURL *payloadURL=[folder URLByAppendingPathComponent:@".cache-payload"];
        if(candidate[@"namespace_id_hex"] && identifier.length==20) {
            memcpy(nativeDescriptor,identifier.bytes,20);
            nativeDescriptor[20]=[candidate[@"descriptor_kind"]unsignedIntValue];
            unsigned index=[candidate[@"index"]unsignedIntValue];
            nativeDescriptor[22]=(uint8_t)index;nativeDescriptor[23]=(uint8_t)(index>>8);
            payload=fopen(payloadURL.path.fileSystemRepresentation,"w+b");
            SAPCacheEnvelopeDetails envelope={0};
            BOOL decoded=payload && SAPExtractCacheEnvelopeCancellable(physical,payload,haveStorageKey?storageKey:NULL,nativeDescriptor,&envelope,exportContinue,(__bridge void *)cancelled);
            SAP_TRACE("export","cache_storage_envelope",0,@{@"file_identifier":idHex,
                @"cache_id_hex":cacheID,@"storage_context_available":@(haveStorageKey),@"decoded":@(decoded),
                @"status":envelope.status?@(envelope.status):@"scratch_open_failed",
                @"physical_bytes":@(envelope.physical_bytes),@"payload_bytes":@(envelope.payload_bytes),
                @"payload_offset":@(envelope.payload_offset),@"block_count":@(envelope.blocks),
                @"storage_encrypted":@(envelope.encrypted),@"metadata_at_end":@(envelope.metadata_at_end),@"key_in_log":@NO});
            if(decoded){input=payload;decodedCount++;}
            else {if(payload)fclose(payload);payload=NULL;[fm removeItemAtURL:payloadURL error:nil];}
        }
        memset_s(storageKey,sizeof(storageKey),0,sizeof(storageKey));
        NSURL *scratch=[folder URLByAppendingPathComponent:@".working"];BOOL success=NO;
        uint8_t keyBlob[28]={0};BOOL haveKeyBlob=SAPExportKeyStoreCopyBlob(identifier,keyBlob);anyMediaKey|=(haveKey||haveKeyBlob);
        struct stat after;
        BOOL stable=!fstat(descriptor,&after)&&before.st_size==after.st_size&&before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec;
        // A plaintext payload needs no key. This is the cheapest and safest case.
        if(stable) {
            rewind(input);FILE *temporary=fopen(scratch.path.fileSystemRepresentation,"w+b");
            if(temporary) {
                BOOL copied=transformCancellable(input,temporary,NULL,cancelled);uint64_t start=0,length=0;
                BOOL diagnosing=SAPTraceIsActive();uint64_t diagnosticGeneration=diagnosing?SAPTraceGeneration():0;SAPOggExportDiagnostics details={0};
                BOOL valid=copied&&SAPValidateOggExportDetailedCancellable(temporary,[track[@"duration_ms"]unsignedLongLongValue],&start,&length,diagnosing?&details:NULL,exportContinue,(__bridge void *)cancelled);
                if(copied&&diagnosing)SAPTraceOggValidationCancellable(temporary,&details,[track[@"duration_ms"]unsignedLongLongValue],@{@"track_uri":track[@"uri"]?:@"",@"file_identifier":idHex,@"cache_id_hex":cacheID,@"route":@"plaintext",@"source_stable":@(stable)},diagnosticGeneration,exportContinue,(__bridge void *)cancelled);
                SAP_TRACE("export","cache_candidate_validated",0,@{@"file_identifier":idHex,@"cache_root":cacheRoot,@"cache_id_hex":cacheID,
                    @"descriptor_kind":candidate[@"descriptor_kind"]?:NSNull.null,@"descriptor_index":candidate[@"index"]?:NSNull.null,
                    @"key_available":@(haveKey),@"media_variant":@"plaintext",@"decryption_attempted":@NO,@"copy_completed":@(copied),@"source_stable":@(stable),
                    @"complete_ogg_validated":@(valid),@"validation_status":!copied?@"copy_failed":statusName(details.status),
                    @"input_bytes":@(details.input_bytes),@"stream_offset":details.has_stream_offset?@(details.stream_offset):NSNull.null,
                    @"pages_validated":@(details.pages_validated),@"failure_offset":@(details.failure_offset),@"sample_rate":@(details.sample_rate),
                    @"observed_duration_ms":@(details.observed_duration_ms),@"expected_duration_ms":track[@"duration_ms"]?:NSNull.null,@"key_in_log":@NO});
                if(valid)success=writeExportFile(temporary,folder,number,track[@"name"],start,length,result,cancelled);
                fclose(temporary);[fm removeItemAtURL:scratch error:nil];
            }
        }
        // Encrypted media layer. The native key record is opaque, so try a
        // bounded, deduplicated list of key/IV/counter/skip interpretations.
        // Only a full Ogg validation can select one; nothing is guessed into
        // the exported file.
        if(!success&&stable&&(haveKey||haveKeyBlob)&&exportContinue((__bridge void *)cancelled)) {
            SAPMediaVariant *variants=calloc(4096,sizeof(SAPMediaVariant));
            if(!variants){memset_s(keyBlob,sizeof(keyBlob),0,sizeof(keyBlob));if(payload){fclose(payload);[fm removeItemAtURL:payloadURL error:nil];}fclose(physical);memset_s(key,sizeof(key),0,sizeof(key));continue;}
            // Exact native record from the key-setter tail:
            // [20-byte derived value][16-byte per-file key]. Try the two
            // observed layouts before the broader bounded matrix.
            uint8_t records[4*56]={0};NSUInteger recordCount=SAPCopyRecentMediaRecords(records,4);
            for(NSUInteger q=0;q<recordCount&&!success&&!(cancelled&&cancelled());q++) {
                const uint8_t *recordFile=records+q*56,*record=recordFile+20;
                if(identifier.length!=20||memcmp(recordFile,identifier.bytes,20))continue;
                const uint8_t *recordKeys[3]={record+20,record,record+4};const uint8_t recordKeyLengths[3]={16,16,16};
                const char *recordKeyLabels[3]={"record_key","record_first16","record_4"};
                uint8_t recordIVs[2][16];memcpy(recordIVs[0],record,16);memcpy(recordIVs[1],record+4,16);
                const char *recordIVLabels[2]={"record_iv","record_iv4"};
                for(unsigned rk=0;rk<3&&!success&&!(cancelled&&cancelled());rk++)for(unsigned ri=0;ri<2&&!success;ri++)
                for(unsigned endian=0;endian<2&&!success;endian++)for(unsigned sm=0;sm<4&&!success;sm++) {
                    static const uint64_t recordSkips[4]={0,167,0,167};
                    static const uint64_t recordCounters[4]={0,0,167,167};
                    SAPMediaVariant rv={0};memcpy(rv.key,recordKeys[rk],recordKeyLengths[rk]);rv.keyLength=recordKeyLengths[rk];
                    memcpy(rv.iv,recordIVs[ri],16);rv.little_endian=(int)endian;rv.skip=recordSkips[sm];rv.counter=recordCounters[sm];
                    rv.keyLabel=recordKeyLabels[rk];rv.ivLabel=recordIVLabels[ri];
                    if(cancelled&&cancelled())break;
                    if(!SAPMediaPreview(input,&rv,128*1024))continue;
                    rewind(input);FILE *rtmp=fopen(scratch.path.fileSystemRepresentation,"w+b");if(!rtmp)break;
                    BOOL rcopied=SAPMediaDecryptFileCancellable(input,rtmp,&rv,exportContinue,(__bridge void *)cancelled);uint64_t rstart=0,rlength=0;
                    BOOL rdiagnosing=SAPTraceIsActive();uint64_t rgeneration=rdiagnosing?SAPTraceGeneration():0;SAPOggExportDiagnostics rdetails={0};
                    BOOL rvalid=rcopied&&SAPValidateOggExportDetailedCancellable(rtmp,[track[@"duration_ms"]unsignedLongLongValue],&rstart,&rlength,rdiagnosing?&rdetails:NULL,exportContinue,(__bridge void *)cancelled);
                    if(rcopied&&rdiagnosing)SAPTraceOggValidationCancellable(rtmp,&rdetails,[track[@"duration_ms"]unsignedLongLongValue],@{@"track_uri":track[@"uri"]?:@"",@"file_identifier":idHex,@"cache_id_hex":cacheID,@"route":@"cached_media_record",@"skip":@(rv.skip),@"counter":@(rv.counter),@"counter_endian":rv.little_endian?@"little":@"big",@"key_source":@(rv.keyLabel),@"iv_source":@(rv.ivLabel)},rgeneration,exportContinue,(__bridge void *)cancelled);
                    SAP_TRACE("export","media_record_variant_tried",0,@{@"file_identifier":idHex,@"cache_id_hex":cacheID,
                        @"key_source":@(recordKeyLabels[rk]),@"iv_source":@(recordIVLabels[ri]),@"counter_endian":endian?@"little":@"big",
                        @"skip":@(recordSkips[sm]),@"counter":@(recordCounters[sm]),@"copy_completed":@(rcopied),
                        @"complete_ogg_validated":@(rvalid),@"pages_validated":@(rdetails.pages_validated),@"key_in_log":@NO});
                    if(rvalid) {
                        SAP_TRACE("export","cache_candidate_validated",0,@{@"file_identifier":idHex,@"cache_root":cacheRoot,@"cache_id_hex":cacheID,
                            @"descriptor_kind":candidate[@"descriptor_kind"]?:NSNull.null,@"descriptor_index":candidate[@"index"]?:NSNull.null,
                            @"key_available":@YES,@"media_key_source":@(recordKeyLabels[rk]),@"media_iv_source":@(recordIVLabels[ri]),
                            @"decryption_attempted":@YES,@"copy_completed":@YES,@"source_stable":@YES,
                            @"complete_ogg_validated":@YES,@"validation_status":@"ok",@"key_in_log":@NO});
                        success=writeExportFile(rtmp,folder,number,track[@"name"],rstart,rlength,result,cancelled);
                    }
                    fclose(rtmp);[fm removeItemAtURL:scratch error:nil];
                }
            }
            memset_s(records,sizeof(records),0,sizeof(records));
            uint8_t nativeKeys24[4*24]={0},nativeContexts24[4*64]={0},nativeLengths24[4]={0},recentContexts[4*64]={0},recentContextLengths[4]={0};NSUInteger nativeKeyCount=SAPCopyRecentMediaKeys24(nativeKeys24,nativeContexts24,nativeLengths24,4);NSUInteger recentContextCount=SAPCopyRecentMediaContexts(recentContexts,recentContextLengths,4);
            unsigned kind=[candidate[@"descriptor_kind"]unsignedIntValue],index=[candidate[@"index"]unsignedIntValue];
            size_t variantCount=(cancelled&&cancelled())?0:SAPMediaBuildVariants(identifier.bytes,kind,index,haveKey?key:NULL,haveKeyBlob?keyBlob:NULL,nativeKeyCount?nativeKeys24:NULL,nativeKeyCount,recentContextCount?recentContexts:NULL,recentContextLengths,recentContextCount,variants,4096);matrixTotal+=variantCount;
            if(nativeUnsealed)for(size_t i=0;i<variantCount;i++)
                if(!strcmp(variants[i].keyLabel,"callback"))variants[i].keyLabel="native_unsealed";
            memset_s(nativeKeys24,sizeof(nativeKeys24),0,sizeof(nativeKeys24));memset_s(nativeContexts24,sizeof(nativeContexts24),0,sizeof(nativeContexts24));memset_s(recentContexts,sizeof(recentContexts),0,sizeof(recentContexts));
            NSUInteger previewHits=0;
            for(size_t i=0;i<variantCount&&!success;i++) {
                if(cancelled&&cancelled())break;
                    if(!SAPMediaPreview(input,&variants[i],128*1024))continue;
                previewHits++;
                rewind(input);FILE *temporary=fopen(scratch.path.fileSystemRepresentation,"w+b");if(!temporary)break;
                BOOL copied=SAPMediaDecryptFileCancellable(input,temporary,&variants[i],exportContinue,(__bridge void *)cancelled);uint64_t start=0,length=0;
                BOOL diagnosing=SAPTraceIsActive();uint64_t diagnosticGeneration=diagnosing?SAPTraceGeneration():0;SAPOggExportDiagnostics details={0};
                BOOL valid=copied&&SAPValidateOggExportDetailedCancellable(temporary,[track[@"duration_ms"]unsignedLongLongValue],&start,&length,diagnosing?&details:NULL,exportContinue,(__bridge void *)cancelled);
                if(copied&&diagnosing)SAPTraceOggValidationCancellable(temporary,&details,[track[@"duration_ms"]unsignedLongLongValue],@{@"track_uri":track[@"uri"]?:@"",@"file_identifier":idHex,@"cache_id_hex":cacheID,@"route":@"media_variant",@"skip":@(variants[i].skip),@"counter":@(variants[i].counter),@"counter_endian":variants[i].little_endian?@"little":@"big",@"key_source":@(variants[i].keyLabel),@"iv_source":@(variants[i].ivLabel)},diagnosticGeneration,exportContinue,(__bridge void *)cancelled);
                SAP_TRACE("export","media_variant_tried",0,@{@"file_identifier":idHex,@"cache_id_hex":cacheID,
                    @"key_source":@(variants[i].keyLabel),@"iv_source":@(variants[i].ivLabel),@"counter_endian":variants[i].little_endian?@"little":@"big",
                    @"skip":@(variants[i].skip),@"copy_completed":@(copied),@"complete_ogg_validated":@(valid),
                    @"validation_status":!copied?@"copy_failed":statusName(details.status),
                    @"pages_validated":@(details.pages_validated),@"key_in_log":@NO});
                if(valid) {
                    SAP_TRACE("export","cache_candidate_validated",0,@{@"file_identifier":idHex,@"cache_root":cacheRoot,@"cache_id_hex":cacheID,
                        @"descriptor_kind":candidate[@"descriptor_kind"]?:NSNull.null,@"descriptor_index":candidate[@"index"]?:NSNull.null,
                        @"key_available":@YES,@"media_key_source":@(variants[i].keyLabel),@"media_iv_source":@(variants[i].ivLabel),@"decryption_attempted":@YES,@"copy_completed":@YES,@"source_stable":@YES,
                        @"complete_ogg_validated":@YES,@"validation_status":@"ok",
                        @"input_bytes":@(details.input_bytes),@"stream_offset":details.has_stream_offset?@(details.stream_offset):NSNull.null,
                        @"pages_validated":@(details.pages_validated),@"failure_offset":@(details.failure_offset),@"sample_rate":@(details.sample_rate),
                        @"observed_duration_ms":@(details.observed_duration_ms),@"expected_duration_ms":track[@"duration_ms"]?:NSNull.null,@"key_in_log":@NO});
                    success=writeExportFile(temporary,folder,number,track[@"name"],start,length,result,cancelled);
                }
                fclose(temporary);[fm removeItemAtURL:scratch error:nil];
            }
            SAP_TRACE("export","media_decode_matrix",0,@{@"file_identifier":idHex,@"cache_id_hex":cacheID,
                @"candidates":@(variantCount),@"preview_hits":@(previewHits),@"validated":@(success),@"native_keys_24":@(nativeKeyCount),@"native_contexts":@(recentContextCount),@"native_unsealed_key_available":@(nativeUnsealed),@"key_in_log":@NO});
#if SAP_RESEARCH_DUMP
            if(!success)researchDump(input,idHex,cacheID,kind,index,keyBlob,haveKeyBlob,key,haveKey,[track[@"duration_ms"]unsignedLongLongValue],variantCount,previewHits);
#endif
            matrixHits+=previewHits;
            free(variants);
            // The native key-store derivation returns a 32-byte result whose
            // first 16 bytes are the IV. Try it directly with the per-file
            // 28-byte key record before declaring the scheme unknown.
            if(!success && !(cancelled&&cancelled())) {
                uint8_t outputs[4*32]={0},outputLengths[4]={0};
                NSUInteger outputCount=SAPCopyRecentMediaOutputs(outputs,outputLengths,4);
                NSURL *nativeScratch=[folder URLByAppendingPathComponent:@".native-output"];
                for(NSUInteger q=0;q<outputCount&&!success;q++) {
                    if(outputLengths[q]<16)continue;
                    for(unsigned kc=0;kc<5&&!success;kc++) {
                        uint8_t candidateKey[32]={0};uint8_t keyLength=0;const char *keyLabel=NULL;
                        switch(kc) {
                            case 0:if(!haveKey)continue;memcpy(candidateKey,key,16);keyLength=16;keyLabel="callback";break;
                            case 1:memcpy(candidateKey,keyBlob,16);keyLength=16;keyLabel="blob0";break;
                            case 2:memcpy(candidateKey,keyBlob+4,16);keyLength=16;keyLabel="blob4";break;
                            case 3:memcpy(candidateKey,keyBlob+12,16);keyLength=16;keyLabel="blob12";break;
                            default:memcpy(candidateKey,keyBlob,24);keyLength=24;keyLabel="blob24";break;
                        }
                        for(unsigned sk=0;sk<2&&!success;sk++) {
                            uint64_t skip=sk?167:0;
                            SAPMediaVariant variant={0};memcpy(variant.key,candidateKey,keyLength);variant.keyLength=keyLength;
                            memcpy(variant.iv,outputs+q*32,16);variant.little_endian=0;variant.skip=skip;variant.counter=0;
                            variant.keyLabel=keyLabel;variant.ivLabel="native_output";
                            if(cancelled&&cancelled())break;
                    if(!SAPMediaPreview(input,&variant,128*1024))continue;
                            rewind(input);FILE *temporary=fopen(nativeScratch.path.fileSystemRepresentation,"w+b");if(!temporary)break;
                            BOOL copied=SAPMediaDecryptFileCancellable(input,temporary,&variant,exportContinue,(__bridge void *)cancelled);uint64_t start=0,length=0;
                            SAPOggExportDiagnostics details={0};
                            BOOL valid=copied&&SAPValidateOggExportDetailedCancellable(temporary,[track[@"duration_ms"]unsignedLongLongValue],&start,&length,SAPTraceIsActive()?&details:NULL,exportContinue,(__bridge void *)cancelled);
                            SAP_TRACE("export","media_output_variant_tried",0,@{@"file_identifier":idHex,@"cache_id_hex":cacheID,
                                @"key_source":@(keyLabel),@"iv_source":@"native_output",@"iv_fingerprint":@(q),@"skip":@(skip),
                                @"copy_completed":@(copied),@"complete_ogg_validated":@(valid),@"pages_validated":@(details.pages_validated),@"key_in_log":@NO});
                            if(valid) {
                                SAP_TRACE("export","cache_candidate_validated",0,@{@"file_identifier":idHex,@"cache_root":cacheRoot,@"cache_id_hex":cacheID,
                                    @"descriptor_kind":candidate[@"descriptor_kind"]?:NSNull.null,@"descriptor_index":candidate[@"index"]?:NSNull.null,
                                    @"key_available":@YES,@"media_key_source":@(keyLabel),@"media_iv_source":@"native_output",
                                    @"decryption_attempted":@YES,@"copy_completed":@YES,@"source_stable":@YES,
                                    @"complete_ogg_validated":@YES,@"validation_status":@"ok",@"key_in_log":@NO});
                                success=writeExportFile(temporary,folder,number,track[@"name"],start,length,result,cancelled);
                            }
                            fclose(temporary);[fm removeItemAtURL:nativeScratch error:nil];
                        }
                    }
                }
                memset_s(outputs,sizeof(outputs),0,sizeof(outputs));
            }
        }
        memset_s(keyBlob,sizeof(keyBlob),0,sizeof(keyBlob));
        if(payload){fclose(payload);[fm removeItemAtURL:payloadURL error:nil];}
        fclose(physical);memset_s(key,sizeof(key),0,sizeof(key));if(success)return YES;
        }
        }
        SAP_TRACE("export","cache_lookup_summary",0,@{@"file_identifier":idHex,@"observed_native_candidates":@(observed.count),@"lookup_count":@(lookupCount),@"open_failures":lookupFailures?:@[],@"open_failure_count":@(openFailureCount),@"failure_details_truncated":@(openFailureCount>lookupFailures.count)});
    }
    if(exportWasCancelled(cancelled,failure))return NO;
    NSString *stage=!cacheSeen?@"no_cache_file":(!openedCount?@"cache_file_rejected":(!decodedCount?@"storage_decode_failed":(!anyMediaKey?@"no_media_key":(!matrixHits?@"media_scheme_not_recognized":@"audio_validation_failed"))));
    if(evidence)*evidence=@{@"stage":stage,@"cache_seen":@(cacheSeen),@"storage_decoded":@(decodedCount),@"media_key_available":@(anyMediaKey)};
    SAP_TRACE("export","export_failure",0,@{@"file_identifier":lastID?:@"",@"stage":stage,
        @"cache_seen":@(cacheSeen),@"opened":@(openedCount),@"storage_decoded":@(decodedCount),
        @"callback_key":@(keySeen),@"blob_available":@(anyMediaKey&&!keySeen),@"media_key_available":@(anyMediaKey),
        @"matrix_candidates":@(matrixTotal),@"matrix_preview_hits":@(matrixHits),@"key_in_log":@NO});
    if(!cacheSeen)
        *failure=@"No supported cache file was found for this track. Play or download the track once, then retry. Export the support log with Diagnostics for the exact lookup list.";
    else if(!decodedCount)
        *failure=@"The cache file was found but its storage container could not be decoded. Export the support log with Diagnostics enabled.";
    else if(!anyMediaKey)
        *failure=@"The audio is present but no media key or key record was observed in this app session. Play the track for a few seconds, then retry with Diagnostics enabled.";
    else if(!matrixHits)
        *failure=@"The cached audio is encrypted with a media scheme outside the recognised set. Export the support log with Diagnostics enabled; the log names the key/IV candidates tried.";
    else
        *failure=@"The decrypted audio did not pass complete Ogg validation (container, CRC, sequence, EOS or duration). Export the support log with Diagnostics enabled.";
    return NO;
}

static BOOL __attribute__((unused)) exportTrack(NSDictionary *track,NSURL *folder,NSUInteger number,NSURL **result,NSString **failure,NSDictionary **evidence) {return SAPExportTrackFromCache(track,folder,number,result,failure,evidence,nil);}
