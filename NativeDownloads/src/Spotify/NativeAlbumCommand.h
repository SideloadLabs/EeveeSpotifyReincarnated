#pragma once
#import <Foundation/Foundation.h>

// Invokes the current native manager method once with NSURL arguments, as the
// album UI does. YES means the void handler returned, not download completion.
BOOL SAPInvokeNativeAlbumCommand(id manager,NSString *albumURI,NSArray<NSString *> *trackURIs,NSString **reason);
