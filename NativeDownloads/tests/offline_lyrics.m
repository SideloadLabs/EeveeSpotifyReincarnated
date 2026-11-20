#import <Foundation/Foundation.h>
#import "OfflineLyrics.h"
#import "WireProto.h"

// Presence of the Swift sidecar is the opt-in gate in production.
@interface EeveeOfflineLyricsDownloader : NSObject @end
@implementation EeveeOfflineLyricsDownloader @end

static NSString *const track=@"spotify:track:0123456789ABCDEFGHIJKL";
static NSUInteger albums,playlists;
static BOOL holdAlbum;
static void (^albumReply)(NSArray *,NSString *);
static NSUInteger metadataCalls;
static NSUInteger metadataMode;
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service,NSString *method,NSData *payload,void (^reply)(NSData *,NSString *)) {
    NSCAssert([service isEqual:@"spotify.metadata_esperanto.proto.ClassicMetadataService"] && [method isEqual:@"GetEntity"],@"Lyrics must use the native track metadata service");
    NSString *uri=SAPProtoString(SAPProtoFields(payload),1);metadataCalls++;
    uint8_t gid[16]={0};const char *abc="0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    for(NSUInteger i=14;i<uri.length;i++){
        unsigned carry=(unsigned)(strchr(abc,[uri characterAtIndex:i])-abc);
        for(NSInteger j=15;j>=0;j--){unsigned v=gid[j]*62+carry;gid[j]=v&255;carry=v>>8;}
    }
    if(metadataMode==1)gid[15]^=1;
    NSMutableData *entity=[SAPProtoBytes(1,[NSData dataWithBytes:gid length:16])mutableCopy];
    [entity appendData:SAPProtoBytes(2,[@"New track" dataUsingEncoding:NSUTF8StringEncoding])];
    if(metadataMode!=2)[entity appendData:SAPProtoBytes(4,SAPProtoBytes(2,[@"New artist" dataUsingEncoding:NSUTF8StringEncoding]))];
    NSMutableData *item=[SAPProtoBytes(4,entity)mutableCopy];
    if(metadataMode==3)[item appendData:SAPProtoInteger(1,5)];
    NSData *response=SAPProtoBytes(1,item);BOOL transportError=metadataMode==4;
    dispatch_async(dispatch_get_main_queue(),^{reply(transportError?nil:response,transportError?@"offline":nil);});
    return ^{};
}
void SAPFetchArtistAlbumTrackURIs(NSString *uri,void (^completion)(NSArray *,NSString *)) {
    albums++;
    if (holdAlbum) albumReply=[completion copy];
    else completion(@[track],nil);
}
dispatch_block_t SAPPlaylistReadList(NSString *uri,void (^completion)(id,NSString *)) {
    playlists++; completion(@{@"items":@[track,@"spotify:episode:0123456789ABCDEFGHIJKL"]},nil); return ^{};
}
int main(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"PixieOfflineLyricsEnabled"];
        __block NSUInteger received=0;
        __block NSTimeInterval publishedAt=0;
        id observer=[NSNotificationCenter.defaultCenter addObserverForName:@"EeveeOfflineLyricsRequested" object:nil queue:nil usingBlock:^(NSNotification *note){
            NSCAssert([note.userInfo[@"requested_at"]doubleValue]>0,@"A late membership reply must retain its original request time");
            publishedAt=[note.userInfo[@"requested_at"]doubleValue];
            NSArray *tracks=note.userInfo[@"tracks"];
            NSCAssert([tracks isEqual:@[track]],@"Only exact track identities should be delivered");received++;
        }];
        SAPRequestOfflineLyrics(track,nil);
        SAPRequestOfflineLyrics(@"spotify:album:0123456789ABCDEFGHIJKL",nil);
        SAPRequestOfflineLyrics(@"spotify:playlist:0123456789ABCDEFGHIJKL",nil);
        SAPRequestOfflineLyrics(@"spotify:album:0123456789ABCDEFGHIJKL",@[[NSURL URLWithString:track],@"invalid"]);
        SAPRequestOfflineLyrics(@"spotify:track:../escape",nil);
        NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
        while(received<4 && deadline.timeIntervalSinceNow>0)
            [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        NSCAssert(received==4 && albums==1 && playlists==1,@"Track, explicit membership and native context paths must all deliver lyrics work");
        __block NSUInteger metadataReplies=0;
        void (^metadataReply)(NSDictionary *)=^(NSDictionary *row){
            NSCAssert(NSThread.isMainThread && [row[@"name"]isEqual:@"New track"] && [row[@"artist_name"]isEqual:@"New artist"],@"A fresh URI-only download needs native title and artist without a library scan");metadataReplies++;
        };
        SAPFetchOfflineLyricsMetadata(track,metadataReply);SAPFetchOfflineLyricsMetadata(track,metadataReply);
        deadline=[NSDate dateWithTimeIntervalSinceNow:2];
        while(metadataReplies<2 && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        NSCAssert(metadataReplies==2 && metadataCalls==1,@"Concurrent requests must share the native read");
        SAPFetchOfflineLyricsMetadata(track,metadataReply);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        NSCAssert(metadataReplies==3 && metadataCalls==1,@"Verified metadata should be cached");
        for(metadataMode=1;metadataMode<=4;metadataMode++){
            NSString *uri=[NSString stringWithFormat:@"spotify:track:%022lu",(unsigned long)metadataMode];__block BOOL done=NO;
            SAPFetchOfflineLyricsMetadata(uri,^(NSDictionary *row){NSCAssert(!row,@"Mismatch, incomplete metadata and native errors must not be accepted");done=YES;});
            deadline=[NSDate dateWithTimeIntervalSinceNow:2];
            while(!done && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
            NSCAssert(done,@"Metadata read never completed");
        }
        metadataMode=0;__block BOOL retried=NO;
        SAPFetchOfflineLyricsMetadata(@"spotify:track:0000000000000000000001",^(NSDictionary *row){NSCAssert(row,@"Failures must not poison the metadata cache");retried=YES;});
        deadline=[NSDate dateWithTimeIntervalSinceNow:2];
        while(!retried && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
        NSCAssert(retried,@"Metadata retry never completed");
        __block NSUInteger began=0,resolved=0;
        id deletion=[NSNotificationCenter.defaultCenter addObserverForName:@"EeveeOfflineLyricsRemoved" object:nil queue:nil usingBlock:^(NSNotification *note){
            NSCAssert([note.userInfo[@"token"]length]>0,@"Deletion needs an identity to reject stale native replies");
            if([note.userInfo[@"phase"]isEqual:@"begin"])began++;
            else {NSCAssert([note.userInfo[@"tracks"]isEqual:@[track]],@"Resolved removal must contain only tracks");resolved++;}
        }];
        SAPRemoveOfflineLyrics(track,nil);
        SAPRemoveOfflineLyrics(@"spotify:album:0123456789ABCDEFGHIJKL",nil);
        SAPRemoveOfflineLyrics(@"spotify:playlist:0123456789ABCDEFGHIJKL",nil);
        deadline=[NSDate dateWithTimeIntervalSinceNow:2];
        while((began<3 || resolved<2) && deadline.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
        NSCAssert(began==3 && resolved==2,@"Direct and context removal were not delivered");
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"PixieOfflineLyricsEnabled"];
        SAPRequestOfflineLyrics(track,nil);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.03]];
        NSCAssert(received==4,@"Disabled downloading still enqueued work");
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"PixieOfflineLyricsEnabled"];
        // A second download after Cancel shares the outstanding membership read.
        holdAlbum=YES;
        NSString *album=@"spotify:album:0123456789ABCDEFGHIJKL";
        NSUInteger beforeReads=albums;
        SAPRequestOfflineLyrics(album,nil);
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        NSCAssert(albumReply,@"Expected pending album read");
        NSTimeInterval cancelledAt=NSDate.date.timeIntervalSince1970;
        SAPRequestOfflineLyrics(album,nil);
        dispatch_async(dispatch_get_main_queue(),^{albumReply(@[track],nil);albumReply=nil;});
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.03]];
        NSCAssert(received==5 && albums==beforeReads+1 && publishedAt>=cancelledAt,
                  @"A new download inherited the cancelled request time or repeated the album read");
        [NSNotificationCenter.defaultCenter removeObserver:deletion];
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        puts("Offline lyrics native bridge tests passed");
    }
}
