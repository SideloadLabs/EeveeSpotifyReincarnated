// Where a track's Canvas comes from, as plain data: the hook tests these without the app around them.
#import <Foundation/Foundation.h>

@interface SGCanvas : NSObject
@property (nonatomic, copy) NSString *identifier;   // canvas.id, the file id where there is none
@property (nonatomic, copy) NSString *address;      // the clip's URL
@property (nonatomic) BOOL video;                   // an IMAGE or GIF canvas is not one of ours
@end

// Spotify's core writes canvas.id, canvas.url, canvas.fileId and canvas.type into the played track's
// metadata, the type spelled IMAGE, VIDEO, VIDEO_LOOPING, VIDEO_LOOPING_RANDOM or GIF.
SGCanvas *SGCanvasFromMetadata(NSDictionary *metadata);

// spotify.canvaz.cache, the service Spotify's own canvases come from: the body asking for one track,
// and the canvas its answer carries back. Type 1, 2 and 3 of its enum are the video ones.
NSData *SGCanvazRequestBody(NSString *trackURI);
SGCanvas *SGCanvazFromBody(NSData *body);
