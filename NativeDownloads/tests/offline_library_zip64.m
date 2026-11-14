// Exercise the actual private streaming writer at ZIP64's entry-count boundary,
// without creating 65,536 hardlinks or duplicating audio blocks on disk.
#import "../src/Library/OfflineLibraryPackage.m"
#include <assert.h>
int main(int argc,const char **argv) {@autoreleasepool {
 assert(argc==2);NSURL *archive=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
 NSURL *folder=[archive.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"zip64-input" isDirectory:YES];
 assert([NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:NO attributes:nil error:NULL]);
 assert([[NSData data]writeToURL:[folder URLByAppendingPathComponent:@"empty.ogg"] atomically:YES]);
 NSMutableArray *paths=[NSMutableArray arrayWithCapacity:65536];for(NSUInteger i=0;i<65536;i++)[paths addObject:@"empty.ogg"];
 NSProgress *progress=[NSProgress progressWithTotalUnitCount:1];NSError *error=nil;
 assert(SAPPackageZIP(folder,paths,archive,progress,^{},&error)&&!error);
 assert([NSFileManager.defaultManager removeItemAtURL:folder error:NULL]);
 puts("PASS ZIP64 65,536-entry native streaming writer boundary");
 }return 0;}
