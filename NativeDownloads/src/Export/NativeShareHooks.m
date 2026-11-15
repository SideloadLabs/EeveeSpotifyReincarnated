#import "NativeShareHooks.h"
#import "ExportArtwork.h"
#import "TrackExport.h"
#import "ShareFilePromise.h"
#import "ShareCompletionRelay.h"
#import "NativeShareTapPolicy.h"
#import "NativeShareRoute.h"
#import <UIKit/UIGestureRecognizerSubclass.h>
#import "Diagnostics.h"
#import "DiagnosticTrace.h"
#import <UIKit/UIKit.h>
#import <MessageUI/MessageUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <LinkPresentation/LinkPresentation.h>
#import <objc/runtime.h>
#import <objc/message.h>
static NSString *const SAPNativeSharePreference=@"PixieShareAsFile";
static char SAPNativeShareStateKey,SAPNativeShareLayoutTriedKey,SAPNativeShareDelegateKey;
@class SAPNativeShareState;
static SAPNativeShareState *SAPNativeSharePending;
static __weak SAPNativeShareState *SAPNativeShareVisible;
static void (*SAPOriginalPresent)(UIViewController *,SEL,UIViewController *,BOOL,void(^)(void));
static void SAPNativeShareTrace(NSString *event,NSString *type){if(SAPDiagnosticsEnabled())SAP_TRACE("native_share","file_event",0,@{@"event":event,@"payload_type":type?:@"none"});}
static NSDictionary *SAPNativeShareRead(UIViewController *controller){
    if(!controller||!NSThread.isMainThread)return nil;
    Class bridge=NSClassFromString(@"SAPNativeShareBridge");SEL selector=NSSelectorFromString(@"bindingForController:");
    if(![bridge respondsToSelector:selector])return nil;id value=((id(*)(id,SEL,id))objc_msgSend)(bridge,selector,controller);
    return [value isKindOfClass:NSDictionary.class]?value:nil;
}
@interface SAPStockFileTap:UIGestureRecognizer
@property(nonatomic,weak) SAPNativeShareState *owner;
@property(nonatomic) SAPNativeShareIntent action;
@property(nonatomic) CGPoint start;
@end
@interface SAPNativeShareState:NSObject<UIGestureRecognizerDelegate>
@property(nonatomic,weak) UIViewController *controller;
@property(nonatomic,strong) UIStackView *stack,*row;
@property(nonatomic,strong) UIView *chat,*external;
@property(nonatomic,strong) SAPStockFileTap *tap;
@property(nonatomic,strong) UIActivityIndicatorView *spinner;
@property(nonatomic,strong) UISwitch *toggle;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,copy) NSString *uri,*format,*filename,*dataType;
@property(nonatomic,strong) id defaultsObserver;
@property(nonatomic) BOOL fileModeOn,lastPreference,suspended,busy,ready,exportInFlight,nativeHandoff;
@property(nonatomic) BOOL ownsHidden,savedChatHidden,savedExternalHidden,intentAnimated;
@property(nonatomic) NSUInteger generation;
@property(nonatomic,strong) NSArray<NSURL *> *preparedFiles;
@property(nonatomic,strong) NSArray *preparedItems;
@property(nonatomic,strong) NSData *preparedData;
@property(nonatomic,strong) SAPShareFilePromise *filePromise;
@property(nonatomic,strong) SAPShareCompletionRelay *nativeCompletion;
@property(nonatomic,weak) UIActivityViewController *nativeActivity;
@property(nonatomic) SAPNativeShareIntent intent;
@property(nonatomic,strong) UIViewController *intentPresenter,*intentController;
@property(nonatomic,copy) void (^intentCompletion)(void);
- (BOOL)validate;
- (BOOL)allowsFileActions;
- (void)apply;
- (void)restore;
- (void)cancel;
- (void)prepare;
- (void)show:(NSString *)text;
- (void)clearIntent;
- (void)performIntent;
- (void)moreFrom:(UIViewController *)presenter completion:(void(^)(void))completion;
- (SAPNativeShareIntent)actionAtPoint:(CGPoint)point;
- (void)stockTapped:(SAPStockFileTap *)tap;
- (void)failed:(NSString *)error generation:(NSUInteger)generation;
@end
@interface SAPNativeShareMessageDelegate:NSObject<MFMessageComposeViewControllerDelegate>
@property(nonatomic,strong) id<MFMessageComposeViewControllerDelegate> original;
@end
@implementation SAPNativeShareMessageDelegate
- (void)messageComposeViewController:(MFMessageComposeViewController *)controller didFinishWithResult:(MessageComposeResult)result {
    id<MFMessageComposeViewControllerDelegate> original=self.original;self.original=nil;
    if([original respondsToSelector:_cmd])[original messageComposeViewController:controller didFinishWithResult:result];
    else [controller dismissViewControllerAnimated:YES completion:nil];
    objc_setAssociatedObject(controller,&SAPNativeShareDelegateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

// A native cell may contain its icon and caption. It must not contain another
// destination before its bounds can extend a caption's touch target.
static BOOL SAPShareCellMatches(UIView *cell,SAPNativeShareIntent action){
    NSMutableArray *pending=[NSMutableArray arrayWithObject:cell],*labels=[NSMutableArray array];NSUInteger count=0;
    while(pending.count&&count++<32){UIView *view=pending.lastObject;[pending removeLastObject];if(view.hidden||view.alpha<0.01)continue;
        NSString *text=[view isKindOfClass:UILabel.class]?[(UILabel *)view text]:[view isKindOfClass:UIButton.class]?[(UIButton *)view currentTitle]:nil;
        if(text.length)[labels addObject:text];if(view.accessibilityLabel.length)[labels addObject:view.accessibilityLabel];
        [pending addObjectsFromArray:view.subviews];
    }
    return !pending.count&&SAPShareCellMatchesAction(labels,action);
}
@implementation SAPNativeShareState
- (void)dealloc {if(_defaultsObserver)[NSNotificationCenter.defaultCenter removeObserver:_defaultsObserver];}
- (BOOL)validate {NSDictionary *v=SAPNativeShareRead(self.controller);return [v[@"uri"]isEqual:self.uri]&&v[@"stack"]==self.stack;}
- (BOOL)allowsFileActions {return SAPShareTapAllowed(self.fileModeOn&&self.toggle.on&&[NSUserDefaults.standardUserDefaults boolForKey:SAPNativeSharePreference],self.controller.viewIfLoaded.window!=nil,self.suspended,[self validate]);}
- (void)restore {}
- (void)show:(NSString *)text {self.status.text=text;self.status.hidden=!self.fileModeOn||!text.length;if(self.busy)[self.spinner startAnimating];else [self.spinner stopAnimating];}
- (void)apply {
    if(!self.suspended)SAPNativeShareVisible=self;
    BOOL on=[NSUserDefaults.standardUserDefaults boolForKey:SAPNativeSharePreference];self.lastPreference=on;self.fileModeOn=on;self.toggle.on=on;self.tap.enabled=on;
    if(!on){[self cancel];[self restore];self.status.hidden=YES;return;}
    if(self.suspended)return;
    NSDictionary *v=SAPNativeShareRead(self.controller);
    if(![v[@"uri"]isEqual:self.uri]||v[@"stack"]!=self.stack){[self cancel];[self restore];self.tap.enabled=NO;[self show:@"This share item is unavailable."];return;}
    if(v[@"onPlatform"]!=self.chat||v[@"offPlatform"]!=self.external){[self restore];self.chat=v[@"onPlatform"];[self.tap.view removeGestureRecognizer:self.tap];self.external=v[@"offPlatform"];[self.external addGestureRecognizer:self.tap];}
    if(!self.busy)[self show:nil];
}
- (void)changed:(UISwitch *)sender {[NSUserDefaults.standardUserDefaults setBool:sender.on forKey:SAPNativeSharePreference];[self apply];}
- (void)clearIntent {self.intent=SAPNativeShareNone;self.intentController=nil;self.intentPresenter=nil;self.intentCompletion=nil;if(SAPNativeSharePending==self)SAPNativeSharePending=nil;}
- (void)cancel {
    [self.filePromise cancel];self.filePromise=nil;self.nativeHandoff=NO;self.nativeActivity=nil;
    BOOL owned=self.exportInFlight;self.exportInFlight=NO;self.busy=NO;self.ready=NO;self.generation++;[self.spinner stopAnimating];
    [self clearIntent];self.preparedFiles=nil;self.preparedItems=nil;self.preparedData=nil;
    if(owned)SAPCancelAudioExport();
    SAPShareCompletionRelay *relay=self.nativeCompletion;self.nativeCompletion=nil;
    [relay finish:nil completed:NO items:nil error:nil];
}
- (void)failed:(NSString *)error generation:(NSUInteger)generation {
    if(self.generation!=generation)return;
    [self.filePromise resolveFile:nil error:[NSError errorWithDomain:@"PixieShare" code:2 userInfo:@{NSLocalizedDescriptionKey:error?:@"Audio preparation failed."}]];
    self.busy=NO;self.exportInFlight=NO;self.ready=NO;[self show:error?:@"Audio preparation failed."];
    [self clearIntent];self.preparedFiles=nil;self.preparedItems=nil;self.preparedData=nil;
    SAPShareCompletionRelay *relay=self.nativeCompletion;self.nativeCompletion=nil;
    [relay finish:nil completed:NO items:nil error:[NSError errorWithDomain:@"PixieShare" code:2 userInfo:@{NSLocalizedDescriptionKey:error?:@"Audio preparation failed."}]];
}
- (void)prepare {
    if(!SAPShareShouldPrepare(self.fileModeOn,self.intent,self.busy,self.ready)||![self validate])return;
    self.filePromise=[SAPShareFilePromise new];self.format=SAPAudioExportFormat();
    self.busy=YES;self.exportInFlight=YES;NSUInteger generation=++self.generation;
    NSString *uri=[self.uri copy];BOOL album=[uri hasPrefix:@"spotify:album:"];
    [self show:[self.uri hasPrefix:@"spotify:album:"]?@"Preparing album files… Please wait.":@"Preparing track file… Please wait."];SAPNativeShareTrace(@"prepare",album?@"folder":@"audio");
    __weak SAPNativeShareState *weakSelf=self;
    SAPExportAudioURI(uri,^(NSString *progress){
        dispatch_async(dispatch_get_main_queue(),^{SAPNativeShareState *state=weakSelf;if(state.busy && state.generation==generation&&[progress rangeOfString:@"Preparing cover artwork" options:NSCaseInsensitiveSearch].location==NSNotFound)[state show:progress];});
    },^(NSArray<NSURL *> *files,NSString *error){
        dispatch_block_t finish=^{
            SAPNativeShareState *state=weakSelf;if(!state || state.generation!=generation)return;state.exportInFlight=NO;
            BOOL valid=files.count>0 && (album || files.count==1);
            for(id file in files){
                if(![file isKindOfClass:NSURL.class] || ![file isFileURL]){valid=NO;break;}
                BOOL directory=NO;
                if(![NSFileManager.defaultManager fileExistsAtPath:[file path] isDirectory:&directory] || (!album && directory)){valid=NO;break;}
            }
            if(error.length || !valid){[state failed:error?:@"No audio file is available." generation:generation];return;}
            state.preparedFiles=files;
            SAPPrepareAudioExportShareItems(files,album,^(NSArray *items,NSString *shareError){
                SAPNativeShareState *ready=weakSelf;if(!ready || ready.generation!=generation)return;
                if(!items.count){[ready failed:shareError?:@"Could not prepare the audio file." generation:generation];return;}
                ready.preparedItems=items;
                id item=items.firstObject;
                NSURL *shared=[item isKindOfClass:NSURL.class]?item:([item conformsToProtocol:@protocol(UIActivityItemSource)]?[item activityViewControllerPlaceholderItem:nil]:nil);
                [ready.filePromise resolveFile:shared error:nil];
                void (^complete)(NSData *,NSString *,NSString *)=^(NSData *data,NSString *type,NSString *readError){
                    SAPNativeShareState *prepared=weakSelf;if(!prepared || prepared.generation!=generation)return;
                    if(readError.length){[prepared failed:readError generation:generation];return;}
                    prepared.preparedData=data;prepared.dataType=type;prepared.filename=SAPAttachedExportArtwork(files.firstObject)[@"share_filename"]?:files.firstObject.lastPathComponent;
                    prepared.busy=NO;prepared.ready=YES;
                    [prepared show:nil];
                    SAPNativeShareTrace(@"ready",album?@"public.folder":type);
                    [prepared performIntent];
                };
                if(album){complete(nil,nil,nil);return;}
                NSURL *audio=files.firstObject;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{@autoreleasepool {
                    NSError *readError=nil;NSData *data=[NSData dataWithContentsOfURL:audio options:0 error:&readError];
                    UTType *type=[UTType typeWithFilenameExtension:audio.pathExtension];
                    NSString *identifier=[audio.pathExtension.lowercaseString isEqual:@"m4a"]?UTTypeMPEG4Audio.identifier:type.identifier;
                    dispatch_async(dispatch_get_main_queue(),^{complete(data,identifier,(!data.length || !identifier.length)?(readError.localizedDescription?:@"Could not read the audio file."):nil);});
                }});
            });
        };
        // Busy/invalid rejection is synchronous; accepted work finishes on main.
        if(NSThread.isMainThread)finish();else dispatch_async(dispatch_get_main_queue(),finish);
    });
}
- (void)request:(SAPNativeShareIntent)intent presenter:(UIViewController *)presenter controller:(UIViewController *)controller animated:(BOOL)animated completion:(void(^)(void))completion {
    if(![self allowsFileActions])return;
    if(intent==SAPNativeShareMore&&[controller isKindOfClass:UIActivityViewController.class]){
        UIActivityViewController *original=(id)controller;
        UIActivityViewControllerCompletionWithItemsHandler native=[original.completionWithItemsHandler copy];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        UIActivityViewControllerCompletionHandler legacy=native?nil:[original.completionHandler copy];
#pragma clang diagnostic pop
        self.nativeCompletion=[[SAPShareCompletionRelay alloc]initWithCompletion:^(NSString *type,BOOL completed,NSArray *items,NSError *error){
            // Retain the original controller until its callback has run. Its SDK
            // owns Spotify's loading state even though we show a file sheet.
            original.completionWithItemsHandler=nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            original.completionHandler=nil;
#pragma clang diagnostic pop
            if(native)native(type,completed,items,error);else if(legacy)legacy(type,completed);
            SAPNativeShareTrace(@"stock_completion_forwarded",error?@"error":completed?@"sent":@"cancelled");
        }];
    }
    self.intent=intent;self.intentPresenter=presenter;self.intentController=controller;self.intentAnimated=animated;self.intentCompletion=completion;SAPNativeSharePending=self;
    SAPNativeShareTrace(@"file_button",intent==SAPNativeShareCopy?@"copy":intent==SAPNativeShareMore?@"more":@"messages");
    if(self.ready)[self performIntent];else [self prepare];
}
- (void)moreTapped {[self moreFrom:self.controller completion:nil];}
- (void)moreFrom:(UIViewController *)presenter completion:(void(^)(void))completion {
    if(![self allowsFileActions])return;
    presenter=SAPShareAvailablePresenter((id)presenter,(id)self.controller);
    if(!presenter||!presenter.viewIfLoaded.window){[self cancel];[self show:@"Close the open sheet and tap More again."];return;}
    if(!self.ready){[self request:SAPNativeShareMore presenter:self.controller controller:nil animated:YES completion:nil];return;}
    // Open only after the real files and their title/artwork are ready.
    UIActivityViewController *activity=[[UIActivityViewController alloc]initWithActivityItems:self.preparedItems applicationActivities:nil];
    self.nativeHandoff=YES;self.nativeActivity=activity;NSUInteger generation=self.generation;__weak UIActivityViewController *weakActivity=activity;SAPNativeShareState *state=self;
    SAPShareCompletionRelay *nativeCompletion=self.nativeCompletion;self.nativeCompletion=nil;
    activity.completionWithItemsHandler=^(UIActivityType type,BOOL completed,NSArray *items,NSError *error){
        if(state.generation==generation&&state.nativeActivity==weakActivity){state.nativeHandoff=NO;state.nativeActivity=nil;[state cancel];[state apply];}
        [nativeCompletion finish:type completed:completed items:items error:error];
        SAPNativeShareTrace(@"file_sheet_completed",error?@"error":completed?@"sent":@"cancelled");
    };
    activity.popoverPresentationController.sourceView=self.external;activity.popoverPresentationController.sourceRect=self.external.bounds;
    SAPNativeShareTrace(@"stock_more_file_presented",[self.uri hasPrefix:@"spotify:album:"]?@"folder":@"audio");
    [presenter presentViewController:activity animated:YES completion:completion];
}
- (SAPNativeShareIntent)actionAtPoint:(CGPoint)point {
    NSMutableArray *pending=[NSMutableArray arrayWithObject:self.external];NSHashTable *seen=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];NSUInteger visited=0;
    while(pending.count&&visited++<256){id node=pending.lastObject;[pending removeLastObject];if([seen containsObject:node])continue;[seen addObject:node];
        if([node isKindOfClass:UIView.class]&&([(UIView *)node isHidden]||[(UIView *)node alpha]<0.01))continue;
        SAPNativeShareIntent action=SAPShareIntentFromLabel([node respondsToSelector:@selector(accessibilityLabel)]?[node accessibilityLabel]:nil);
        if(action==SAPNativeShareNone)action=SAPShareIntentFromLabel([node respondsToSelector:@selector(accessibilityIdentifier)]?[node accessibilityIdentifier]:nil);
        if(action==SAPNativeShareNone&&[node isKindOfClass:UILabel.class])action=SAPShareIntentFromLabel([(UILabel *)node text]);
        if(action==SAPNativeShareNone&&[node isKindOfClass:UIButton.class])action=SAPShareIntentFromLabel([(UIButton *)node currentTitle]);
        CGRect frame=[node respondsToSelector:@selector(accessibilityFrame)]?[node accessibilityFrame]:CGRectZero;
        if([node isKindOfClass:UIView.class]) {
            UIView *view=node;UIWindow *window=view.window;
            if(window&&CGRectIsEmpty(frame))frame=[window.screen.coordinateSpace convertRect:[view convertRect:view.bounds toView:window] fromCoordinateSpace:window];
            // A label's native cell also contains its icon. Use that cell only,
            // never enlarge the hit target across the entire destination row.
            if(action!=SAPNativeShareNone&&window){
                UIView *cell=view.superview;
                if(cell&&cell!=self.external&&cell.bounds.size.width<=self.external.bounds.size.width*0.45&&cell.bounds.size.width>=view.bounds.size.width&&SAPShareCellMatches(cell,action))
                    frame=[window.screen.coordinateSpace convertRect:[cell convertRect:cell.bounds toView:window] fromCoordinateSpace:window];
            }
        }
        if(action!=SAPNativeShareNone&&!CGRectIsEmpty(frame)&&CGRectContainsPoint(frame,point))return action;
        if([node isKindOfClass:UIView.class]){NSArray *children=[node subviews];if(children.count+pending.count<256)[pending addObjectsFromArray:children];}
        id exposed=[node respondsToSelector:@selector(accessibilityElements)]?[node accessibilityElements]:nil;NSArray *elements=[exposed isKindOfClass:NSArray.class]?exposed:nil;if(elements.count&&elements.count+pending.count<256)[pending addObjectsFromArray:elements];
        if(!elements.count&&[node respondsToSelector:@selector(accessibilityElementCount)]){
            NSInteger count=[node accessibilityElementCount];if(count>0&&count<=64)for(NSInteger i=0;i<count&&pending.count<256;i++){id child=[node accessibilityElementAtIndex:i];if(child)[pending addObject:child];}
        }
    }
    SAPNativeShareTrace(@"stock_tap_unresolved",@"original_action_preserved");return SAPNativeShareNone;
}
- (void)stockTapped:(SAPStockFileTap *)tap {
    if(tap.state!=UIGestureRecognizerStateRecognized||![self allowsFileActions])return;
    if(tap.action==SAPNativeShareMore)[self moreTapped];
    else if(tap.action==SAPNativeShareCopy||tap.action==SAPNativeShareMessage)[self request:tap.action presenter:self.controller controller:nil animated:YES completion:nil];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {return NO;}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)other {return gesture==self.tap&&self.fileModeOn&&!self.suspended;}
- (void)performIntent {
    if(!self.ready || self.intent==SAPNativeShareNone || ![self allowsFileActions])return;
    SAPNativeShareIntent intent=self.intent;UIViewController *presenter=self.intentPresenter,*native=self.intentController;
    BOOL animated=self.intentAnimated;void (^completion)(void)=self.intentCompletion;
    [self clearIntent];
    if(intent==SAPNativeShareMore){[self moreFrom:presenter?:self.controller completion:completion];return;}
    if(intent==SAPNativeShareCopy){
        if(!self.preparedData.length){[self show:@"Copying folders is unavailable. Use More to share the album folder."];return;}
        NSData *data=self.preparedData;NSString *type=self.dataType;
        NSItemProvider *provider=[NSItemProvider new];provider.suggestedName=self.filename;
        [provider registerDataRepresentationForTypeIdentifier:type visibility:NSItemProviderRepresentationVisibilityAll loadHandler:^NSProgress *(void (^done)(NSData *,NSError *)){done(data,nil);return nil;}];
        
        [UIPasteboard.generalPasteboard setItemProviders:@[provider] localOnly:NO expirationDate:nil];
        
        SAPNativeShareTrace(@"payload",type);[self show:@"Audio file copied."];return;
    }
    if(!presenter || !presenter.viewIfLoaded.window || presenter.presentedViewController){[self show:@"Reopen the share menu and try again."];return;}
    if(!self.preparedData.length || ![MFMessageComposeViewController canSendAttachments] || ![MFMessageComposeViewController isSupportedAttachmentUTI:self.dataType]){[self show:@"Messages cannot attach this audio format or an album folder."];return;}
    MFMessageComposeViewController *message=[native isKindOfClass:MFMessageComposeViewController.class]?(id)native:[MFMessageComposeViewController new];
    if(![message addAttachmentData:self.preparedData typeIdentifier:self.dataType filename:self.filename]){[self show:@"Messages could not attach this audio file."];return;}
    SAPNativeShareMessageDelegate *delegate=[SAPNativeShareMessageDelegate new];delegate.original=message.messageComposeDelegate;
    objc_setAssociatedObject(message,&SAPNativeShareDelegateKey,delegate,OBJC_ASSOCIATION_RETAIN_NONATOMIC);message.messageComposeDelegate=delegate;
    SAPNativeShareTrace(@"payload",self.dataType);
    [presenter presentViewController:message animated:animated completion:completion];
}
@end
@implementation SAPStockFileTap
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if(touches.count!=1||![self.owner allowsFileActions]){self.state=UIGestureRecognizerStateFailed;return;}
    UITouch *touch=touches.anyObject;self.start=[touch locationInView:self.view];
    CGPoint screen=[self.view.window.screen.coordinateSpace convertPoint:[touch locationInView:self.view.window] fromCoordinateSpace:self.view.window];
    self.action=[self.owner actionAtPoint:screen];if(self.action==SAPNativeShareNone)self.state=UIGestureRecognizerStateFailed;
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {CGPoint p=[touches.anyObject locationInView:self.view];if(hypot(p.x-self.start.x,p.y-self.start.y)>10)self.state=UIGestureRecognizerStateFailed;}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {self.state=self.action!=SAPNativeShareNone&&[self.owner allowsFileActions]?UIGestureRecognizerStateRecognized:UIGestureRecognizerStateFailed;}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {self.state=UIGestureRecognizerStateCancelled;}
- (void)reset {[super reset];self.action=SAPNativeShareNone;}
- (BOOL)canPreventGestureRecognizer:(UIGestureRecognizer *)other {return self.action!=SAPNativeShareNone?YES:[super canPreventGestureRecognizer:other];}
- (BOOL)canBePreventedByGestureRecognizer:(UIGestureRecognizer *)other {return self.action!=SAPNativeShareNone?NO:[super canBePreventedByGestureRecognizer:other];}
@end
static SAPNativeShareState *SAPNativeShareBind(UIViewController *controller){
    SAPNativeShareState *state=objc_getAssociatedObject(controller,&SAPNativeShareStateKey);if(state)return state;
    NSDictionary *v=SAPNativeShareRead(controller);if(!v)return nil;
    state=[SAPNativeShareState new];state.controller=controller;state.uri=v[@"uri"];state.stack=v[@"stack"];state.chat=v[@"onPlatform"];state.external=v[@"offPlatform"];
    state.tap=[[SAPStockFileTap alloc]initWithTarget:state action:@selector(stockTapped:)];state.tap.owner=state;state.tap.delegate=state;state.tap.cancelsTouchesInView=YES;state.tap.delaysTouchesBegan=YES;[state.external addGestureRecognizer:state.tap];
    UILabel *title=[UILabel new];title.text=@"Share as file";title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];title.textColor=UIColor.labelColor;
    state.toggle=[UISwitch new];state.toggle.accessibilityLabel=@"Share as file";[state.toggle addTarget:state action:@selector(changed:) forControlEvents:UIControlEventValueChanged];
    UIStackView *heading=[[UIStackView alloc]initWithArrangedSubviews:@[title,state.toggle]];heading.axis=UILayoutConstraintAxisHorizontal;heading.alignment=UIStackViewAlignmentCenter;heading.spacing=12;[title setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    state.status=[UILabel new];state.status.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];state.status.textColor=UIColor.secondaryLabelColor;state.status.numberOfLines=0;
    state.spinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];state.spinner.hidesWhenStopped=YES;
    UIStackView *progress=[[UIStackView alloc]initWithArrangedSubviews:@[state.spinner,state.status]];progress.axis=UILayoutConstraintAxisHorizontal;progress.alignment=UIStackViewAlignmentCenter;progress.spacing=8;
    state.row=[[UIStackView alloc]initWithArrangedSubviews:@[heading,progress]];state.row.axis=UILayoutConstraintAxisVertical;state.row.spacing=8;state.row.layoutMarginsRelativeArrangement=YES;state.row.layoutMargins=UIEdgeInsetsMake(12,16,12,16);
    [state.stack addArrangedSubview:state.row];objc_setAssociatedObject(controller,&SAPNativeShareStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __weak SAPNativeShareState *weak=state;
    state.defaultsObserver=[NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:NSUserDefaults.standardUserDefaults queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){SAPNativeShareState *s=weak;if(s&&!s.suspended&&s.lastPreference!=[NSUserDefaults.standardUserDefaults boolForKey:SAPNativeSharePreference])[s apply];}];
    [state apply];return state;
}
static void SAPNativeShareReplace(Class cls,SEL selector,IMP replacement){Method m=class_getInstanceMethod(cls,selector);if(!m)return;if(!class_addMethod(cls,selector,replacement,method_getTypeEncoding(m)))class_replaceMethod(cls,selector,replacement,method_getTypeEncoding(m));}
static void SAPNativeShareLifecycle(Class cls,SEL selector,BOOL animated,BOOL disappearing){
    Method m=class_getInstanceMethod(cls,selector);if(!m||method_getNumberOfArguments(m)!=(animated?3:2))return;
    char result[8]={0};method_getReturnType(m,result,sizeof(result));if(strcmp(result,"v"))return;
    if(animated){char arg[8]={0};method_getArgumentType(m,2,arg,sizeof(arg));if(strcmp(arg,"B")&&strcmp(arg,"c"))return;}
    IMP original=method_getImplementation(m),replacement;
    if(animated)replacement=imp_implementationWithBlock(^(UIViewController *controller,BOOL flag){
        ((void(*)(id,SEL,BOOL))original)(controller,selector,flag);if(object_getClass(controller)!=cls)return;
        SAPNativeShareState *state=disappearing?objc_getAssociatedObject(controller,&SAPNativeShareStateKey):SAPNativeShareBind(controller);state.suspended=disappearing;state.tap.enabled=!disappearing&&state.fileModeOn;
        if(disappearing){[state restore];if(!state.nativeHandoff)[state cancel];}else [state apply];
    });
    else replacement=imp_implementationWithBlock(^(UIViewController *controller){
        ((void(*)(id,SEL))original)(controller,selector);if(object_getClass(controller)!=cls||objc_getAssociatedObject(controller,&SAPNativeShareStateKey))return;
        if(selector==@selector(viewDidLayoutSubviews)){if(objc_getAssociatedObject(controller,&SAPNativeShareLayoutTriedKey))return;objc_setAssociatedObject(controller,&SAPNativeShareLayoutTriedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
        SAPNativeShareBind(controller);
    });
    SAPNativeShareReplace(cls,selector,replacement);
}
// Spotify may provide no public accessibility caption for its More button.
// Intercept the resulting public activity presentation instead, only while the
// exact bound Spotify menu owns that presenter and file mode is enabled.
static void SAPNativeSharePresent(UIViewController *presenter,SEL selector,UIViewController *modal,BOOL animated,void(^completion)(void)) {
    SAPNativeShareState *state=SAPNativeShareVisible;
    BOOL activity=[modal isKindOfClass:UIActivityViewController.class];
    if(activity&&!state)SAPNativeShareTrace(@"stock_activity_presentation",@"no_bound_native_menu");
    if(activity&&state&&modal!=state.nativeActivity) {
        BOOL owns=SAPShareAvailablePresenter((id)presenter,(id)state.controller)!=nil;
        BOOL enabled=[state allowsFileActions];
        SAPNativeShareTrace(@"stock_activity_presentation",enabled?(owns?@"file_intercept":@"different_presenter"):@"file_mode_inactive");
        if(enabled&&owns){
            if(state.intent==SAPNativeShareNone)[state request:SAPNativeShareMore presenter:presenter controller:modal animated:animated completion:completion];
            return;
        }
    }
    SAPOriginalPresent(presenter,selector,modal,animated,completion);
}
static void SAPInstallSharePresentationGate(void) {
    Method method=class_getInstanceMethod(UIViewController.class,@selector(presentViewController:animated:completion:));
    if(!method||method_getNumberOfArguments(method)!=5)return;
    SAPOriginalPresent=(void *)method_getImplementation(method);
    method_setImplementation(method,(IMP)SAPNativeSharePresent);
}
void SAPInstallNativeShareHooks(void){static dispatch_once_t once;dispatch_once(&once,^{SAPInstallSharePresentationGate();for(NSString *name in @[@"_TtC14Share_MenuImpl29NativeShareMenuViewController",@"_TtC14Share_MenuImpl29LegacyShareMenuViewController"]){Class cls=NSClassFromString(name);if(!cls||![cls isSubclassOfClass:UIViewController.class])continue;SAPNativeShareLifecycle(cls,@selector(viewDidLoad),NO,NO);SAPNativeShareLifecycle(cls,@selector(viewDidLayoutSubviews),NO,NO);SAPNativeShareLifecycle(cls,@selector(viewDidAppear:),YES,NO);SAPNativeShareLifecycle(cls,@selector(viewDidDisappear:),YES,YES);}});}
