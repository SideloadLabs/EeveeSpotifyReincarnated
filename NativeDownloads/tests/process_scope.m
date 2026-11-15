#import "ProcessScope.h"
#include <assert.h>

int main(void) {@autoreleasepool {
    assert(!SAPIsAppExtensionProcess(@{@"CFBundleIdentifier":@"com.spotify.client"},@"/Applications/Spotify.app"));
    assert(!SAPIsAppExtensionProcess(@{@"CFBundleIdentifier":@"signed.custom.spotify"},@"/Applications/Spotify.app"));
    assert(!SAPIsAppExtensionProcess(@{},@"/Applications/LiveContainer.app"));
    assert(!SAPIsAppExtensionProcess(@{},@"/Container/Documents/Applications/Spotify.app"));
    assert(!SAPIsAppExtensionProcess(nil,nil));
    assert(SAPIsAppExtensionProcess(@{@"NSExtension":@{}},@"/Applications/UnusualHost.app"));
    assert(SAPIsAppExtensionProcess(@{},@"/Applications/Spotify.app/PlugIns/Widget.appex"));
    assert(SAPIsAppExtensionProcess(@{},@"/Applications/Spotify.app/Extensions/Notification.APPEX"));
    assert(SAPIsAppExtensionProcess(@{@"NSExtension":NSNull.null},nil));
    puts("PASS: extensions skip host hooks; renamed Spotify and LiveContainer remain eligible");
}return 0;}
