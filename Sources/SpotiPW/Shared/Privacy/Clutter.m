#import "Core/SGCore.h"
#import "Privacy.h"
static NSString*const socialProofFlags[]={@"ios-feature-search.social_proof_playlist_enabled",@"ios-feature-search.social_proof_plays_in_search_enabled"};
static BOOL forcedOff(NSString*key){if(SGHidden(SGKeyHideSearchVideos)&&[key isEqualToString:@"ios-feature-search.video_carousel_section_enabled"])return YES;if(!SGHidden(SGKeyHideSocialProof))return NO;for(size_t i=0;i<2;i++)if([key isEqualToString:socialProofFlags[i]])return YES;return NO;}
__attribute__((constructor))static void registerForcer(void){SGFlagForcer off=^id(NSString*key){return forcedOff(key)?@NO:nil;};SGRegisterFlagForcer(NO,off,off);}
