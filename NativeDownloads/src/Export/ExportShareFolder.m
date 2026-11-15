#import "ExportShareFolder.h"
#import "ExportArtwork.h"
#import <objc/runtime.h>
#include <sys/stat.h>
#include <unistd.h>
static char shareLeaseKey,singleFolderKey;
@interface SAPExportShareLease:NSObject
@property(nonatomic,strong) NSURL *root;
@end
@implementation SAPExportShareLease
- (void)dealloc {[NSFileManager.defaultManager removeItemAtURL:_root error:nil];}
@end
NSURL *SAPCreateAudioShareFolder(NSArray<NSURL *> *files,NSString *name,NSString **error) {
    if(error)*error=nil;if(!files.count){if(error)*error=@"No album files were exported.";return nil;}
    if(!name.length)name=@"Album";
    name=[[name componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:\n\r\t"]]componentsJoinedByString:@"_"];
    while([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>180)name=[name substringToIndex:[name rangeOfComposedCharacterSequenceAtIndex:name.length-1].location];
    if([name isEqual:@"."]||[name isEqual:@".."]||!name.length)name=@"Album";
    NSFileManager *fm=NSFileManager.defaultManager;
    SAPExportShareLease *lease=[SAPExportShareLease new];lease.root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[@"PixieShare-" stringByAppendingString:NSUUID.UUID.UUIDString]] isDirectory:YES];
    NSURL *folder=[lease.root URLByAppendingPathComponent:name isDirectory:YES];NSError *failure=nil;
    if(![fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&failure]){if(error)*error=failure.localizedDescription;return nil;}
    NSMutableSet *linked=[NSMutableSet set];
    for(NSURL *file in files) {
        struct stat info;if(!file.isFileURL||lstat(file.path.fileSystemRepresentation,&info)||!S_ISREG(info.st_mode)){if(error)*error=@"An exported album file is no longer available.";return nil;}
        if([linked containsObject:file.path])continue;[linked addObject:file.path];
        NSString *filename=SAPAttachedExportArtwork(file)[@"share_filename"]?:file.lastPathComponent;
        if(![filename isEqual:filename.lastPathComponent]||[filename isEqual:@"."]||[filename isEqual:@".."]){if(error)*error=@"Invalid album filename.";return nil;}
        NSURL *destination=[folder URLByAppendingPathComponent:filename];
        if([fm fileExistsAtPath:destination.path]){
            NSString *uri=SAPAttachedExportArtwork(file)[@"track_uri"];
            if(![uri hasPrefix:@"spotify:track:"]||uri.length!=36){if(error)*error=@"Two different album tracks have the same filename.";return nil;}
            filename=[NSString stringWithFormat:@"%@ [%@].%@",filename.stringByDeletingPathExtension,[uri substringFromIndex:14],filename.pathExtension];
            destination=[folder URLByAppendingPathComponent:filename];
            if([fm fileExistsAtPath:destination.path]){if(error)*error=@"Duplicate album track identity.";return nil;}
        }
        if(link(file.path.fileSystemRepresentation,destination.path.fileSystemRepresentation)){if(error)*error=@"Could not prepare the album folder for sharing.";return nil;}
    }
    NSArray *skipped=SAPAttachedExportArtwork(files.firstObject)[@"album_skipped"];
    if([skipped count]) {
        NSString *note=[@"Spotify could not download these tracks, so they are not included:\n" stringByAppendingString:[skipped componentsJoinedByString:@"\n"]];
        [note writeToURL:[folder URLByAppendingPathComponent:@"Skipped tracks.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    objc_setAssociatedObject(folder,&shareLeaseKey,lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return folder;
}

void SAPRetainTemporaryAudioFiles(NSArray<NSURL *> *files,NSURL *root) {
    if(!files.count||!root)return;
    SAPExportShareLease *lease=[SAPExportShareLease new];lease.root=root;
    for(NSURL *file in files)objc_setAssociatedObject(file,&shareLeaseKey,lease,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

NSURL *SAPCreateAudioShareFile(NSURL *file,NSString **error) {
    NSURL *folder=SAPCreateAudioShareFolder(@[file],@"Audio",error);if(!folder)return nil;
    NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtURL:folder includingPropertiesForKeys:nil options:0 error:nil];
    if(files.count!=1){if(error)*error=@"The audio share snapshot is incomplete.";return nil;}
    NSURL *audio=files.firstObject;
    objc_setAssociatedObject(audio,&singleFolderKey,folder,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SAPAttachExportArtwork(audio,SAPAttachedExportArtwork(file));return audio;
}
