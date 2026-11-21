#pragma once
#import <Foundation/Foundation.h>

// Passive sidecar: never changes the audio command or waits for a lyrics provider.
void SAPRequestOfflineLyrics(NSString *uri, NSArray *trackURLs);

// Removes only the app-owned lyrics sidecar; audio deletion stays with Spotify.
void SAPRemoveOfflineLyrics(NSString *uri, NSArray *trackURLs);

// Minimal identity-checked metadata for provider searches, independent of the
// manually refreshed downloaded-library snapshot. Completion runs on main.
__attribute__((visibility("default")))
void SAPFetchOfflineLyricsMetadata(NSString *trackURI, void (^completion)(NSDictionary *metadata));
