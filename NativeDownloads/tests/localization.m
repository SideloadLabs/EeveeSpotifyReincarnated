#import "Localization.h"
#include <assert.h>

// What Eevee exports (`.localized`): the app's language, then English, then the key itself.
__attribute__((visibility("default"), used))
NSString *EeveeLocalizedString(NSString *key) {
    static NSBundle *bundle, *english;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleWithURL:[NSBundle.mainBundle URLForResource:@"EeveeSpotify" withExtension:@"bundle"]];
        english = [NSBundle bundleWithPath:[bundle pathForResource:@"en" ofType:@"lproj"]];
    });
    NSString *value = [bundle localizedStringForKey:key value:nil table:nil];
    if (![value isEqualToString:key]) return value;
    return [english localizedStringForKey:key value:key table:nil];
}

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc > 1);
        BOOL russian = [[NSString stringWithUTF8String:argv[1]] isEqualToString:@"ru"];
        assert([SAPLocalized(@"pixie_download_manager") isEqualToString:
                (russian ? @"Менеджер загрузок Pixie" : @"Pixie Download Manager")]);
        assert([SAPLocalized(@"download_missing_lyrics") isEqualToString:
                (russian ? @"Скачать недостающие тексты" : @"Download missing lyrics")]);
        NSString *progress = [NSString stringWithFormat:SAPLocalized(@"downloading_lyrics"), 3UL, 12UL];
        assert([progress isEqualToString:
                (russian ? @"Скачивание текстов · 3 / 12" : @"Downloading lyrics · 3 / 12")]);
        // Key request mode details come from the adapter in English.
        NSString *mode = @"Mode 0 is verified in the executable. This status does not confirm download authorization.";
        assert([SAPLocalizedValue(mode) isEqualToString:
                (russian ? @"Режим 0 подтверждён в исполняемом файле. Это не подтверждает разрешение на загрузку." : mode)]);
        assert([SAPLocalizedValue(@"Singles & EPs") isEqualToString:(russian ? @"Синглы и мини-альбомы" : @"Singles & EPs")]);
        // A value already translated, or one without a translation, is shown as it is.
        assert([SAPLocalizedValue(@"Some provider error") isEqualToString:@"Some provider error"]);
        assert([SAPLocalized(@"unknown_translation_key") isEqualToString:@"unknown_translation_key"]);
        puts("Pixie language, formatting, values and missing-key fallback passed");
    }
}
