#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A key of EeveeSpotify.bundle's Localizable.strings, translated as `.localized` translates
// it in the rest of the mod (Eevee does the lookup). Without Eevee the key comes back.
NSString *SAPLocalized(NSString *key);

// A value Pixie keeps in English (release categories, item kinds, some errors), translated
// when shown. Any other value is taken as a key.
NSString *SAPLocalizedValue(NSString *value);

NS_ASSUME_NONNULL_END
