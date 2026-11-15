#pragma once
#import <UIKit/UIKit.h>
// Installs the artist-page download button hooks (idempotent; retries until the page class is registered).
void SAPInstallArtistPageButton(void);
// Used by Eevee's Liquid Glass action row (resolved with dlsym): the row owns the button and the
// companion keeps its state and tap handling.
__attribute__((visibility("default"))) void SAPUpdateArtistDownloadsExternal(UIView *header, UIButton *_Nullable externalButton);
__attribute__((visibility("default"))) NSString *_Nullable SAPArtistURIForHeader(UIView *header);
