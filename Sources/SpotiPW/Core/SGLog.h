#import <Foundation/Foundation.h>
#import <os/log.h>

// %{public}s so idevicesyslog on the Mac sees the text instead of <private>.
#define SGLog(fmt, ...) os_log_with_type(OS_LOG_DEFAULT, OS_LOG_TYPE_DEFAULT, "[spotifyglass] %{public}s", [NSString stringWithFormat:(fmt), ##__VA_ARGS__].UTF8String)

// Long dumps, split into numbered parts under the unified log's size cap.
void SGLogLong(NSString *tag, NSString *text);
// Logs every class of the list that this Spotify does not have; a feature calls it from its %ctor.
void SGRequireClasses(NSArray<NSString *> *names);
