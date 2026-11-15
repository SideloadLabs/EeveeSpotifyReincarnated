#pragma once
#import <UIKit/UIKit.h>

@interface SAPPlaylistPickerController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,copy) void (^onChoose)(NSDictionary *,UIViewController *);
@end
