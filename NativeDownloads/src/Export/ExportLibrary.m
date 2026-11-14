#import "ExportLibrary.h"
#include <stdio.h>
#include <unistd.h>
#include <sqlite3.h>
static NSObject *libraryLock(void){static NSObject *lock;static dispatch_once_t once;dispatch_once(&once,^{lock=[NSObject new];});return lock;}
static NSString *component(NSString *value,NSString *fallback) {
    if(![value isKindOfClass:NSString.class]||!value.length)value=fallback;
    value=[[value componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:\n\r\t"]]componentsJoinedByString:@"_"];
    value=[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while([value lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>160)value=[value substringToIndex:[value rangeOfComposedCharacterSequenceAtIndex:value.length-1].location];
    return !value.length||[value isEqual:@"."]||[value isEqual:@".."]?fallback:value;
}
static BOOL safePath(NSURL *root,NSURL *url) {
    if(!root.isFileURL||!url.isFileURL||![root.lastPathComponent isEqual:@"Pixie Exports"])return NO;
    NSString *base=root.path.stringByStandardizingPath,*path=url.path.stringByStandardizingPath;
    if(![path isEqual:base]&&![path hasPrefix:[base stringByAppendingString:@"/"]])return NO;
    for(NSString *at=path;at.length>1;at=at.stringByDeletingLastPathComponent) {
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:at error:nil];
        if([attributes[NSFileType]isEqual:NSFileTypeSymbolicLink])return NO;
        if([at isEqual:base])break;
    }
    return YES;
}
static NSString *identity(NSDictionary *track,NSString *format) {
    NSString *uri=track[@"uri"];if(![uri isKindOfClass:NSString.class]||![uri hasPrefix:@"spotify:track:"]||uri.length!=36)return nil;
    NSString *idPart=[uri substringFromIndex:14];
    if([idPart rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet].location!=NSNotFound)return nil;
    if(![format isEqual:@"ogg"]&&![format isEqual:@"m4a"])return nil;
    return [uri stringByAppendingFormat:@"|%@",format];
}
static sqlite3 *libraryDB;
static NSString *libraryPath;
static void closeLibrary(void){if(libraryDB)sqlite3_close(libraryDB);libraryDB=NULL;libraryPath=nil;}
static BOOL openLibrary(NSURL *root,BOOL create) {
    NSURL *url=[root URLByAppendingPathComponent:@".pixie-index.sqlite"];
    if(!safePath(root,url))return NO;
    if(libraryDB&&[libraryPath isEqual:url.path])return YES;
    closeLibrary();NSFileManager *fm=NSFileManager.defaultManager;
    if(!create&&![fm fileExistsAtPath:url.path])return NO;
    if(create&&![fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil])return NO;
    if(sqlite3_open_v2(url.path.fileSystemRepresentation,&libraryDB,SQLITE_OPEN_READWRITE|(create?SQLITE_OPEN_CREATE:0)|SQLITE_OPEN_FULLMUTEX,NULL)!=SQLITE_OK){closeLibrary();return NO;}
    sqlite3_busy_timeout(libraryDB,2000);
    if(sqlite3_exec(libraryDB,"PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA cache_size=-512; CREATE TABLE IF NOT EXISTS exports(track_key TEXT PRIMARY KEY, relative_path TEXT NOT NULL UNIQUE) WITHOUT ROWID;",NULL,NULL,NULL)!=SQLITE_OK){closeLibrary();return NO;}
    libraryPath=url.path;[fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:url.path error:nil];return YES;
}
static NSString *lookup(const char *sql,NSString *value) {
    sqlite3_stmt *statement=NULL;NSString *result=nil;
    if(sqlite3_prepare_v2(libraryDB,sql,-1,&statement,NULL)==SQLITE_OK){sqlite3_bind_text(statement,1,value.UTF8String,-1,SQLITE_TRANSIENT);if(sqlite3_step(statement)==SQLITE_ROW){const unsigned char *text=sqlite3_column_text(statement,0);if(text)result=[NSString stringWithUTF8String:(const char *)text];}}
    sqlite3_finalize(statement);return result;
}
NSURL *SAPExportLibraryExisting(NSURL *root,NSDictionary *track,NSString *format) {
    @synchronized(libraryLock()) {
        NSString *key=identity(track,format);if(!key||!openLibrary(root,NO))return nil;
        NSString *relative=lookup("SELECT relative_path FROM exports WHERE track_key=?",key);if(!relative)return nil;
        NSURL *file=[root URLByAppendingPathComponent:relative];NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
        return safePath(root,file)&&[attributes[NSFileType]isEqual:NSFileTypeRegular]&&[attributes[NSFileSize]unsignedLongLongValue]>0?file:nil;
    }
}
NSURL *SAPExportLibraryPublish(NSURL *source,NSURL *root,NSDictionary *track,NSString **error) {
    @synchronized(libraryLock()) {
        if(error)*error=nil;NSFileManager *fm=NSFileManager.defaultManager;NSString *key=identity(track,source.pathExtension.lowercaseString);
        if(!key||!safePath(root,root)){if(error)*error=@"Invalid export library identity or path.";return nil;}
        NSDictionary *attrs=[fm attributesOfItemAtPath:source.path error:nil];
        if(![attrs[NSFileType]isEqual:NSFileTypeRegular]||![attrs[NSFileSize]unsignedLongLongValue]){if(error)*error=@"The complete export file is unavailable.";return nil;}
        if(!openLibrary(root,YES)){if(error)*error=@"Could not open the export index.";return nil;}
        NSString *relative=lookup("SELECT relative_path FROM exports WHERE track_key=?",key);
        if(!relative) {
            NSString *artist=component(track[@"artist_name"],@"Unknown artist"),*album=component(track[@"album_name"],@"Singles");
            NSString *name=[NSString stringWithFormat:@"%@.%@",component(track[@"name"],@"Track"),source.pathExtension.lowercaseString];
            relative=[[artist stringByAppendingPathComponent:album]stringByAppendingPathComponent:name];
            if([fm fileExistsAtPath:[root URLByAppendingPathComponent:relative].path]||lookup("SELECT track_key FROM exports WHERE relative_path=?",relative)){
                name=[NSString stringWithFormat:@"%@ [%@].%@",component(track[@"name"],@"Track"),[track[@"uri"]substringFromIndex:14],source.pathExtension.lowercaseString];relative=[[artist stringByAppendingPathComponent:album]stringByAppendingPathComponent:name];
            }
        }
        NSURL *destination=[root URLByAppendingPathComponent:relative],*folder=destination.URLByDeletingLastPathComponent;
        if(!safePath(root,destination)){if(error)*error=@"Unsafe export destination.";return nil;}
        NSError *failure=nil;
        if(![fm createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&failure]){if(error)*error=failure.localizedDescription;return nil;}
        NSString *token=NSUUID.UUID.UUIDString;NSURL *scratch=[folder URLByAppendingPathComponent:[@".pixie-publish-" stringByAppendingString:token]],*backup=[folder URLByAppendingPathComponent:[@".pixie-backup-" stringByAppendingString:token]];
        if(![fm copyItemAtURL:source toURL:scratch error:&failure]){if(error)*error=failure.localizedDescription;return nil;}
        BOOL transaction=sqlite3_exec(libraryDB,"BEGIN IMMEDIATE",NULL,NULL,NULL)==SQLITE_OK;sqlite3_stmt *statement=NULL;BOOL indexed=NO;
        if(transaction&&sqlite3_prepare_v2(libraryDB,"INSERT INTO exports(track_key,relative_path) VALUES(?,?) ON CONFLICT(track_key) DO UPDATE SET relative_path=excluded.relative_path",-1,&statement,NULL)==SQLITE_OK){sqlite3_bind_text(statement,1,key.UTF8String,-1,SQLITE_TRANSIENT);sqlite3_bind_text(statement,2,relative.UTF8String,-1,SQLITE_TRANSIENT);indexed=sqlite3_step(statement)==SQLITE_DONE;}
        sqlite3_finalize(statement);
        if(!indexed){if(transaction)sqlite3_exec(libraryDB,"ROLLBACK",NULL,NULL,NULL);[fm removeItemAtURL:scratch error:nil];if(error)*error=@"Could not update the export index. Previous files were preserved.";return nil;}
        BOOL replacing=[fm fileExistsAtPath:destination.path];
        if(replacing&&link(destination.path.fileSystemRepresentation,backup.path.fileSystemRepresentation)){sqlite3_exec(libraryDB,"ROLLBACK",NULL,NULL,NULL);[fm removeItemAtURL:scratch error:nil];if(error)*error=@"Could not preserve the previous export.";return nil;}
        if(rename(scratch.path.fileSystemRepresentation,destination.path.fileSystemRepresentation)){sqlite3_exec(libraryDB,"ROLLBACK",NULL,NULL,NULL);[fm removeItemAtURL:scratch error:nil];[fm removeItemAtURL:backup error:nil];if(error)*error=@"Could not atomically publish the audio file.";return nil;}
        if(sqlite3_exec(libraryDB,"COMMIT",NULL,NULL,NULL)!=SQLITE_OK){
            sqlite3_exec(libraryDB,"ROLLBACK",NULL,NULL,NULL);BOOL restored=replacing?rename(backup.path.fileSystemRepresentation,destination.path.fileSystemRepresentation)==0:[fm removeItemAtURL:destination error:nil];
            if(error)*error=restored?@"Index commit failed. The previous export was preserved.":@"Index commit and rollback failed; the previous file remains in a .pixie-backup file.";return nil;
        }
        [fm removeItemAtURL:backup error:nil];return destination;
    }
}
BOOL SAPExportLibraryClear(NSURL *root,NSString **error) {
    @synchronized(libraryLock()) {
        if(error)*error=nil;if(!safePath(root,root)){if(error)*error=@"Unsafe export cleanup path.";return NO;}
        closeLibrary();NSError *failure=nil;NSFileManager *fm=NSFileManager.defaultManager;if(![fm fileExistsAtPath:root.path])return YES;
        BOOL ok=[fm removeItemAtURL:root error:&failure];if(!ok&&error)*error=failure.localizedDescription;return ok;
    }
}
