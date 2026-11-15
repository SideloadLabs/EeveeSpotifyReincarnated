#import <Foundation/Foundation.h>
#import "OfflineLibraryPackage.h"
#include <sandbox.h>
#include <assert.h>
static NSString *fixtureHome;
NSString *SAPFixtureHome(void){return fixtureHome;}
int main(void){@autoreleasepool {
 NSURL *root=[[[NSURL fileURLWithPath:NSTemporaryDirectory()isDirectory:YES]URLByResolvingSymlinksInPath]URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
 assert([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL]);
 NSURL *file=[root URLByAppendingPathComponent:@"track.m4a"];NSData *data=[@"prepared audio" dataUsingEncoding:NSUTF8StringEncoding];assert([data writeToURL:file atomically:YES]);
 fixtureHome=[NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:[@".package-sandbox-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString]];
 NSURL *published=[NSURL fileURLWithPath:[fixtureHome stringByAppendingPathComponent:@"Documents/Pixie Exports/Artist/Album/track.m4a"]];
 assert([NSFileManager.defaultManager createDirectoryAtURL:published.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL]);assert([data writeToURL:published atomically:YES]);
 // Warm Foundation before restricting ancestor-directory reads, as on iOS.
 (void)[[NSURL fileURLWithPath:NSTemporaryDirectory()]URLByResolvingSymlinksInPath];
 char *reason=NULL;int status=sandbox_init("(version 1)(allow default)(deny file-read-data (literal \"/private/var\"))",0,&reason);
 if(status){fprintf(stderr,"sandbox unavailable: %s\n",reason?reason:"");return 2;}
 assert([[NSData dataWithContentsOfURL:file]isEqual:data]);
 __block BOOL done=NO;__block NSURL *output=nil;
 SAPPrepareOfflineLibraryPackage(@[@{@"file":file,@"uri":@"spotify:track:fixture"},@{@"file":published,@"uri":@"spotify:track:published"}],NO,nil,^(NSURL *url,NSError *error){
  if(error)fprintf(stderr,"package: %s\n",error.localizedDescription.UTF8String);output=url;done=YES;
 });
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:10];while(!done && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
 assert(done && output);SAPReleaseOfflineLibraryPackage(output);[NSFileManager.defaultManager removeItemAtURL:root error:NULL];[NSFileManager.defaultManager removeItemAtPath:fixtureHome error:NULL];puts("offline_library_sandbox PASS");
}}
