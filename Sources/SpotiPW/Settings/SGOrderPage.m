#import "SGOrderPage.h"
#import "SGPage.h"
#import "SGPageStyle.h"

@implementation SGOrderItem
@end

SGOrderItem *SGOrderItemMake(NSString *key, NSString *name, NSString *detail) {
    SGOrderItem *item = [SGOrderItem new];
    item.key = key;
    item.name = name;
    item.detail = detail;
    return item;
}

typedef NS_ENUM(NSInteger, SGOrderSection) {
    SGOrderSectionOn = 0,
    SGOrderSectionOff,
    SGOrderSectionCount,
};

@interface SGOrderController : SGPage
@property (nonatomic, copy) NSArray<SGOrderItem *> *items;
@property (nonatomic, copy) NSArray<NSString *> *(^read)(void);
@property (nonatomic, copy) void (^write)(NSArray<NSString *> *order);
@property (nonatomic, copy) NSString *note;
@end

@implementation SGOrderController {
    NSMutableArray<NSString *> *_on;    // keys, in the order they are asked
    NSMutableArray<NSString *> *_off;
    UIView *_footer;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (SGOrderItem *)itemFor:(NSString *)key {
    for (SGOrderItem *item in self.items) {
        if ([item.key isEqualToString:key]) return item;
    }
    return nil;
}

- (void)load {
    _on = [NSMutableArray array];
    for (NSString *key in self.read()) {
        if ([self itemFor:key]) [_on addObject:key];
    }
    _off = [NSMutableArray array];
    for (SGOrderItem *item in self.items) {
        if (![_on containsObject:item.key]) [_off addObject:item.key];
    }
}

- (void)save {
    self.write(_on);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self load];
    self.tableView.editing = YES;
    self.tableView.allowsSelectionDuringEditing = YES;
    _footer = SGNote(self.note);
    self.tableView.tableFooterView = _footer;
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    SGFitNote(self.tableView, _footer, 16, 24);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (NSMutableArray<NSString *> *)keysIn:(NSInteger)section {
    return section == SGOrderSectionOn ? _on : _off;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {
    return SGOrderSectionCount;
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self keysIn:section].count;
}

- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    if (section == SGOrderSectionOn) return SGSectionHeader(table, _on.count ? @"Asked in this order" : @"None on");
    return _off.count ? SGSectionHeader(table, @"Off") : nil;
}

- (CGFloat)tableView:(UITableView *)table heightForHeaderInSection:(NSInteger)section {
    return section == SGOrderSectionOn || _off.count ? SGSectionHeaderHeight : CGFLOAT_MIN;
}

- (CGFloat)tableView:(UITableView *)table heightForFooterInSection:(NSInteger)section {
    return CGFLOAT_MIN;
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"source");
    SGOrderItem *item = [self itemFor:[self keysIn:path.section][(NSUInteger)path.row]];
    BOOL on = path.section == SGOrderSectionOn;
    // The asked ones are numbered, so the order reads as an order rather than a list.
    NSString *title = on ? [NSString stringWithFormat:@"%ld. %@", (long)path.row + 1, item.name] : item.name;
    SGFillCell(cell, title, item.detail, on ? nil : SGGrey(), on ? @"checkmark.circle.fill" : @"circle");
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (BOOL)tableView:(UITableView *)table canMoveRowAtIndexPath:(NSIndexPath *)path {
    return path.section == SGOrderSectionOn;
}

- (BOOL)tableView:(UITableView *)table canEditRowAtIndexPath:(NSIndexPath *)path {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)table editingStyleForRowAtIndexPath:(NSIndexPath *)path {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)table shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)path {
    return NO;
}

// Dragging stays inside the order; a source is switched on and off by tapping it, not by dropping
// it into the other section, so an order is never lost to a stray drag.
- (NSIndexPath *)tableView:(UITableView *)table targetIndexPathForMoveFromRowAtIndexPath:(NSIndexPath *)from toProposedIndexPath:(NSIndexPath *)to {
    return to.section == SGOrderSectionOn ? to : from;
}

- (void)tableView:(UITableView *)table moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *key = _on[(NSUInteger)from.row];
    [_on removeObjectAtIndex:(NSUInteger)from.row];
    [_on insertObject:key atIndex:(NSUInteger)to.row];
    [self save];
    [table reloadData];   // the numbers in front of the names have all moved
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    NSString *key = [self keysIn:path.section][(NSUInteger)path.row];
    if (path.section == SGOrderSectionOn) {
        [_on removeObject:key];
        // Back to where it sits among the sources that are off, in the order they all come in.
        NSUInteger at = 0;
        for (SGOrderItem *item in self.items) {
            if ([item.key isEqualToString:key]) break;
            if ([_off containsObject:item.key]) at++;
        }
        [_off insertObject:key atIndex:at];
    } else {
        [_off removeObject:key];
        [_on addObject:key];
    }
    [self save];
    [table reloadData];
}

@end

UIViewController *SGOrderPage(NSString *title, NSArray<SGOrderItem *> *items, NSArray<NSString *> *(^read)(void),
                              void (^write)(NSArray<NSString *> *order), NSString *note) {
    SGOrderController *page = [SGOrderController new];
    page.title = title;
    page.items = items;
    page.read = read;
    page.write = write;
    page.note = note;
    return page;
}
