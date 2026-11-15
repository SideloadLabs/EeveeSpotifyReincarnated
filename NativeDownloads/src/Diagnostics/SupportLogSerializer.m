#import "SupportLog.h"

NSDictionary *SAPSupportLogReadFile(NSURL *url) {
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfURL:url options:0 error:&error];
    NSMutableDictionary *entry=[@{@"name":url.lastPathComponent?:@"unknown",
        @"captured_at":[[NSISO8601DateFormatter new]stringFromDate:NSDate.date]} mutableCopy];
    if(!data) {
        entry[@"read_status"]=@"unavailable";
        entry[@"error_domain"]=error.domain?:@"unknown";entry[@"error_code"]=@(error.code);
    }else {
        entry[@"read_status"]=@"included";entry[@"bytes"]=@(data.length);
        NSString *text=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding];
        entry[@"encoding"]=text?@"utf-8":@"base64";
        entry[@"content"]=text?:[data base64EncodedStringWithOptions:0];
    }
    return entry;
}
BOOL SAPSupportLogWrite(NSURL *url,NSDictionary *diagnostics,NSDictionary *journal,
                        NSString *summary,NSArray *files,NSError **error) {
    NSMutableDictionary *report=[diagnostics mutableCopy]?:[NSMutableDictionary dictionary];
    NSDictionary *trace=report[@"diagnostic_trace"]?:@{@"status":@"not_included"};[report removeObjectForKey:@"diagnostic_trace"];
    NSDictionary *value=@{@"log_schema":@"Pixie support log 3",
        @"generated_at":[[NSISO8601DateFormatter new]stringFromDate:NSDate.date],
        @"snapshot_note":@"Sections have their own observation times. File contents are captured separately; this is not an atomic snapshot of Spotify or its server.",
        @"sections":@{@"diagnostics":report,@"trace":trace,@"download_journal":journal?:@{},
            @"download_summary":summary?:@"",@"log_files":files?:@[]}};
    NSData *data=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:error];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:error];
}
