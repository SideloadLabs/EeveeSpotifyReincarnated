#import "M4AConversionQueue.h"
#include <stdatomic.h>
#include <assert.h>
static atomic_int started,active,maximum,completed,cancelledCount;
static dispatch_semaphore_t gate;
SAPM4AExportStatus SAPExportOggToM4A(const char *in,const char *out,const SAPM4AExportMetadata *meta,SAPM4AExportCancellation cancel,SAPM4AExportProgress progress,void *ctx) {
 atomic_fetch_add(&started,1);int n=atomic_fetch_add(&active,1)+1,old=atomic_load(&maximum);while(n>old&&!atomic_compare_exchange_weak(&maximum,&old,n)){}
 assert(!strcmp(meta->title,"Title"));assert(!strcmp(meta->artist,"Artist"));assert(meta->jpeg_cover_length==3);
 dispatch_semaphore_wait(gate,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));atomic_fetch_sub(&active,1);
 return cancel&&cancel(ctx)?SAPM4AExportCancelled:SAPM4AExportOK;
}
int main(void){@autoreleasepool {
 gate=dispatch_semaphore_create(0);NSURL *input=[NSURL fileURLWithPath:@"/tmp/input.ogg"],*output=[NSURL fileURLWithPath:@"/tmp/output.m4a"];
 int cap=NSProcessInfo.processInfo.thermalState==NSProcessInfoThermalStateCritical?1:NSProcessInfo.processInfo.thermalState==NSProcessInfoThermalStateSerious?2:20;
 NSMutableArray *jobs=NSMutableArray.array;
 for(int i=0;i<cap+1;i++)[jobs addObject:SAPQueueM4AConversion(input,output,@{@"name":@"Title",@"artist_name":@"Artist"},@{@"jpeg":[NSData dataWithBytes:"abc" length:3]},nil,^(SAPM4AExportStatus status){if(status==SAPM4AExportCancelled)atomic_fetch_add(&cancelledCount,1);atomic_fetch_add(&completed,1);})];
 NSDate *end=[NSDate dateWithTimeIntervalSinceNow:3];while(atomic_load(&started)<cap&&end.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.001];
 assert(atomic_load(&started)==cap);assert(atomic_load(&maximum)==cap);[jobs.lastObject cancel];[jobs.firstObject cancel];
 for(int i=0;i<cap+1;i++)dispatch_semaphore_signal(gate);
 end=[NSDate dateWithTimeIntervalSinceNow:5];while(atomic_load(&completed)<cap+1&&end.timeIntervalSinceNow>0)[NSThread sleepForTimeInterval:.001];
 assert(atomic_load(&completed)==cap+1 && atomic_load(&cancelledCount)==2);assert(atomic_load(&maximum)<=20);assert(atomic_load(&started)==cap);
 puts("m4a_conversion_queue PASS");
}}
