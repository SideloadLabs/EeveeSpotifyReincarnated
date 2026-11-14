#pragma once
#import <Foundation/Foundation.h>
#include <stdint.h>

static inline NSString *SAPJournalErrorName(uint64_t code) {
    switch (code) {
        case 0: return @"SUCCESS"; case 1: return @"GENERIC"; case 8: return @"DISK_FULL";
        case 14: return @"EXPIRED"; case 19: return @"TOO_MANY_TRACKS"; case 23: return @"NOT_ALLOWED";
        case 36: return @"CONNECTION_DISABLED"; case 7028: return @"DEVICE_LIMIT_REACHED"; default: return @"UNKNOWN";
    }
}
