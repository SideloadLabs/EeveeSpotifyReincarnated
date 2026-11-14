#import <Foundation/Foundation.h>
#import "ExportCacheIndex.h"
#include <sqlite3.h>
#include <assert.h>
static NSDictionary *candidate(unsigned n) {
    return @{@"cache_id_hex":[NSString stringWithFormat:@"%040x",n],
        @"namespace_id_hex":@"0123456789abcdef0123456789abcdef01234567",@"descriptor_kind":@3,@"index":@(n%65536)};
}
int main(void) {@autoreleasepool {
    NSString *directory=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path=[directory stringByAppendingPathComponent:@"cache-index.sqlite"];
    SAPExportCacheIndexSetPathForTesting(path);
    NSData *file=[NSMutableData dataWithLength:20];
    SAPExportCacheIndexObserve(file,candidate(1));
    NSArray *items=SAPExportCacheIndexCandidates(file);
    assert(items.count==1&&[items[0]isEqual:candidate(1)]);
    for(unsigned i=0;i<100;i++)SAPExportCacheIndexObserve(file,candidate(1));
    assert(SAPExportCacheIndexCandidates(file).count==1);
    SAPExportCacheIndexCloseForTesting();
    assert([NSFileManager.defaultManager fileExistsAtPath:path]);
    assert([SAPExportCacheIndexCandidates(file)isEqual:items]);
    NSMutableDictionary *bad=[candidate(2)mutableCopy];bad[@"namespace_id_hex"]=@"bad";
    SAPExportCacheIndexObserve(file,bad);
    bad=[candidate(2)mutableCopy];bad[@"namespace_id_hex"]=@42;SAPExportCacheIndexObserve(file,bad);
    bad=[candidate(2)mutableCopy];bad[@"descriptor_kind"]=@256;SAPExportCacheIndexObserve(file,bad);
    bad=[candidate(2)mutableCopy];bad[@"index"]=@(-1);SAPExportCacheIndexObserve(file,bad);
    bad=[candidate(2)mutableCopy];bad[@"index"]=@1.5;SAPExportCacheIndexObserve(file,bad);
    SAPExportCacheIndexObserve([NSData data],candidate(2));
    assert(SAPExportCacheIndexCandidates(file).count==1);
    for(unsigned i=2;i<=80;i++)SAPExportCacheIndexObserve(file,candidate(i));
    items=SAPExportCacheIndexCandidates(file);assert(items.count==64);
    assert([items[0][@"cache_id_hex"]isEqual:candidate(80)[@"cache_id_hex"]]);
    SAPExportCacheIndexCloseForTesting();
    sqlite3 *db=NULL;assert(sqlite3_open(path.UTF8String,&db)==SQLITE_OK);
    sqlite3_stmt *s=NULL;assert(sqlite3_prepare_v2(db,"SELECT count(*) FROM mappings",-1,&s,NULL)==SQLITE_OK);
    assert(sqlite3_step(s)==SQLITE_ROW&&sqlite3_column_int(s,0)==80);sqlite3_finalize(s);
    assert(sqlite3_prepare_v2(db,"PRAGMA journal_mode",-1,&s,NULL)==SQLITE_OK);
    assert(sqlite3_step(s)==SQLITE_ROW&&!strcmp((const char *)sqlite3_column_text(s,0),"wal"));sqlite3_finalize(s);
    // Independent seeding exercises the real 100000-row bound cheaply.
    assert(sqlite3_exec(db,"BEGIN; WITH RECURSIVE n(x) AS (SELECT 81 UNION ALL SELECT x+1 FROM n WHERE x<100000) INSERT INTO mappings(file_id,cache_id,namespace_id,descriptor_kind,descriptor_index,last_seen) SELECT zeroblob(20),randomblob(20),zeroblob(20),0,0,x FROM n; COMMIT;",NULL,NULL,NULL)==SQLITE_OK);
    sqlite3_close(db);
    SAPExportCacheIndexObserve(file,candidate(100001));
    assert(SAPExportCacheIndexCandidates(file).count==64);
    NSDictionary *report=SAPExportCacheIndexReport();assert([report[@"rows"]unsignedIntegerValue]==100000);
    assert([report[@"write_errors"]unsignedIntegerValue]==0);
    SAPExportCacheIndexCloseForTesting();
    assert(sqlite3_open(path.UTF8String,&db)==SQLITE_OK);
    assert(sqlite3_prepare_v2(db,"SELECT count(*) FROM mappings",-1,&s,NULL)==SQLITE_OK);
    assert(sqlite3_step(s)==SQLITE_ROW&&sqlite3_column_int(s,0)==100000);sqlite3_finalize(s);sqlite3_close(db);
    printf("cache metadata for 100000 mappings: %llu bytes\n",[[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileSize]unsignedLongLongValue]);
    [NSFileManager.defaultManager removeItemAtPath:directory error:NULL];
    puts("PASS cache-index persistence, validation, dedup, bounded queries, WAL and incremental pruning");
}return 0;}
