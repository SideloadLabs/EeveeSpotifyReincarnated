#import <Foundation/Foundation.h>
#import "OfflineLibraryPackage.h"
#include <assert.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>

static NSURL *Prepare(NSArray *tracks, BOOL zip, BOOL cancel, NSError **failure) {
    __block BOOL done=NO; __block NSURL *result=nil; __block NSError *error=nil;
    NSProgress *progress=SAPPrepareOfflineLibraryPackage(tracks,zip,^(double value){assert(NSThread.isMainThread);assert(value>=0&&value<=1);},^(NSURL *url,NSError *e){assert(NSThread.isMainThread);result=url;error=e;done=YES;});
    if(cancel)[progress cancel];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:20];
    while(!done&&deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(done);if(failure)*failure=error;return result;
}
static NSDictionary *Track(NSURL *file,NSString *uri,NSString *name,NSString *artist,NSString *album,NSInteger number) {
 return @{ @"file":file,@"uri":uri,@"name":name,@"artist_name":artist,@"album_name":album,@"number":@(number),@"disc":@1,@"category":@"album"};
}
static NSSet *ScratchRoots(void) {
 NSMutableSet *names=[NSMutableSet set];
 for(NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:NULL])
  if([name hasPrefix:@"PixieLibrary-"])[names addObject:name];
 return names;
}
static void TestStreamingCancellation(NSURL *root) {
 NSFileManager *fm=NSFileManager.defaultManager;NSURL *large=[root URLByAppendingPathComponent:@"large.m4a"];
 int fd=open(large.path.fileSystemRepresentation,O_RDWR|O_CREAT|O_EXCL,0600);assert(fd>=0);assert(!ftruncate(fd,256*1024*1024));close(fd);
 NSSet *before=ScratchRoots();__block BOOL done=NO,sawWork=NO;__block NSProgress *job=nil;
 job=SAPPrepareOfflineLibraryPackage(@[Track(large,@"large",@"Long",@"Artist",@"Album",1),Track(large,@"large2",@"Long2",@"Artist",@"Album",2)],YES,^(double fraction){
  assert(NSThread.isMainThread);if(fraction>0.01&&fraction<1){sawWork=YES;[job cancel];}
 },^(NSURL *url,NSError *error){assert(!url&&error.code==NSUserCancelledError);done=YES;});
 NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:30];
 while(!done&&deadline.timeIntervalSinceNow>0)[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
 assert(done&&sawWork);job=nil;
 assert([ScratchRoots()isEqual:before]);assert([fm fileExistsAtPath:large.path]);[fm removeItemAtURL:large error:NULL];
}
int main(int argc,const char **argv) {@autoreleasepool {
 NSFileManager *fm=NSFileManager.defaultManager;
 NSURL *root=[[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]URLByResolvingSymlinksInPath];
 root=[root URLByAppendingPathComponent:[@"package-fixture-" stringByAppendingString:NSUUID.UUID.UUIDString] isDirectory:YES];
 assert([fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:NULL]);
 NSURL *a=[root URLByAppendingPathComponent:@"a.m4a"],*b=[root URLByAppendingPathComponent:@"b.ogg"];
 NSData *bytes=[@"fake M4A / Ogg bytes are retained, not transcoded" dataUsingEncoding:NSUTF8StringEncoding];
 assert([bytes writeToURL:a atomically:YES]);assert([bytes writeToURL:b atomically:YES]);
 [@"private db" writeToURL:[root URLByAppendingPathComponent:@"library.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
 NSArray *tracks=@[Track(a,@"spotify:track:aaaaaaaaaaaaaaaaaaaaaa",@"Été/空",@"Björk",@"作品",2),Track(b,@"spotify:track:bbbbbbbbbbbbbbbbbbbbbb",@"Été:空",@"Björk",@"作品",2),Track(a,@"spotify:track:cccccccccccccccccccccc",@"Intro",@"Björk",@"作品",1),Track(a,@"spotify:track:dddddddddddddddddddddd",@"Intro",@"Other",@"作品",1)];
 NSError *error=nil;NSSet *initialScratch=ScratchRoots();
 for(NSNumber *archive in @[@NO,@YES]){NSURL *single=Prepare(@[Track(a,@"single",@"One Track",@"Artist",@"Album",1)],archive.boolValue,NO,&error);assert(single&&!error);struct stat info;assert(!lstat(single.path.fileSystemRepresentation,&info)&&S_ISREG(info.st_mode));assert([single.lastPathComponent isEqual:@"One Track.m4a"]);SAPReleaseOfflineLibraryPackage(single);}

 NSURL *folder=Prepare(tracks,NO,NO,&error);assert(folder&&!error);assert([folder.lastPathComponent isEqual:@"Music"]);
 NSArray *paths=[fm subpathsAtPath:folder.path];assert(paths.count==10);
 assert([fm fileExistsAtPath:[folder.path stringByAppendingPathComponent:@"Björk/Albums/作品/Intro.m4a"]]);
 NSMutableSet *inodes=[NSMutableSet set];NSUInteger files=0;
 for(NSString *path in paths){NSURL *file=[folder URLByAppendingPathComponent:path];struct stat s;if(!lstat(file.path.fileSystemRepresentation,&s)&&S_ISREG(s.st_mode)){files++;[inodes addObject:@(s.st_ino)];assert(([@[@"m4a",@"ogg"]containsObject:file.pathExtension]));assert([[NSData dataWithContentsOfURL:file]isEqual:bytes]);}}
 assert(files==4&&inodes.count==2);
 NSString *folderPath=[folder.path copy];SAPReleaseOfflineLibraryPackage(folder);assert(![fm fileExistsAtPath:folderPath]);
 // Distinct names that sanitize to the same component must retain both artists/albums.
 NSMutableDictionary *multi1=[Track(a,@"multi1",@".. /\\:\n",@"A/B",@"X/Y",2)mutableCopy];multi1[@"disc"]=@2;
 NSDictionary *multi2=Track(b,@"multi2",@"First",@"A/B",@"X/Y",1);
 NSDictionary *multi3=Track(a,@"multi3",@"Different Artist",@"A:B",@"X/Y",1);
 NSDictionary *multi4=Track(a,@"multi4",@"Different Album",@"A/B",@"X:Y",1);
 NSURL *sanitized=Prepare(@[multi1,multi2,multi3,multi4],NO,NO,&error);assert(sanitized&&!error);
 assert([fm fileExistsAtPath:[sanitized.path stringByAppendingPathComponent:@"A_B/Albums/X_Y/First.ogg"]]);
 NSArray *safePaths=[fm subpathsAtPath:sanitized.path];NSUInteger safeCount=0;
 for(NSString *path in safePaths){assert(![path containsString:@"../"]);if([path.pathExtension isEqual:@"m4a"]||[path.pathExtension isEqual:@"ogg"])safeCount++;}
 assert(safeCount==4);SAPReleaseOfflineLibraryPackage(sanitized);
 // Display labels cannot merge distinct artist/release identities from the catalog.
 NSMutableDictionary *entity1=[Track(a,@"entity1",@"First release",@"Same Artist",@"Same Release",1)mutableCopy];entity1[@"artist_uri"]=@"spotify:artist:A";entity1[@"album_uri"]=@"spotify:album:A1";
 NSMutableDictionary *entity2=[Track(a,@"entity2",@"Second release",@"Same Artist",@"Same Release",1)mutableCopy];entity2[@"artist_uri"]=@"spotify:artist:A";entity2[@"album_uri"]=@"spotify:album:A2";
 NSMutableDictionary *entity3=[Track(b,@"entity3",@"Other artist",@"Same Artist",@"Same Release",1)mutableCopy];entity3[@"artist_uri"]=@"spotify:artist:B";entity3[@"album_uri"]=@"spotify:album:B1";
 NSURL *entityGroups=Prepare(@[entity3,entity2,entity1],NO,NO,&error);assert(entityGroups&&!error);
 assert([[fm contentsOfDirectoryAtPath:entityGroups.path error:NULL]count]==2);
 assert([fm fileExistsAtPath:[entityGroups.path stringByAppendingPathComponent:@"Same Artist/Albums/Same Release/First release.m4a"]]);
 assert([fm fileExistsAtPath:[entityGroups.path stringByAppendingPathComponent:@"Same Artist/Albums/Same Release (2)/Second release.m4a"]]);
 assert([fm fileExistsAtPath:[entityGroups.path stringByAppendingPathComponent:@"Same Artist (2)/Albums/Same Release/Other artist.ogg"]]);
 SAPReleaseOfflineLibraryPackage(entityGroups);
 // Track/disc metadata never becomes a filename prefix, including numbers above 99.
 NSURL *wideNumbers=Prepare(@[Track(a,@"wide1",@"Before",@"Artist",@"Long Album",99),Track(a,@"wide2",@"After",@"Artist",@"Long Album",100),Track(a,@"wide3",@"99",@"Artist",@"Long Album",3)],NO,NO,&error);assert(wideNumbers&&!error);
 assert([fm fileExistsAtPath:[wideNumbers.path stringByAppendingPathComponent:@"Before.m4a"]]);
 assert([fm fileExistsAtPath:[wideNumbers.path stringByAppendingPathComponent:@"After.m4a"]]);
 assert([fm fileExistsAtPath:[wideNumbers.path stringByAppendingPathComponent:@"99.m4a"]]);SAPReleaseOfflineLibraryPackage(wideNumbers);
 // Same extension and title still produce two distinct names by track identity.
 NSURL *collisions=Prepare(@[Track(a,@"one",@"Same",@"Artist",@"Album",1),Track(a,@"two",@"Same",@"Artist",@"Album",1)],NO,NO,&error);assert(collisions&&!error);
 assert([[fm contentsOfDirectoryAtPath:collisions.path error:NULL]count]==2);SAPReleaseOfflineLibraryPackage(collisions);
 NSString *longTitle=[@"空" stringByPaddingToLength:200 withString:@"空" startingAtIndex:0];
 NSURL *longCollision=Prepare(@[Track(a,@"one",longTitle,@"Artist",@"Album",1),Track(a,@"two",longTitle,@"Artist",@"Album",1)],NO,NO,&error);assert(longCollision&&!error);
 BOOL hasIdentity=NO;for(NSString *name in [fm contentsOfDirectoryAtPath:longCollision.path error:NULL])if([name hasSuffix:@" [two].m4a"])hasIdentity=YES;
 assert(hasIdentity);SAPReleaseOfflineLibraryPackage(longCollision);
 // One release is named after that release and has no redundant artist/category levels.
 NSArray *oneRelease=@[Track(a,@"flat1",@"First",@"Artist",@"Chosen Album",1),Track(b,@"flat2",@"Second",@"Artist",@"Chosen Album",2)];
 for(NSNumber *archive in @[@NO,@YES]) {
  NSURL *flat=Prepare(oneRelease,archive.boolValue,NO,&error);assert(flat&&!error);
  assert([flat.lastPathComponent isEqual:archive.boolValue?@"Chosen Album.zip":@"Chosen Album"]);
  if(archive.boolValue){if(argc>2)assert([fm copyItemAtURL:flat toURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]] error:NULL]);}
  else {assert([[fm subpathsAtPath:flat.path]count]==2);assert([fm fileExistsAtPath:[flat.path stringByAppendingPathComponent:@"First.m4a"]]);}
  SAPReleaseOfflineLibraryPackage(flat);
 }
 NSMutableDictionary *singleRow=[Track(a,@"s",@"Single song",@"Artist",@"A Single",1)mutableCopy];singleRow[@"category"]=@"Singles";
 NSMutableDictionary *epRow=[Track(a,@"e",@"EP song",@"Artist",@"An EP",1)mutableCopy];epRow[@"category"]=@"EPs";
 NSURL *typed=Prepare(@[oneRelease[0],singleRow,epRow],NO,NO,&error);assert(typed&&!error);
 for(NSString *path in @[@"Artist/Albums/Chosen Album/First.m4a",@"Artist/Singles/A Single/Single song.m4a",@"Artist/EPs/An EP/EP song.m4a"])assert([fm fileExistsAtPath:[typed.path stringByAppendingPathComponent:path]]);
 SAPReleaseOfflineLibraryPackage(typed);
 NSMutableDictionary *collab1=[Track(a,@"c1",@"Together",@"Artist A",@"Collaboration",1)mutableCopy];collab1[@"album_uri"]=@"spotify:album:shared";
 NSMutableDictionary *collab2=[Track(b,@"c2",@"Again",@"Artist B",@"Collaboration",2)mutableCopy];collab2[@"album_uri"]=@"spotify:album:shared";
 NSURL *collab=Prepare(@[collab1,collab2],NO,NO,&error);assert(collab&&!error);assert([collab.lastPathComponent isEqual:@"Collaboration"]);assert([[fm subpathsAtPath:collab.path]count]==2);SAPReleaseOfflineLibraryPackage(collab);
 // A collaboration must remain one release even when another release is exported too.
 for(NSArray *selection in @[@[collab2,oneRelease[0],collab1],@[collab1,oneRelease[0],collab2]]) {
  NSURL *mixed=Prepare(selection,NO,NO,&error);assert(mixed&&!error);assert([mixed.lastPathComponent isEqual:@"Music"]);
  assert([fm fileExistsAtPath:[mixed.path stringByAppendingPathComponent:@"Artist A/Albums/Collaboration/Together.m4a"]]);
  assert([fm fileExistsAtPath:[mixed.path stringByAppendingPathComponent:@"Artist A/Albums/Collaboration/Again.ogg"]]);
  assert(![fm fileExistsAtPath:[mixed.path stringByAppendingPathComponent:@"Artist B"]]);SAPReleaseOfflineLibraryPackage(mixed);
 }
 NSURL *zip=Prepare(tracks,YES,NO,&error);assert(zip&&!error);assert([zip.lastPathComponent isEqual:@"Music.zip"]);
 if(argc>1) assert([fm copyItemAtURL:zip toURL:[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]] error:NULL]);
 NSString *zipPath=[zip.path copy];SAPReleaseOfflineLibraryPackage(zip);assert(![fm fileExistsAtPath:zipPath]);
 NSURL *cancelled=Prepare(tracks,YES,YES,&error);assert(!cancelled&&error.code==NSUserCancelledError);
 NSURL *bad=Prepare(@[Track([root URLByAppendingPathComponent:@"library.sqlite"],@"bad",@"bad",@"Artist",@"Album",1)],NO,NO,&error);assert(!bad&&error);
 NSURL *link=[root URLByAppendingPathComponent:@"link.m4a"];assert(!symlink(a.path.fileSystemRepresentation,link.path.fileSystemRepresentation));
 assert(!Prepare(@[Track(link,@"link",@"bad",@"Artist",@"Album",1)],NO,NO,&error)&&error);
 NSURL *linkedDirectory=[root URLByAppendingPathComponent:@"linked-dir"];
 assert(!symlink(root.path.fileSystemRepresentation,linkedDirectory.path.fileSystemRepresentation));
 assert(!Prepare(@[Track([linkedDirectory URLByAppendingPathComponent:@"a.m4a"],@"ancestor-link",@"bad",@"Artist",@"Album",1)],NO,NO,&error)&&error);
 assert(!Prepare(@[tracks.firstObject,Track([root URLByAppendingPathComponent:@"missing.m4a"],@"missing",@"Missing",@"Artist",@"Album",1)],NO,NO,&error)&&error);
 TestStreamingCancellation(root);
 assert([ScratchRoots()isEqual:initialScratch]);
 assert([fm fileExistsAtPath:a.path]&&[fm fileExistsAtPath:b.path]&&[fm fileExistsAtPath:[root.path stringByAppendingPathComponent:@"library.sqlite"]]);
 // ARC lifetime cleanup without the explicit consumer release function.
 __block NSString *automaticPath=nil;
 @autoreleasepool {NSURL *automatic=Prepare(tracks,NO,NO,&error);assert(automatic);automaticPath=[automatic.path copy];}
 // Completion blocks run in a main-queue autorelease pool, which must drain.
 for(NSUInteger n=0;n<10&&[fm fileExistsAtPath:automaticPath];n++)[[NSRunLoop currentRunLoop]runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
 assert(![fm fileExistsAtPath:automaticPath]);
 [fm removeItemAtURL:root error:NULL];puts("PASS offline package hierarchy, identity collisions, hardlinks, ZIP, cancel, validation, input preservation, leases");
 }return 0;}
