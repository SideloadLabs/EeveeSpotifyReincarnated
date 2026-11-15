#pragma once
#import <Foundation/Foundation.h>

// Cancelling a source also releases its handler and captured request after GCD
// completes cancellation; completed requests do not wait for their deadline.
static inline dispatch_source_t SAPScheduleDeadline(dispatch_queue_t queue,double seconds,dispatch_block_t handler) {
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    __weak dispatch_source_t weakTimer=timer;
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,0);
    dispatch_source_set_event_handler(timer,^{
        dispatch_source_t source=weakTimer;if(source)dispatch_source_cancel(source);
        handler();
    });
    dispatch_resume(timer);return timer;
}
