#import <Foundation/Foundation.h>
#import "ExportLibrary.h"
#include <assert.h>
#include <sqlite3.h>
static void put(NSURL *url,NSString *text){assert([text writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]);}
int main(void){@autoreleasepool {
 NSURL *root=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
 NSURL *input=[root URLByAppendingPathComponent:@"scratch.ogg"];
 [NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil];put(input,@"audio one");
 NSURL *library=[root URLByAppendingPathComponent:@"Pixie Exports"];
 NSDictionary *track=@{@"uri":@"spotify:track:0123456789012345678901",@"name":@"One",@"artist_name":@"Artist",@"album_name":@"Album",@"number":@1};NSString *error=nil;
 NSURL *a=SAPExportLibraryPublish(input,library,track,&error);assert(a&&!error);assert([a.lastPathComponent isEqual:@"One.ogg"]);assert([a.path containsString:@"/Artist/Album/"]);
 put(input,@"audio two");NSURL *b=SAPExportLibraryPublish(input,library,track,&error);assert([a isEqual:b]);
 assert([[NSString stringWithContentsOfURL:a encoding:NSUTF8StringEncoding error:nil]isEqual:@"audio two"]);
 NSMutableDictionary *other=[track mutableCopy];other[@"uri"]=@"spotify:track:0123456789012345678902";
 NSURL *c=SAPExportLibraryPublish(input,library,other,&error);assert(c&&![c isEqual:a]);
 sqlite3 *db=NULL;assert(sqlite3_open([[library URLByAppendingPathComponent:@".pixie-index.sqlite"]path].fileSystemRepresentation,&db)==SQLITE_OK);
 assert(sqlite3_exec(db,"CREATE TRIGGER reject_change BEFORE UPDATE ON exports BEGIN SELECT RAISE(ABORT,'synthetic index failure'); END",NULL,NULL,NULL)==SQLITE_OK);
 put(input,@"must not replace");assert(!SAPExportLibraryPublish(input,library,track,&error));
 assert([[NSString stringWithContentsOfURL:a encoding:NSUTF8StringEncoding error:nil]isEqual:@"audio two"]);
 assert(sqlite3_exec(db,"DROP TRIGGER reject_change",NULL,NULL,NULL)==SQLITE_OK);sqlite3_close(db);
 [NSFileManager.defaultManager removeItemAtURL:input error:nil];assert(!SAPExportLibraryPublish(input,library,track,&error));
 assert([[NSString stringWithContentsOfURL:a encoding:NSUTF8StringEncoding error:nil]isEqual:@"audio two"]);
 NSURL *outside=[root URLByAppendingPathComponent:@"keep.txt"];put(outside,@"keep");
 assert(SAPExportLibraryClear(library,&error));assert([NSFileManager.defaultManager fileExistsAtPath:outside.path]);
 assert(![NSFileManager.defaultManager fileExistsAtPath:a.path]);
 [NSFileManager.defaultManager removeItemAtURL:root error:nil];puts("PASS export identity, collision, atomic replacement, failure preservation, scoped cleanup");
}return 0;}
