#pragma once
#import <Foundation/Foundation.h>
#import "M4AExport.h"
// Shared process-wide cap, userInitiated priority; thermal serious2/critical1.
// The producer window in TrackExport uses the same constant so they cannot drift.
#define SAPM4AConversionParallelLimit 20
// Completion runs on its conversion worker; progress and metadata remain retained.
// Cancel NSProgress or provide a thread-safe cancellation predicate.
NSProgress *SAPQueueM4AConversion(NSURL *input, NSURL *output, NSDictionary *track,
    NSDictionary *artwork, BOOL (^cancelled)(void), void (^completion)(SAPM4AExportStatus status));
