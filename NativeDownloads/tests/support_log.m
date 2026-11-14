#import <Foundation/Foundation.h>
#import "SupportLog.h"
#include <assert.h>
int main(void) {@autoreleasepool {
    NSURL *folder=[NSURL fileURLWithPath:[NSTemporaryDirectory()stringByAppendingPathComponent:NSUUID.UUID.UUIDString] isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    NSMutableArray *files=[NSMutableArray array];
    for(NSString *name in @[@"PixieActions.log",@"SpotifyAudioProbeJournal.log",@"vitrine-diagnostics.txt"]) {
        NSURL *url=[folder URLByAppendingPathComponent:name];
        [@"line 1\nUnicode: ✓\n" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        NSDictionary *entry=SAPSupportLogReadFile(url);assert([entry[@"content"]isEqual:@"line 1\nUnicode: ✓\n"]);[files addObject:entry];
    }
    NSURL *binary=[folder URLByAppendingPathComponent:@"non-utf8.log"];
    NSData *raw=[NSData dataWithBytes:(uint8_t[]){0xff,0x00,0xfe} length:3];[raw writeToURL:binary atomically:YES];
    NSDictionary *binaryEntry=SAPSupportLogReadFile(binary);assert([binaryEntry[@"encoding"]isEqual:@"base64"]);
    assert([[[NSData alloc]initWithBase64EncodedString:binaryEntry[@"content"] options:0]isEqual:raw]);[files addObject:binaryEntry];
    NSDictionary *missing=SAPSupportLogReadFile([folder URLByAppendingPathComponent:@"missing.log"]);
    assert([missing[@"read_status"]isEqual:@"unavailable"]);[files addObject:missing];
    NSDictionary *journal=@{@"snapshots":@{@"license_status":@{@"free_licenses":@0,@"max_licenses":@5}},@"core_errors":@[@{@"code":@7028}]};
    NSURL *out=[folder URLByAppendingPathComponent:@"PixieSupportLog.json"];NSError *error=nil;
    NSDictionary *trace=@{@"events":@[@{@"event_id":@1}],@"coverage":@{@"scope":@"fixture"}};
    assert(SAPSupportLogWrite(out,@{@"configured_mode":@0,@"diagnostic_trace":trace},journal,@"DEVICE_LIMIT_REACHED",files,&error));
    NSDictionary *result=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfURL:out] options:0 error:&error];
    assert([result[@"sections"][@"download_journal"]isEqual:journal]);
    assert([result[@"sections"][@"log_files"]isEqual:files]);
    assert([result[@"sections"][@"download_summary"]isEqual:@"DEVICE_LIMIT_REACHED"]);
    assert([result[@"log_schema"]isEqual:@"Pixie support log 3"]&&[result[@"sections"][@"trace"]isEqual:trace]);
    assert(!result[@"sections"][@"diagnostics"][@"diagnostic_trace"]);
    assert(!SAPSupportLogWrite([folder URLByAppendingPathComponent:@"missing/out.json"],@{},@{},@"",@[],&error));
    [NSFileManager.defaultManager removeItemAtURL:folder error:NULL];
    puts("PASS one JSON contains complete report, journal, summary and lossless logs; missing/read/write failures are explicit");
}return 0;}
