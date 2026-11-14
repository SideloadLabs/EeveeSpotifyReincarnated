#import "OfflineLibraryPackage.h"
#import <objc/runtime.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <zlib.h>

static char SAPLibraryLeaseKey;
static NSString *const SAPLibraryPackageDomain=@"SAPOfflineLibraryPackage";

@interface SAPLibraryPackageLease : NSObject
@property(nonatomic,strong) NSURL *root;
@end
@implementation SAPLibraryPackageLease
- (void)dealloc { if(_root) [NSFileManager.defaultManager removeItemAtURL:_root error:NULL]; }
@end

static NSError *SAPPackageError(NSString *message) {
    return [NSError errorWithDomain:SAPLibraryPackageDomain code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL SAPPackageCancelled(NSProgress *progress,NSError *__strong *error) {
    if(!progress.cancelled)return NO;
    if(error)*error=[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:@{NSLocalizedDescriptionKey:@"Library packaging was cancelled."}];
    return YES;
}
static NSString *SAPPackageString(id value,NSString *fallback) {
    return [value isKindOfClass:NSString.class]&&[value length] ? value:fallback;
}
static NSString *SAPPackageShorten(NSString *value,NSUInteger limit) {
    while([value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>limit)
        value=[value substringToIndex:[value rangeOfComposedCharacterSequenceAtIndex:value.length-1].location];
    return value;
}
static NSString *SAPPackageComponent(NSString *value,NSString *fallback) {
    value=[value precomposedStringWithCanonicalMapping];
    NSMutableCharacterSet *unsafe=[NSCharacterSet.controlCharacterSet mutableCopy];
    [unsafe addCharactersInString:@"/\\:"];
    value=[[value componentsSeparatedByCharactersInSet:unsafe]componentsJoinedByString:@"_"];
    value=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // Finder hides dot-leading names; preserve the useful text while avoiding that surprise.
    while([value hasPrefix:@"."])value=[value substringFromIndex:1];
    if(!value.length)value=fallback;
    value=SAPPackageShorten(value,160);
    return value.length?value:fallback;
}
static NSString *SAPPackageUniqueComponent(NSString *base,NSMutableSet<NSString *> *used) {
    NSString *candidate=base;NSUInteger n=2;
    while([used containsObject:candidate.lowercaseString])candidate=[NSString stringWithFormat:@"%@ (%lu)",base,(unsigned long)n++];
    [used addObject:candidate.lowercaseString];return candidate;
}
static NSInteger SAPPackageNumber(id value) {
    if(![value isKindOfClass:NSNumber.class])return 0;
    long long n=[value longLongValue];return (NSInteger)MAX(0,MIN(n,999999));
}

// Start inside the authorized exporter scratch root. Opening every ancestor from
// / requires directory-read access that an iOS sandbox does not grant, even when
// the final audio file is readable. O_NOFOLLOW still protects every relative node.
static int SAPPackageSource(NSURL *url,int *parentFD,NSString **leaf,struct stat *info) {
    if(![url isKindOfClass:NSURL.class]||!url.isFileURL){errno=EINVAL;return -1;}
    NSString *path=url.path.stringByStandardizingPath;
    if([path hasPrefix:@"/var/"])path=[@"/private" stringByAppendingString:path];
    NSString *logical=NSTemporaryDirectory().stringByStandardizingPath;
    if([logical hasPrefix:@"/var/"])logical=[@"/private" stringByAppendingString:logical];
    NSString *canonical=[[NSURL fileURLWithPath:logical isDirectory:YES]URLByResolvingSymlinksInPath].path;
    NSString *prefix=[canonical stringByAppendingString:@"/"];
    if(![path hasPrefix:prefix])prefix=[logical stringByAppendingString:@"/"];
    if(![path hasPrefix:prefix]) {
        // The exporter can also reuse validated published files. Anchor at the
        // authorized app home, so Documents and Pixie Exports still get NOFOLLOW.
        NSString *home=NSHomeDirectory().stringByStandardizingPath;
        if([home hasPrefix:@"/var/"])home=[@"/private" stringByAppendingString:home];
        NSString *resolved=[[NSURL fileURLWithPath:home isDirectory:YES]URLByResolvingSymlinksInPath].path;
        if([path hasPrefix:[resolved stringByAppendingString:@"/Documents/Pixie Exports/"]]){canonical=resolved;prefix=[resolved stringByAppendingString:@"/"];}
        else if([path hasPrefix:[home stringByAppendingString:@"/Documents/Pixie Exports/"]]){canonical=resolved;prefix=[home stringByAppendingString:@"/"];}
        else {errno=EACCES;return -1;}
    }
    if(canonical.length<2){errno=EINVAL;return -1;}
    NSArray<NSString *> *parts=[[path substringFromIndex:prefix.length]pathComponents];
    if(!parts.count){errno=EINVAL;return -1;}
    int directory=open(canonical.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(directory<0)return -1;
    for(NSUInteger i=0;i+1<parts.count;i++) {
        int next=openat(directory,parts[i].fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
        close(directory);directory=next;if(directory<0)return -1;
    }
    NSString *name=parts.lastObject;
    int fd=openat(directory,name.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0){close(directory);return -1;}
    if(fstat(fd,info)||!S_ISREG(info->st_mode)||info->st_size<0){close(fd);close(directory);errno=EINVAL;return -1;}
    *parentFD=directory;*leaf=name;return fd;
}

@interface SAPLibraryZipEntry : NSObject
@property(nonatomic,strong) NSData *name;
@property(nonatomic) uint64_t size;
@property(nonatomic) uint64_t offset;
@property(nonatomic) uint32_t crc;
@end
@implementation SAPLibraryZipEntry @end

static BOOL SAPZipWrite(int fd,const void *bytes,size_t count,uint64_t *offset,NSError *__strong *error) {
    const uint8_t *cursor=bytes;
    while(count) {
        ssize_t n=write(fd,cursor,count);
        if(n<0&&errno==EINTR)continue;
        if(n<=0){if(error)*error=SAPPackageError(@"Could not write the library ZIP.");return NO;}
        cursor+=n;count-=(size_t)n;*offset+=(uint64_t)n;
    }
    return YES;
}
static void SAPZip16(uint8_t *p,uint16_t x){p[0]=(uint8_t)x;p[1]=(uint8_t)(x>>8);}
static void SAPZip32(uint8_t *p,uint32_t x){SAPZip16(p,(uint16_t)x);SAPZip16(p+2,(uint16_t)(x>>16));}
static void SAPZip64(uint8_t *p,uint64_t x){SAPZip32(p,(uint32_t)x);SAPZip32(p+4,(uint32_t)(x>>32));}

// ZIP STORE with UTF-8 names, CRC-32 data descriptors, and ZIP64 for size/offset/count.
// Memory is bounded by one 128 KiB audio buffer plus central-directory entry metadata.
static BOOL SAPPackageZIP(NSURL *folder,NSArray<NSString *> *paths,NSURL *zip,NSProgress *progress,void (^report)(void),NSError *__strong *error) {
    int output=open(zip.path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(output<0){if(error)*error=SAPPackageError(@"Could not create the library ZIP.");return NO;}
    BOOL ok=YES;uint64_t offset=0;
    NSMutableArray<SAPLibraryZipEntry *> *entries=[NSMutableArray arrayWithCapacity:paths.count];
    uint8_t buffer[128*1024];
    for(NSString *path in paths) {@autoreleasepool {
        if(SAPPackageCancelled(progress,error)){ok=NO;break;}
        NSURL *source=[folder URLByAppendingPathComponent:path];
        int input=open(source.path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
        struct stat info;
        if(input<0||fstat(input,&info)||!S_ISREG(info.st_mode)||info.st_size<0){if(input>=0)close(input);if(error)*error=SAPPackageError(@"A library snapshot is no longer available.");ok=NO;break;}
        SAPLibraryZipEntry *entry=[SAPLibraryZipEntry new];entry.name=[path dataUsingEncoding:NSUTF8StringEncoding];entry.size=(uint64_t)info.st_size;entry.offset=offset;
        if(!entry.name||entry.name.length>UINT16_MAX){close(input);if(error)*error=SAPPackageError(@"A library ZIP path is too long.");ok=NO;break;}
        BOOL wide=entry.size>=UINT32_MAX;uint8_t local[50]={0};
        SAPZip32(local,0x04034b50);SAPZip16(local+4,wide?45:20);SAPZip16(local+6,0x0808);
        SAPZip16(local+12,0x0021); // DOS date 1980-01-01, independent of local timezone.
        SAPZip32(local+18,wide?UINT32_MAX:0);SAPZip32(local+22,wide?UINT32_MAX:0);
        SAPZip16(local+26,(uint16_t)entry.name.length);SAPZip16(local+28,wide?20:0);
        if(wide){SAPZip16(local+30,1);SAPZip16(local+32,16);SAPZip64(local+34,entry.size);SAPZip64(local+42,entry.size);}
        ok=SAPZipWrite(output,local,30,&offset,error)&&SAPZipWrite(output,entry.name.bytes,entry.name.length,&offset,error);
        if(ok&&wide)ok=SAPZipWrite(output,local+30,20,&offset,error);
        uint64_t remaining=entry.size;uLong crc=crc32(0L,Z_NULL,0);
        while(ok&&remaining) {
            if(SAPPackageCancelled(progress,error)){ok=NO;break;}
            size_t want=(size_t)MIN((uint64_t)sizeof(buffer),remaining);ssize_t n=read(input,buffer,want);
            if(n<0&&errno==EINTR)continue;
            if(n<=0){if(error)*error=SAPPackageError(@"A library audio file changed while packaging.");ok=NO;break;}
            crc=crc32(crc,buffer,(uInt)n);ok=SAPZipWrite(output,buffer,(size_t)n,&offset,error);
            remaining-=(uint64_t)n;progress.completedUnitCount+=n;report();
        }
        struct stat after;
        if(ok&&(fstat(input,&after)||after.st_size!=info.st_size||after.st_mtimespec.tv_sec!=info.st_mtimespec.tv_sec||after.st_mtimespec.tv_nsec!=info.st_mtimespec.tv_nsec)) {
            if(error)*error=SAPPackageError(@"A library audio file changed while packaging.");ok=NO;
        }
        close(input);if(!ok)break;
        entry.crc=(uint32_t)crc;uint8_t descriptor[24]={0};SAPZip32(descriptor,0x08074b50);SAPZip32(descriptor+4,entry.crc);
        if(wide){SAPZip64(descriptor+8,entry.size);SAPZip64(descriptor+16,entry.size);}else{SAPZip32(descriptor+8,(uint32_t)entry.size);SAPZip32(descriptor+12,(uint32_t)entry.size);}
        ok=SAPZipWrite(output,descriptor,wide?24:16,&offset,error);if(!ok)break;
        [entries addObject:entry];
    }}
    uint64_t centralOffset=offset;
    if(ok)for(SAPLibraryZipEntry *entry in entries) {
        if(SAPPackageCancelled(progress,error)){ok=NO;break;}
        BOOL bigSize=entry.size>=UINT32_MAX,bigOffset=entry.offset>=UINT32_MAX;
        uint16_t extraLength=(bigSize||bigOffset)?(uint16_t)(4+(bigSize?16:0)+(bigOffset?8:0)):0;
        uint8_t header[46]={0},extra[28]={0};SAPZip32(header,0x02014b50);SAPZip16(header+4,45);SAPZip16(header+6,(bigSize||bigOffset)?45:20);
        SAPZip16(header+8,0x0808);SAPZip16(header+14,0x0021);SAPZip32(header+16,entry.crc);
        SAPZip32(header+20,bigSize?UINT32_MAX:(uint32_t)entry.size);SAPZip32(header+24,bigSize?UINT32_MAX:(uint32_t)entry.size);
        SAPZip16(header+28,(uint16_t)entry.name.length);SAPZip16(header+30,extraLength);SAPZip32(header+42,bigOffset?UINT32_MAX:(uint32_t)entry.offset);
        if(extraLength){SAPZip16(extra,1);SAPZip16(extra+2,extraLength-4);NSUInteger at=4;if(bigSize){SAPZip64(extra+at,entry.size);SAPZip64(extra+at+8,entry.size);at+=16;}if(bigOffset)SAPZip64(extra+at,entry.offset);}
        ok=SAPZipWrite(output,header,sizeof(header),&offset,error)&&SAPZipWrite(output,entry.name.bytes,entry.name.length,&offset,error)&&SAPZipWrite(output,extra,extraLength,&offset,error);
        if(!ok)break;
    }
    uint64_t centralSize=offset-centralOffset;
    if(ok&&(entries.count>=UINT16_MAX||centralSize>=UINT32_MAX||centralOffset>=UINT32_MAX)) {
        uint64_t endOffset=offset;uint8_t end[56]={0},locator[20]={0};SAPZip32(end,0x06064b50);SAPZip64(end+4,44);SAPZip16(end+12,45);SAPZip16(end+14,45);
        SAPZip64(end+24,entries.count);SAPZip64(end+32,entries.count);SAPZip64(end+40,centralSize);SAPZip64(end+48,centralOffset);
        SAPZip32(locator,0x07064b50);SAPZip64(locator+8,endOffset);SAPZip32(locator+16,1);
        ok=SAPZipWrite(output,end,sizeof(end),&offset,error)&&SAPZipWrite(output,locator,sizeof(locator),&offset,error);
    }
    if(ok) {
        uint8_t end[22]={0};SAPZip32(end,0x06054b50);SAPZip16(end+8,(uint16_t)MIN(entries.count,UINT16_MAX));SAPZip16(end+10,(uint16_t)MIN(entries.count,UINT16_MAX));
        SAPZip32(end+12,(uint32_t)MIN(centralSize,UINT32_MAX));SAPZip32(end+16,(uint32_t)MIN(centralOffset,UINT32_MAX));
        ok=SAPZipWrite(output,end,sizeof(end),&offset,error);
    }
    if(close(output)&&ok){if(error)*error=SAPPackageError(@"Could not finish writing the library ZIP.");ok=NO;}
    return ok&&!SAPPackageCancelled(progress,error);
}

static NSString *SAPPackageCategory(id value) {
    NSString *category=SAPPackageString(value,@"Albums").lowercaseString;
    if([@[@"single",@"singles"]containsObject:category])return @"Singles";
    if([@[@"ep",@"eps"]containsObject:category])return @"EPs";
    if([@[@"compilation",@"compilations"]containsObject:category])return @"Compilations";
    return @"Albums";
}
static NSURL *SAPBuildLibraryPackage(NSArray<NSDictionary *> *tracks,BOOL zip,NSProgress *progress,void (^report)(void),NSError *__strong *error) {
    if(!tracks.count){*error=SAPPackageError(@"No audio tracks were selected.");return nil;}
    NSMutableArray<NSMutableDictionary *> *items=[NSMutableArray arrayWithCapacity:tracks.count];
    NSMutableSet<NSString *> *identities=[NSMutableSet set];NSMutableDictionary *releaseOwners=NSMutableDictionary.dictionary;int64_t total=1;
    for(id object in tracks) {
        if(SAPPackageCancelled(progress,error))return nil;
        if(![object isKindOfClass:NSDictionary.class]){*error=SAPPackageError(@"A selected library track is invalid.");return nil;}
        NSDictionary *track=object;NSURL *file=track[@"file"];
        NSString *identity=SAPPackageString(track[@"uri"],@"");
        if(![file isKindOfClass:NSURL.class]||!file.isFileURL||!identity.length||![@[@"m4a",@"ogg"]containsObject:file.pathExtension.lowercaseString]){*error=SAPPackageError(@"Library packages require prepared M4A or Ogg tracks with identities.");return nil;}
        if([identities containsObject:identity])continue;[identities addObject:identity];
        int parent=-1;NSString *leaf=nil;struct stat info;int input=SAPPackageSource(file,&parent,&leaf,&info);
        if(input<0){int code=errno;*error=[NSError errorWithDomain:NSPOSIXErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"Could not read prepared audio (%d: %s).",code,strerror(code)]}];return nil;}close(input);close(parent);
        if(zip&&info.st_size>INT64_MAX-total-1){*error=SAPPackageError(@"The selected audio library is too large.");return nil;}
        total+=1+(zip?info.st_size:0);
        NSString *artist=SAPPackageString(track[@"artist_name"],@"Unknown Artist");
        NSString *album=SAPPackageString(track[@"album_name"],@"Unknown Album");
        NSString *artistURI=SAPPackageString(track[@"artist_uri"],@"");
        NSString *albumURI=SAPPackageString(track[@"album_uri"],@"");
        NSString *artistKey=artistURI.length?[@"uri:" stringByAppendingString:artistURI]:[@"name:" stringByAppendingString:artist];
        NSString *albumKey=albumURI.length?[@"uri:" stringByAppendingString:albumURI]:[@"name:" stringByAppendingString:album];
        NSString *category=SAPPackageCategory(track[@"category"]);
        id<NSCopying> releaseKey=albumURI.length?(id)albumKey:@[artistKey,category,albumKey];
        [items addObject:[@{@"file":file,@"identity":identity,@"artist":artist,@"album":album,@"artist_key":artistKey,@"album_key":albumKey,@"title":SAPPackageString(track[@"name"],@"Track"),@"number":@(SAPPackageNumber(track[@"number"])),@"disc":@(MAX(1,SAPPackageNumber(track[@"disc"]))),@"size":@(info.st_size),@"device":@(info.st_dev),@"inode":@(info.st_ino)}mutableCopy]];
        items.lastObject[@"category"]=category;
        items.lastObject[@"category_order"]=@([@[@"Albums",@"EPs",@"Singles",@"Compilations"]indexOfObject:category]);
        items.lastObject[@"release_key"]=releaseKey;
        NSDictionary *previous=releaseOwners[releaseKey];BOOL earlier=previous==nil;
        if(previous)for(NSString *key in @[@"disc",@"number",@"identity"]) {
            NSComparisonResult order=[items.lastObject[key]compare:previous[key]];
            if(order!=NSOrderedSame){earlier=order==NSOrderedAscending;break;}
        }
        if(earlier)releaseOwners[releaseKey]=items.lastObject;
    }
    BOOL single=items.count==1;if(single){zip=NO;total=2;}
    progress.totalUnitCount=total;
    // Album-artist metadata is not supplied here. Use the earliest available
    // track as a stable grouping owner, while keeping the source audio tags intact.
    for(NSMutableDictionary *item in items) {
        NSDictionary *owner=releaseOwners[item[@"release_key"]];
        for(NSString *key in @[@"artist",@"artist_key",@"album",@"category",@"category_order"])item[key]=owner[key];
    }
    BOOL oneRelease=releaseOwners.count==1;
    NSArray *sortKeys=oneRelease?@[@"disc",@"number",@"identity"]:@[@"artist",@"artist_key",@"category_order",@"category",@"album",@"album_key",@"disc",@"number",@"identity"];
    [items sortUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        for(NSString *key in sortKeys) {NSComparisonResult r=[a[key]compare:b[key]];if(r!=NSOrderedSame)return r;}return NSOrderedSame;
    }];
    if(SAPPackageCancelled(progress,error))return nil;
    NSURL *temp=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]URLByResolvingSymlinksInPath];
    NSString *pattern=[temp.path stringByAppendingPathComponent:@"PixieLibrary-XXXXXX"];
    char *template=strdup(pattern.fileSystemRepresentation);char *created=mkdtemp(template);
    if(!created){free(template);*error=SAPPackageError(@"Could not create a private library package directory.");return nil;}
    SAPLibraryPackageLease *lease=[SAPLibraryPackageLease new];lease.root=[NSURL fileURLWithFileSystemRepresentation:created isDirectory:YES relativeToURL:nil];free(template);
    NSString *packageName=oneRelease?SAPPackageComponent(items.firstObject[@"album"],@"Unknown Album"):@"Music";
    NSURL *folder=[lease.root URLByAppendingPathComponent:packageName isDirectory:YES];NSFileManager *fm=NSFileManager.defaultManager;
    NSError *fileError=nil;
    if(![fm createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:&fileError]){*error=fileError;return nil;}
    NSMutableDictionary<NSString *,NSString *> *artists=[NSMutableDictionary dictionary];NSMutableSet *artistNames=[NSMutableSet set];
    NSMutableDictionary<id<NSCopying>,NSString *> *albums=[NSMutableDictionary dictionary];NSMutableDictionary<NSString *,NSMutableSet *> *albumNames=[NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *,NSMutableSet *> *filenames=[NSMutableDictionary dictionary];
    if(oneRelease)filenames[@""]=NSMutableSet.set;
    NSMutableArray<NSString *> *paths=[NSMutableArray arrayWithCapacity:items.count];
    for(NSDictionary *item in items) {@autoreleasepool {
        if(SAPPackageCancelled(progress,error))return nil;
        NSString *albumPath=@"";
        if(!oneRelease) {
            NSString *artist=item[@"artist"],*artistKey=item[@"artist_key"],*artistPath=artists[artistKey];
            if(!artistPath){artistPath=SAPPackageUniqueComponent(SAPPackageComponent(artist,@"Unknown Artist"),artistNames);artists[artistKey]=artistPath;}
            NSString *categoryPath=[artistPath stringByAppendingPathComponent:item[@"category"]];
            if(!albumNames[categoryPath])albumNames[categoryPath]=NSMutableSet.set;
            id<NSCopying> albumKey=item[@"release_key"];albumPath=albums[albumKey];
            if(!albumPath){NSString *component=SAPPackageUniqueComponent(SAPPackageComponent(item[@"album"],@"Unknown Album"),albumNames[categoryPath]);albumPath=[categoryPath stringByAppendingPathComponent:component];albums[albumKey]=albumPath;filenames[albumPath]=[NSMutableSet set];NSError *directoryError=nil;if(![fm createDirectoryAtURL:[folder URLByAppendingPathComponent:albumPath isDirectory:YES] withIntermediateDirectories:YES attributes:nil error:&directoryError]){*error=directoryError;return nil;}}
        }
        NSString *base=SAPPackageComponent(item[@"title"],@"Track");
        NSString *ext=[item[@"file"]pathExtension].lowercaseString,*name=[base stringByAppendingPathExtension:ext];NSMutableSet *used=filenames[albumPath];
        if([used containsObject:name.lowercaseString]) {
            NSString *identity=SAPPackageShorten(SAPPackageComponent(item[@"identity"],@"track"),64);
            NSString *shortBase=SAPPackageShorten(base,100);
            // Reserve room for identity even when the title itself reaches the component limit.
            NSString *collision=[NSString stringWithFormat:@"%@ [%@]",shortBase.length?shortBase:@"Track",identity.length?identity:@"track"];
            name=[collision stringByAppendingPathExtension:ext];NSUInteger suffix=2;
            while([used containsObject:name.lowercaseString])name=[[NSString stringWithFormat:@"%@ (%lu)",collision,(unsigned long)suffix++]stringByAppendingPathExtension:ext];
        }
        [used addObject:name.lowercaseString];NSString *relative=[albumPath stringByAppendingPathComponent:name];NSURL *destination=[folder URLByAppendingPathComponent:relative];
        int parent=-1;NSString *leaf=nil;struct stat source;int fd=SAPPackageSource(item[@"file"],&parent,&leaf,&source);
        if(fd<0){*error=SAPPackageError(@"A selected audio file is no longer available.");return nil;}
        BOOL same=(uint64_t)source.st_ino==[item[@"inode"]unsignedLongLongValue]&&(uint64_t)source.st_dev==[item[@"device"]unsignedLongLongValue]&&source.st_size==[item[@"size"]longLongValue];
        int linked=same?linkat(parent,leaf.fileSystemRepresentation,AT_FDCWD,destination.path.fileSystemRepresentation,0):-1;
        struct stat snapshot;BOOL valid=linked==0&&lstat(destination.path.fileSystemRepresentation,&snapshot)==0&&S_ISREG(snapshot.st_mode)&&snapshot.st_ino==source.st_ino&&snapshot.st_dev==source.st_dev;
        close(fd);close(parent);
        if(!valid){*error=SAPPackageError(@"Could not create a safe hard-link snapshot of the selected audio.");return nil;}
        [paths addObject:relative];progress.completedUnitCount++;report();
    }}
    NSURL *result=single?[folder URLByAppendingPathComponent:paths.firstObject]:folder;
    if(zip){result=[lease.root URLByAppendingPathComponent:[packageName stringByAppendingPathExtension:@"zip"]];if(!SAPPackageZIP(folder,paths,result,progress,report,error))return nil;if(![fm removeItemAtURL:folder error:&fileError]){*error=fileError;return nil;}}
    if(SAPPackageCancelled(progress,error))return nil;
    progress.completedUnitCount=progress.totalUnitCount;report();
    objc_setAssociatedObject(result,&SAPLibraryLeaseKey,lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);return result;
}

NSProgress *SAPPrepareOfflineLibraryPackage(NSArray<NSDictionary *> *tracks,BOOL zip,void (^callback)(double),void (^completion)(NSURL *,NSError *)) {
    NSProgress *progress=[NSProgress progressWithTotalUnitCount:1];progress.cancellable=YES;
    // Copy metadata and retain source URLs (including their exporter scratch leases) through snapshotting.
    NSMutableArray *snapshot=[NSMutableArray arrayWithCapacity:tracks.count];
    for(id item in tracks)[snapshot addObject:[item conformsToProtocol:@protocol(NSCopying)]?[item copy]:item];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool {
        __block double last=-1;__block NSTimeInterval lastTime=0;
        void (^report)(void)=^{double fraction=progress.fractionCompleted;NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            if(callback&&(fraction==1||last<0||((fraction-last)>=0.005&&now-lastTime>=0.03))){last=fraction;lastTime=now;dispatch_async(dispatch_get_main_queue(),^{callback(fraction);});}};
        report();NSError *error=nil;NSURL *result=SAPBuildLibraryPackage(snapshot,zip,progress,report,&error);
        dispatch_async(dispatch_get_main_queue(),^{
            NSError *failure=error;NSURL *package=result;
            if(SAPPackageCancelled(progress,&failure)){if(package)SAPReleaseOfflineLibraryPackage(package);package=nil;}
            if(completion)completion(package,failure);
        });
    }});return progress;
}
void SAPReleaseOfflineLibraryPackage(NSURL *package) {objc_setAssociatedObject(package,&SAPLibraryLeaseKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
