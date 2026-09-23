// The grid the double tap is read against, and what each of its cells does.
#import "Core/SGCore.h"
#import "Gestures.h"

NSArray<NSString *> *SGGestureActionNames(void) {
    return @[@"Nothing", @"Seek back", @"Seek forward", @"Play or pause", @"Next track",
             @"Previous track", @"Shuffle", @"Repeat"];
}

NSArray<NSString *> *SGGestureSplitNames(void) {
    return @[@"Two columns", @"Three columns", @"Three by three"];
}

NSArray<NSNumber *> *SGGestureStepChoices(void) {
    return @[@5, @10, @15, @30];
}

NSInteger SGGestureSplit(void) {
    return SGInt(SGKeyGestureSplit, 1);   // three columns
}

NSInteger SGGestureStepChoice(void) {
    NSInteger choice = SGInt(SGKeyGestureStep, 1);   // ten seconds
    return choice >= 0 && choice < (NSInteger)SGGestureStepChoices().count ? choice : 1;
}

void SGGestureGrid(NSInteger *columns, NSInteger *rows) {
    NSInteger split = SGGestureSplit();
    *columns = split == 0 ? 2 : 3;
    *rows = split == 2 ? 3 : 1;
}

double SGGestureStep(void) {
    return SGGestureStepChoices()[(NSUInteger)SGGestureStepChoice()].doubleValue;
}

// Seek out to the sides, play or pause in the middle; a grid of three rows repeats the columns, so
// the split changes the cells to edit without changing what the player does until one is edited.
static NSArray<NSNumber *> *defaultZones(NSInteger columns, NSInteger rows) {
    NSMutableArray<NSNumber *> *zones = [NSMutableArray array];
    for (NSInteger row = 0; row < rows; row++) {
        for (NSInteger column = 0; column < columns; column++) {
            SGGestureAction action = SGGestureSeekForward;
            if (column == 0) action = SGGestureSeekBack;
            else if (columns == 3 && column == 1) action = SGGesturePlayPause;
            [zones addObject:@(action)];
        }
    }
    return zones;
}

// One saved layout per split, so switching between them and back keeps both.
static NSString *splitKey(NSInteger columns, NSInteger rows) {
    return [NSString stringWithFormat:@"%ldx%ld", (long)columns, (long)rows];
}

static NSDictionary *savedZones(void) {
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:SGKeyGestureZones];
    return [saved isKindOfClass:NSDictionary.class] ? saved : @{};
}

NSArray<NSNumber *> *SGGestureZones(void) {
    NSInteger columns, rows;
    SGGestureGrid(&columns, &rows);
    NSArray *zones = savedZones()[splitKey(columns, rows)];
    if (![zones isKindOfClass:NSArray.class] || zones.count != (NSUInteger)(columns * rows)) {
        return defaultZones(columns, rows);
    }
    for (id action in zones) if (![action isKindOfClass:NSNumber.class]) return defaultZones(columns, rows);
    return zones;
}

void SGSetGestureZone(NSInteger cell, SGGestureAction action) {
    NSInteger columns, rows;
    SGGestureGrid(&columns, &rows);
    if (cell < 0 || cell >= columns * rows) return;
    NSMutableArray<NSNumber *> *zones = [SGGestureZones() mutableCopy];
    zones[(NSUInteger)cell] = @(action);
    NSMutableDictionary *saved = [savedZones() mutableCopy];
    saved[splitKey(columns, rows)] = zones;
    [NSUserDefaults.standardUserDefaults setObject:saved forKey:SGKeyGestureZones];
}

void SGResetGestureZones(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyGestureZones];
}

NSInteger SGGestureCellAt(CGPoint point, CGSize size) {
    NSInteger columns, rows;
    SGGestureGrid(&columns, &rows);
    if (size.width <= 0 || size.height <= 0) return -1;
    NSInteger column = (NSInteger)(point.x / size.width * columns);
    NSInteger row = (NSInteger)(point.y / size.height * rows);
    column = MAX(0, MIN(columns - 1, column));
    row = MAX(0, MIN(rows - 1, row));
    return row * columns + column;
}
