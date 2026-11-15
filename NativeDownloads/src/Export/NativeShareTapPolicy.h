#pragma once
#import <Foundation/Foundation.h>
typedef NS_ENUM(NSUInteger,SAPNativeShareIntent){SAPNativeShareNone,SAPNativeShareCopy,SAPNativeShareMessage,SAPNativeShareMore};
static inline SAPNativeShareIntent SAPShareIntentFromLabel(NSString *label){
 if(![label isKindOfClass:NSString.class]||label.length>256)return SAPNativeShareNone;
 NSArray *words=[label.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];NSMutableArray *nonempty=[NSMutableArray array];for(NSString *word in words)if(word.length)[nonempty addObject:word];NSString *text=[nonempty componentsJoinedByString:@" "];
 if([@[@"copy link",@"copy file",@"скопировать ссылку",@"скопировать файл",@"копировать ссылку",@"copia link",@"copiar enlace",@"link kopieren",@"copier le lien",@"copylink"]containsObject:text])return SAPNativeShareCopy;
 if([@[@"more",@"больше",@"ещё",@"еще",@"altro",@"más",@"mehr",@"plus",@"nativesharemenu"]containsObject:text])return SAPNativeShareMore;
 if([@[@"message",@"messages",@"сообщение",@"сообщения",@"messaggi",@"mensajes",@"nachrichten",@"sms"]containsObject:text])return SAPNativeShareMessage;
 return SAPNativeShareNone;
}
static inline BOOL SAPShareTapAllowed(BOOL enabled,BOOL visible,BOOL suspended,BOOL sameEntity){return enabled&&visible&&!suspended&&sameEntity;}

static inline BOOL SAPShareShouldPrepare(BOOL enabled,SAPNativeShareIntent intent,BOOL busy,BOOL ready){return enabled&&intent!=SAPNativeShareNone&&!busy&&!ready;}

static inline BOOL SAPShareCellMatchesAction(NSArray<NSString *> *labels,SAPNativeShareIntent action){
 if(action==SAPNativeShareNone)return NO;BOOL found=NO;
 for(NSString *label in labels){if(![label isKindOfClass:NSString.class])return NO;if(![label stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)continue;if(SAPShareIntentFromLabel(label)!=action)return NO;found=YES;}return found;
}
