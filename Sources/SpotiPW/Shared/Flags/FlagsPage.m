#import "Core/SGCore.h"
#import "Settings/SGPage.h"
#import "Settings/SGPageStyle.h"
#import "Flags.h"

static NSString *flagState(const SGFlagDef *flag, id value) {
    if (value) return [NSString stringWithFormat:@"forced %@", flag->type == SGFlagBool ? ([value boolValue] ? @"on" : @"off") : value];
    switch (flag->type) {
        case SGFlagBool: return flag->value ? @"on by default" : @"off by default";
        case SGFlagInt: return [NSString stringWithFormat:@"%ld by default, %ld to %ld", flag->value, flag->lower, flag->upper];
        case SGFlagEnum: return @"text value";
        default: return @"type unknown";
    }
}

// Every flag in SGFlagTable, filtered by the search words; forced flags first while the search
// is empty. Bool flags get an Auto / Off / On control, the others a text field in an alert.
@interface SGFlagsPage : SGPage <UISearchBarDelegate>
@end

@implementation SGFlagsPage {
    NSArray<NSNumber *> *_shown;
    NSDictionary<NSString *, id> *_overrides;
    UISearchBar *_search;
    UIView *_header;
}

- (instancetype)init {
    if (!(self = [super initWithStyle:UITableViewStylePlain])) return nil;
    self.title = @"Flags";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _search = [UISearchBar new];
    _search.placeholder = [NSString stringWithFormat:@"Search %lu flags", (unsigned long)SGFlagCount];
    _search.searchBarStyle = UISearchBarStyleMinimal;
    _search.delegate = self;
    _header = SGNote(@"Auto keeps Spotify's value. Changes apply after you restart Spotify.");
    [_header addSubview:_search];
    self.tableView.tableHeaderView = _header;
    [self reload];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    _search.frame = CGRectMake(8, 4, self.tableView.bounds.size.width - 16, 44);
    SGFitNote(self.tableView, _header, 52, 8);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGInsetForBars(self.tableView);
}

- (void)reload {
    NSMutableDictionary *overrides = [NSMutableDictionary dictionary];
    NSDictionary *defaults = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    for (NSString *key in defaults) {
        if ([key hasPrefix:SGFlagOverridePrefix]) overrides[[key substringFromIndex:SGFlagOverridePrefix.length]] = defaults[key];
    }
    NSArray<NSString *> *words = [_search.text.lowercaseString componentsSeparatedByString:@" "];
    NSMutableArray *forced = [NSMutableArray array], *rest = [NSMutableArray array];
    for (NSUInteger i = 0; i < SGFlagCount; i++) {
        NSString *key = @(SGFlagTable[i].key);
        BOOL match = YES;
        for (NSString *word in words) match = match && (!word.length || [key containsString:word]);
        if (match) [overrides[key] ? forced : rest addObject:@(i)];
    }
    _overrides = overrides;
    _shown = [forced arrayByAddingObjectsFromArray:rest];
    [self.tableView reloadData];
}

- (void)searchBar:(UISearchBar *)bar textDidChange:(NSString *)text {
    [self reload];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)bar {
    [bar resignFirstResponder];
}

- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_shown.count;
}

- (const SGFlagDef *)flagAt:(NSInteger)row {
    return &SGFlagTable[_shown[(NSUInteger)row].unsignedIntegerValue];
}

- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell = SGDequeueCell(table, @"flag");
    const SGFlagDef *flag = [self flagAt:path.row];
    NSString *key = @(flag->key);
    NSUInteger dot = [key rangeOfString:@"."].location;
    id value = _overrides[key];

    SGFillCell(cell, [key substringFromIndex:dot + 1],
             [NSString stringWithFormat:@"%@ · %@", [key substringToIndex:dot], flagState(flag, value)],
             value ? SGGreen() : nil, nil);
    cell.backgroundColor = UIColor.clearColor;
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (flag->type == SGFlagBool) {
        UISegmentedControl *control = [[UISegmentedControl alloc] initWithItems:@[@"Auto", @"Off", @"On"]];
        control.selectedSegmentIndex = value ? ([value boolValue] ? 2 : 1) : 0;
        control.selectedSegmentTintColor = SGGreen();
        [control setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor, NSFontAttributeName: SGSubtitleFont()} forState:UIControlStateNormal];
        control.tag = path.row;
        [control addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
        [control sizeToFit];
        cell.accessoryView = control;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return cell;
}

- (void)segmentChanged:(UISegmentedControl *)control {
    NSString *key = @([self flagAt:control.tag]->key);
    NSInteger index = control.selectedSegmentIndex;
    [self store:index == 0 ? nil : @(index == 2) forKey:key row:control.tag];
}

- (void)store:(id)value forKey:(NSString *)key row:(NSInteger)row {
    SGSetFlagOverride(key, value);
    NSMutableDictionary *overrides = [_overrides mutableCopy];
    overrides[key] = value;
    _overrides = overrides;
    [self.tableView reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:0]] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];
    const SGFlagDef *flag = [self flagAt:path.row];
    if (flag->type == SGFlagBool) return;
    NSString *key = @(flag->key);
    id value = _overrides[key];
    NSString *hint = flag->type == SGFlagUnknown ? @"true or false, a number, or a text value" : flagState(flag, value);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[key substringFromIndex:[key rangeOfString:@"."].location + 1] message:hint preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = value ? [value description] : @"";
        field.keyboardType = flag->type == SGFlagInt ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeDefault;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Auto" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [self store:nil forKey:key row:path.row];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Force" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *text = alert.textFields.firstObject.text;
        if (!text.length) return;
        [self store:flag->type == SGFlagInt ? @(text.integerValue) : text forKey:key row:path.row];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

UIViewController *SGAllFlagsPage(void) {
    return [SGFlagsPage new];
}
