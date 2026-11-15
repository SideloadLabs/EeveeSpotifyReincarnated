#import "JournalStorage.h"
#import "Diagnostics.h"
#include <stdio.h>
#include <string.h>

// All writer state is confined to the existing journal queue. This module does
// not create a worker, timer or deferred buffer: each accepted line is flushed.
static FILE *logStream;
static unsigned long long logBytes;
static NSDateFormatter *logClock;
static const unsigned long long maximumLogBytes = 8 * 1024 * 1024;
static FILE *actionStream;
static unsigned long long actionBytes;
static const unsigned long long maximumActionBytes = 2 * 1024 * 1024;


NSURL *SAPJournalDocumentsURL(NSString *name) {
#ifdef SAP_TESTING
    // На хосте журнал не трогает ~/Documents пользователя.
    return [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
#else
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    return [documents URLByAppendingPathComponent:name];
#endif
}
void SAPJournalWriterAppendActionData(NSData *line) {
        if(actionStream && actionBytes>maximumActionBytes) {
            fclose(actionStream);actionStream=NULL;actionBytes=0;
            NSURL *current=SAPJournalDocumentsURL(@"PixieActions.log"),*previous=SAPJournalDocumentsURL(@"PixieActions.1.log");
            [NSFileManager.defaultManager removeItemAtURL:previous error:NULL];
            [NSFileManager.defaultManager moveItemAtURL:current toURL:previous error:NULL];
        }
        if(!actionStream) {
            actionStream=fopen(SAPJournalDocumentsURL(@"PixieActions.log").fileSystemRepresentation,"a");
            if(!actionStream)return;
            actionBytes=(unsigned long long)ftello(actionStream);
        }
        if(fwrite(line.bytes,1,line.length,actionStream)==line.length &&
           fwrite("\n",1,1,actionStream)==1)actionBytes+=line.length+1;
        fflush(actionStream);
}

void SAPJournalWriterFlushActions(void) {
    if(actionStream)fflush(actionStream);
}
void SAPJournalWriterClose(BOOL resetCounters) {
    if(logStream){fclose(logStream);logStream=NULL;}
    if(actionStream){fclose(actionStream);actionStream=NULL;}
    if(resetCounters){logBytes=0;actionBytes=0;}
}

void SAPJournalWriterWrite(NSString *kind, NSString *detail) { // только на очереди журнала
    if(!SAPDiagnosticsEnabled())return;
    if (!detail.length) return;
    if (!logClock) {
        logClock = [NSDateFormatter new];
        logClock.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        logClock.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    }
    if (logStream && logBytes > maximumLogBytes) {
        fclose(logStream); logStream = NULL; logBytes = 0;
        NSURL *url = SAPJournalDocumentsURL(@"SpotifyAudioProbeJournal.log");
        NSURL *previous = SAPJournalDocumentsURL(@"SpotifyAudioProbeJournal.1.log");
        [NSFileManager.defaultManager removeItemAtURL:previous error:NULL];
        [NSFileManager.defaultManager moveItemAtURL:url toURL:previous error:NULL];
    }
    if (!logStream) {
        NSURL *url = SAPJournalDocumentsURL(@"SpotifyAudioProbeJournal.log");
        logStream = fopen(url.fileSystemRepresentation, "a");
        if (!logStream) return;
        logBytes = (unsigned long long)ftello(logStream);
        int written = fprintf(logStream, "=== SpotifyAudioProbe journal opened %s ===\n", [logClock stringFromDate:NSDate.date].UTF8String);
        if (written > 0) logBytes += (unsigned long long)written;
    }
    NSString *line = [NSString stringWithFormat:@"%@ %-9@ %@\n", [logClock stringFromDate:NSDate.date], kind ?: @"", detail];
    const char *bytes = line.UTF8String;
    if (!bytes) return;
    size_t length = strlen(bytes);
    if (fwrite(bytes, 1, length, logStream) == length) logBytes += length;
    fflush(logStream);
}
void SAPJournalWriterLog(NSString *kind, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
void SAPJournalWriterLog(NSString *kind, NSString *format, ...) {
    if(!SAPDiagnosticsEnabled())return;
    va_list arguments; va_start(arguments, format);
    NSString *detail = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    SAPJournalWriterWrite(kind, detail);
}

