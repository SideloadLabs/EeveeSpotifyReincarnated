#import <Foundation/Foundation.h>
#import "ExportShareFolder.h"
#include <assert.h>
#include <sys/stat.h>
int main(void){@autoreleasepool {
 NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
 [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];
 NSURL *first=[root URLByAppendingPathComponent:@"one.m4a"],*second=[[root URLByAppendingPathComponent:@"other"]URLByAppendingPathComponent:@"two.m4a"];
 [NSFileManager.defaultManager createDirectoryAtURL:second.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
 [@"audio1" writeToURL:first atomically:YES encoding:NSUTF8StringEncoding error:nil];[@"audio2" writeToURL:second atomically:YES encoding:NSUTF8StringEncoding error:nil];
 [@"old-format" writeToURL:[root URLByAppendingPathComponent:@"one.ogg"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
 NSString *path;
 @autoreleasepool {NSString *error=nil;NSURL *folder=SAPCreateAudioShareFolder(@[first,second],@"Album",&error);assert(folder&&!error);path=[folder.path copy];
 NSArray *names=[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder.path error:nil];assert(names.count==2&&[names containsObject:@"one.m4a"]&&[names containsObject:@"two.m4a"]);
 struct stat a,b;assert(!stat(first.path.fileSystemRepresentation,&a)&&!stat([[folder URLByAppendingPathComponent:@"one.m4a"]path].fileSystemRepresentation,&b)&&a.st_ino==b.st_ino);
 }
 assert(![NSFileManager.defaultManager fileExistsAtPath:path]);assert([NSFileManager.defaultManager fileExistsAtPath:first.path]);
 NSString *scratchPath;
 @autoreleasepool {
  NSURL *scratch=[root URLByAppendingPathComponent:@"temporary-audio" isDirectory:YES];
  [NSFileManager.defaultManager createDirectoryAtURL:scratch withIntermediateDirectories:YES attributes:nil error:nil];
  NSURL *audio=[scratch URLByAppendingPathComponent:@"track.m4a"];
  [@"audio" writeToURL:audio atomically:YES encoding:NSUTF8StringEncoding error:nil];scratchPath=[scratch.path copy];
  SAPRetainTemporaryAudioFiles(@[audio],scratch);
  assert([NSFileManager.defaultManager fileExistsAtPath:audio.path]);
 }
 assert(![NSFileManager.defaultManager fileExistsAtPath:scratchPath]);
 [NSFileManager.defaultManager removeItemAtURL:root error:nil];puts("PASS album snapshot only chosen files, mixed parents, no duplicate audio blocks, lifetime cleanup");
}return 0;}
