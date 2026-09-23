// A page of sources dragged into the order they are asked in; tapping one moves it below the line, off.
#import <UIKit/UIKit.h>

@interface SGOrderItem : NSObject
@property (nonatomic, copy) NSString *key;      // stored in the order, never shown
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;   // one line under the name
@end

SGOrderItem *SGOrderItemMake(NSString *key, NSString *name, NSString *detail);

// `items` in the order a fresh install asks them; `read` answers the keys switched on, in order, and
// `write` stores a new one. `note` sits under the list.
UIViewController *SGOrderPage(NSString *title, NSArray<SGOrderItem *> *items, NSArray<NSString *> *(^read)(void),
                              void (^write)(NSArray<NSString *> *order), NSString *note);
