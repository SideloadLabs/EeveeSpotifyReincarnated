#import "Localization.h"
#include <assert.h>

int main(int argc, char **argv) {
    @autoreleasepool {
        assert(argc > 1);
        BOOL russian = [[NSString stringWithUTF8String:argv[1]] isEqualToString:@"ru"];
        assert([SAPLocalized(@"Pixie Download Manager") isEqualToString:
                (russian ? @"Менеджер загрузок Pixie" : @"Pixie Download Manager")]);
        assert([SAPLocalized(@"Download missing lyrics") isEqualToString:
                (russian ? @"Скачать недостающие тексты" : @"Download missing lyrics")]);
        NSString *progress = [NSString stringWithFormat:SAPLocalized(@"Downloading lyrics · %lu / %lu"), 3UL, 12UL];
        assert([progress isEqualToString:
                (russian ? @"Скачивание текстов · 3 / 12" : @"Downloading lyrics · 3 / 12")]);
        assert([SAPLocalized(@"Unknown translation key") isEqualToString:@"Unknown translation key"]);
        puts("Pixie language, formatting, and missing-key fallback passed");
    }
}
