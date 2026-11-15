#import "OfflineLibraryChromeGeometry.h"
#import <assert.h>
int main(void) {@autoreleasepool {
    CGRect page=CGRectMake(0,0,430,932);
    NSArray *expanded=@[[NSValue valueWithRect:NSRectFromCGRect(CGRectMake(8,786,414,56))],[NSValue valueWithRect:NSRectFromCGRect(CGRectMake(20,852,390,70))]];
    NSArray *collapsed=@[[NSValue valueWithRect:NSRectFromCGRect(CGRectMake(90,850,320,56))],[NSValue valueWithRect:NSRectFromCGRect(CGRectMake(20,850,60,60))]];
    assert(SAPOfflineChromeCoverage(page,898,expanded)==146);
    assert(SAPOfflineChromeCoverage(page,898,collapsed)==82);
    assert(SAPOfflineChromeCoverage(page,898,@[])==34);
    NSArray *unrelated=@[[NSValue valueWithRect:NSRectFromCGRect(CGRectMake(0,0,430,700))],[NSValue valueWithRect:NSRectFromCGRect(CGRectMake(0,950,430,60))],[NSValue valueWithRect:NSRectFromCGRect(CGRectNull)]];
    assert(SAPOfflineChromeCoverage(page,898,unrelated)==34);
    assert(SAPOfflineChromeCoverage(CGRectMake(0,100,430,832),898,expanded)==146);
    puts("offline_library_chrome PASS");
}}
