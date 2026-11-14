#import "ExportCacheIndex.h"
#import <TargetConditionals.h>
#import <os/lock.h>
#import <dispatch/dispatch.h>
#include <sqlite3.h>
#include <math.h>
#include <stdatomic.h>

enum { SAPCacheIndexMaximumRows=100000, SAPCacheIndexMaximumCandidates=64, SAPCacheIndexMaximumPending=4096 };
static dispatch_queue_t worker;
static os_unfair_lock pendingLock=OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSData *,NSDictionary *> *pending;
static BOOL drainScheduled;
static uint64_t observationOrder,droppedObservations,invalidObservations;
static atomic_uint_fast64_t writeErrors,publishedRows;
static sqlite3 *database;
static sqlite3_stmt *insertStatement,*updateStatement,*readStatement,*pruneStatement;
static sqlite3_int64 rows,lastSeen;
static NSString *testingPath;
static void *queueKey=&queueKey;

static void initialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        worker=dispatch_queue_create("app.pixie.export.cache-index",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
        dispatch_queue_set_specific(worker,queueKey,queueKey,NULL);
        pending=[NSMutableDictionary dictionary];
    });
}
static NSData *unhex(id object) {
    if(![object isKindOfClass:NSString.class]||[(NSString *)object length]!=40)return nil;
    uint8_t bytes[20];NSString *text=object;
    for(NSUInteger i=0;i<40;i++) {
        unichar c=[text characterAtIndex:i];unsigned value;
        if(c>='0'&&c<='9')value=c-'0';else if(c>='a'&&c<='f')value=c-'a'+10;
        else if(c>='A'&&c<='F')value=c-'A'+10;else return nil;
        if(i%2)bytes[i/2]|=value;else bytes[i/2]=(uint8_t)(value<<4);
    }
    return [NSData dataWithBytes:bytes length:20];
}
static NSString *hex(const void *pointer) {
    const uint8_t *bytes=pointer;char text[41];static const char digits[]="0123456789abcdef";
    for(unsigned i=0;i<20;i++){text[2*i]=digits[bytes[i]>>4];text[2*i+1]=digits[bytes[i]&15];}text[40]=0;
    return [NSString stringWithUTF8String:text];
}
static BOOL integerInRange(id value,unsigned maximum) {
    if(![value isKindOfClass:NSNumber.class])return NO;
    double n=[value doubleValue];return isfinite(n)&&n>=0&&n<=maximum&&floor(n)==n;
}
static void closeDatabase(void) {
    sqlite3_finalize(insertStatement);sqlite3_finalize(updateStatement);sqlite3_finalize(readStatement);sqlite3_finalize(pruneStatement);
    insertStatement=updateStatement=readStatement=pruneStatement=NULL;
    if(database)sqlite3_close(database);database=NULL;rows=lastSeen=0;
}
static BOOL prepare(sqlite3_stmt **statement,const char *sql) {
    return sqlite3_prepare_v2(database,sql,-1,statement,NULL)==SQLITE_OK;
}
static void protectFiles(NSString *path) {
#if TARGET_OS_IPHONE
    NSDictionary *attributes=@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication};
    for(NSString *suffix in @[@"",@"-wal",@"-shm"])
        [NSFileManager.defaultManager setAttributes:attributes ofItemAtPath:[path stringByAppendingString:suffix] error:NULL];
#else
    (void)path;
#endif
}
static BOOL openDatabase(void) {
    if(database)return YES;
    NSString *path=testingPath;
#ifdef SAP_TESTING
    if(!path)path=@":memory:";
#else
    if(!path)path=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/PixieExport/cache-index.sqlite"];
#endif
    NSDictionary *attributes=nil;
#if TARGET_OS_IPHONE
    attributes=@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication};
#endif
    if(![path isEqual:@":memory:"]&&![NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:attributes error:NULL])return NO;
#if TARGET_OS_IPHONE
    // Existing PixieExport directories must also establish inheritance for WAL/SHM.
    if(![NSFileManager.defaultManager setAttributes:attributes ofItemAtPath:path.stringByDeletingLastPathComponent error:NULL])return NO;
#endif
    if(sqlite3_open_v2(path.fileSystemRepresentation,&database,SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_NOMUTEX,NULL)!=SQLITE_OK){closeDatabase();return NO;}
    sqlite3_busy_timeout(database,100);
    const char *schema="PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;"
        "CREATE TABLE IF NOT EXISTS mappings (file_id BLOB NOT NULL CHECK(length(file_id)=20),cache_id BLOB NOT NULL CHECK(length(cache_id)=20),namespace_id BLOB NOT NULL CHECK(length(namespace_id)=20),descriptor_kind INTEGER NOT NULL CHECK(descriptor_kind BETWEEN 0 AND 255),descriptor_index INTEGER NOT NULL CHECK(descriptor_index BETWEEN 0 AND 65535),last_seen INTEGER NOT NULL,UNIQUE(file_id,cache_id,namespace_id));"
        "CREATE INDEX IF NOT EXISTS mappings_file_seen ON mappings(file_id,last_seen DESC);"
        "CREATE INDEX IF NOT EXISTS mappings_seen ON mappings(last_seen);";
    if(sqlite3_exec(database,schema,NULL,NULL,NULL)!=SQLITE_OK)goto failed;
    sqlite3_stmt *count=NULL;
    if(!prepare(&count,"SELECT count(*),coalesce(max(last_seen),0) FROM mappings"))goto failed;
    if(sqlite3_step(count)!=SQLITE_ROW){sqlite3_finalize(count);goto failed;}
    rows=sqlite3_column_int64(count,0);lastSeen=sqlite3_column_int64(count,1);sqlite3_finalize(count);
    if(!prepare(&insertStatement,"INSERT OR IGNORE INTO mappings(file_id,cache_id,namespace_id,descriptor_kind,descriptor_index,last_seen) VALUES(?,?,?,?,?,?)")||
       !prepare(&updateStatement,"UPDATE mappings SET descriptor_kind=?,descriptor_index=?,last_seen=? WHERE file_id=? AND cache_id=? AND namespace_id=?")||
       !prepare(&readStatement,"SELECT cache_id,namespace_id,descriptor_kind,descriptor_index FROM mappings WHERE file_id=? ORDER BY last_seen DESC LIMIT 64")||
       !prepare(&pruneStatement,"DELETE FROM mappings WHERE rowid IN (SELECT rowid FROM mappings ORDER BY last_seen LIMIT ?)"))goto failed;
    atomic_store(&publishedRows,(uint64_t)rows);protectFiles(path);return YES;
failed:
    closeDatabase();return NO;
}
static void bindData(sqlite3_stmt *statement,int index,NSData *data) {
    sqlite3_bind_blob(statement,index,data.bytes,(int)data.length,SQLITE_TRANSIENT);
}
static BOOL step(sqlite3_stmt *statement) {
    BOOL ok=sqlite3_step(statement)==SQLITE_DONE;sqlite3_reset(statement);sqlite3_clear_bindings(statement);return ok;
}
static void recordLost(NSUInteger count) {
    os_unfair_lock_lock(&pendingLock);droppedObservations+=count;os_unfair_lock_unlock(&pendingLock);writeErrors++;
}
static void flushPending(void) {
    os_unfair_lock_lock(&pendingLock);NSArray *batch=pending.allValues;[pending removeAllObjects];os_unfair_lock_unlock(&pendingLock);
    if(!batch.count)return;
    batch=[batch sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"order"]compare:b[@"order"]];}];
    if(!openDatabase()||sqlite3_exec(database,"BEGIN IMMEDIATE",NULL,NULL,NULL)!=SQLITE_OK){recordLost(batch.count);return;}
    sqlite3_int64 previousRows=rows,previousSeen=lastSeen;
    for(NSDictionary *item in batch) {
        bindData(insertStatement,1,item[@"file"]);bindData(insertStatement,2,item[@"cache"]);bindData(insertStatement,3,item[@"namespace"]);
        sqlite3_bind_int(insertStatement,4,[item[@"kind"]intValue]);sqlite3_bind_int(insertStatement,5,[item[@"index"]intValue]);sqlite3_bind_int64(insertStatement,6,++lastSeen);
        if(!step(insertStatement))goto failed;
        BOOL inserted=sqlite3_changes(database)>0;
        if(inserted)rows++;
        else {
            sqlite3_bind_int(updateStatement,1,[item[@"kind"]intValue]);sqlite3_bind_int(updateStatement,2,[item[@"index"]intValue]);sqlite3_bind_int64(updateStatement,3,lastSeen);
            bindData(updateStatement,4,item[@"file"]);bindData(updateStatement,5,item[@"cache"]);bindData(updateStatement,6,item[@"namespace"]);
            if(!step(updateStatement))goto failed;
        }
    }
    if(rows>SAPCacheIndexMaximumRows) {
        sqlite3_bind_int64(pruneStatement,1,rows-SAPCacheIndexMaximumRows);
        if(!step(pruneStatement))goto failed;rows-=sqlite3_changes(database);
    }
    if(sqlite3_exec(database,"COMMIT",NULL,NULL,NULL)==SQLITE_OK){atomic_store(&publishedRows,(uint64_t)rows);return;}
failed:
    sqlite3_exec(database,"ROLLBACK",NULL,NULL,NULL);rows=previousRows;lastSeen=previousSeen;recordLost(batch.count);
}
static void drain(void) {
    @autoreleasepool {
        flushPending();
        os_unfair_lock_lock(&pendingLock);
        if(pending.count)dispatch_async(worker,^{drain();});else drainScheduled=NO;
        os_unfair_lock_unlock(&pendingLock);
    }
}
void SAPExportCacheIndexObserve(NSData *fileID,NSDictionary *candidate) {
    initialize();
    NSData *cache=nil,*namespace=nil;
    if([candidate isKindOfClass:NSDictionary.class]){cache=unhex(candidate[@"cache_id_hex"]);namespace=unhex(candidate[@"namespace_id_hex"]);}
    if(![fileID isKindOfClass:NSData.class]||fileID.length!=20||!cache||!namespace||
       !integerInRange(candidate[@"descriptor_kind"],255)||!integerInRange(candidate[@"index"],65535)) {
        os_unfair_lock_lock(&pendingLock);invalidObservations++;os_unfair_lock_unlock(&pendingLock);return;
    }
    NSData *file=[fileID copy];NSMutableData *identity=[file mutableCopy];[identity appendData:cache];[identity appendData:namespace];
    os_unfair_lock_lock(&pendingLock);
    if(pending.count>=SAPCacheIndexMaximumPending&&!pending[identity]){droppedObservations++;os_unfair_lock_unlock(&pendingLock);return;}
    pending[identity]=@{@"file":file,@"cache":cache,@"namespace":namespace,@"kind":@([candidate[@"descriptor_kind"]unsignedIntValue]),@"index":@([candidate[@"index"]unsignedIntValue]),@"order":@(++observationOrder)};
    if(!drainScheduled){drainScheduled=YES;dispatch_async(worker,^{drain();});}
    os_unfair_lock_unlock(&pendingLock);
}
static void synchronously(dispatch_block_t block) {
    initialize();if(dispatch_get_specific(queueKey))block();else dispatch_sync(worker,block);
}
NSArray<NSDictionary *> *SAPExportCacheIndexCandidates(NSData *fileID) {
    if(![fileID isKindOfClass:NSData.class]||fileID.length!=20)return @[];
    NSData *file=[fileID copy];__block NSArray *result=@[];
    synchronously(^{
        flushPending();if(!openDatabase()){writeErrors++;return;}
        NSMutableArray *items=[NSMutableArray array];bindData(readStatement,1,file);int code;
        while((code=sqlite3_step(readStatement))==SQLITE_ROW) {
            if(sqlite3_column_bytes(readStatement,0)!=20||sqlite3_column_bytes(readStatement,1)!=20)continue;
            [items addObject:@{@"cache_id_hex":hex(sqlite3_column_blob(readStatement,0)),@"namespace_id_hex":hex(sqlite3_column_blob(readStatement,1)),@"descriptor_kind":@(sqlite3_column_int(readStatement,2)),@"index":@(sqlite3_column_int(readStatement,3))}];
        }
        if(code!=SQLITE_DONE)writeErrors++;
        sqlite3_reset(readStatement);sqlite3_clear_bindings(readStatement);result=[items copy];
    });return result;
}
NSDictionary *SAPExportCacheIndexReport(void) {
    initialize();os_unfair_lock_lock(&pendingLock);uint64_t lost=droppedObservations,invalid=invalidObservations;NSUInteger queued=pending.count;os_unfair_lock_unlock(&pendingLock);
    return @{@"rows":@(atomic_load(&publishedRows)),@"write_errors":@(atomic_load(&writeErrors)),@"dropped_observations":@(lost),@"invalid_observations":@(invalid),@"pending":@(queued),@"maximum_rows":@(SAPCacheIndexMaximumRows),@"per_file_limit":@(SAPCacheIndexMaximumCandidates)};
}

#ifdef SAP_TESTING
void SAPExportCacheIndexSetPathForTesting(NSString *path) {
    synchronously(^{flushPending();closeDatabase();testingPath=[path copy];});
}
void SAPExportCacheIndexCloseForTesting(void) {synchronously(^{flushPending();closeDatabase();});}
#endif
