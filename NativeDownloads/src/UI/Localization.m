#import "Localization.h"
#import <dlfcn.h>

NSString *SAPLocalized(NSString *key) {
    // Eevee may load after Pixie, so a missing lookup is asked for again.
    static NSString *(*lookup)(NSString *);
    if (!lookup) lookup = dlsym(RTLD_DEFAULT, "EeveeLocalizedString");
    return lookup && key.length ? lookup(key) : key;
}

NSString *SAPLocalizedValue(NSString *value) {
    static NSDictionary<NSString *, NSString *> *keys;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        keys = @{
            @"Album": @"album",
            @"Albums": @"albums",
            @"Another export is already running.": @"another_export_is_already_running",
            @"Appears on": @"appears_on",
            @"Audio export cancelled.": @"audio_export_cancelled",
            @"Compilations": @"compilations",
            @"Download in progress": @"download_in_progress",
            @"EPs": @"eps",
            @"Malformed native offline context": @"malformed_native_offline_context",
            @"Malformed native offline item identity": @"malformed_native_offline_item_identity",
            @"Metadata unavailable": @"metadata_unavailable",
            @"Mode 0 is verified in the executable. This status does not confirm download authorization.": @"mode_0_is_verified_in_the",
            @"Mode 1 is verified in the executable. This status does not confirm download authorization.": @"mode_1_is_verified_in_the",
            @"Native offline context enumeration failed": @"native_offline_context_enumeration_failed",
            @"Native offline context identity missing": @"native_offline_context_identity_missing",
            @"Native offline item validation failed": @"native_offline_item_validation_failed",
            @"Native offline item validation omitted requested tracks": @"native_offline_item_validation_omitted_requested",
            @"Native offline item validation returned inconsistent identities": @"native_offline_item_validation_returned_inconsistent",
            @"Only restoring a confirmed mode 1 to mode 0 is allowed. A saved preference alone is not confirmation.": @"only_restoring_a_confirmed_mode_1",
            @"Playlist": @"playlist_2",
            @"Playlist contents are still loading.": @"playlist_contents_are_still_loading",
            @"Preparing cover artwork…": @"preparing_cover_artwork",
            @"Release": @"release",
            @"Remove": @"remove",
            @"Singles": @"singles",
            @"Singles & EPs": @"singles_eps",
            @"Spotify device": @"spotify_device",
            @"The installed request mode cannot be verified. Changes are disabled.": @"the_installed_request_mode_cannot_be",
            @"The playlist changed while being read. Retry to use its current contents.": @"the_playlist_changed_while_being_read",
            @"The verified selector returned 1. Restoring mode 0 is available. Download authorization is separate.": @"the_verified_selector_returned_1_restoring",
            @"Track": @"track",
            @"Unknown artist": @"unknown_artist",
        };
    });
    return SAPLocalized(keys[value] ?: value);
}
