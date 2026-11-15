#import "ArtistDownloadComponents.h"
#import "ArtistArtworkLoader.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "ProgressAnimation.h"

UIImage *SAPArtistArtworkPlaceholder(void) {
    static UIImage *image;static dispatch_once_t once;dispatch_once(&once,^{
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc]initWithSize:CGSizeMake(52,52)];
        image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
            [[UIColor colorWithWhite:.20 alpha:1]setFill];[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,52,52) cornerRadius:8]fill];
            UIImage *glyph=[[UIImage systemImageNamed:@"music.note"]imageWithTintColor:UIColor.tertiaryLabelColor];
            [glyph drawInRect:CGRectMake(17,17,18,18)];
        }];
    });return image;
}


@implementation SAPArtistProgressAccessory { CAShapeLayer *_progressRing; }
- (instancetype)initWithDownloaded:(NSUInteger)downloaded total:(NSUInteger)total progress:(double)progress {
    if((self=[super initWithFrame:CGRectMake(0,0,40,40)])) {
        CGPoint center=CGPointMake(20,20);CGFloat radius=13.5;
        UIBezierPath *path=[UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:-M_PI_2 endAngle:M_PI*1.5 clockwise:YES];
        CAShapeLayer *track=[CAShapeLayer layer];track.path=path.CGPath;track.fillColor=UIColor.clearColor.CGColor;
        track.strokeColor=[UIColor colorWithWhite:.32 alpha:1].CGColor;track.lineWidth=2.5;[self.layer addSublayer:track];
        CAShapeLayer *ring=[CAShapeLayer layer];ring.path=path.CGPath;ring.fillColor=UIColor.clearColor.CGColor;
        ring.strokeColor=[UIColor colorWithRed:1 green:.66 blue:.18 alpha:1].CGColor;ring.lineWidth=2.5;ring.lineCap=kCALineCapRound;
        _progressRing=ring;[self.layer addSublayer:ring];
        UIImageSymbolConfiguration *arrowStyle=[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        UIImageView *arrow=[[UIImageView alloc]initWithImage:[UIImage systemImageNamed:@"arrow.down" withConfiguration:arrowStyle]];arrow.preferredSymbolConfiguration=arrowStyle;arrow.tintColor=UIColor.systemOrangeColor;arrow.contentMode=UIViewContentModeScaleAspectFit;arrow.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:arrow];
        [NSLayoutConstraint activateConstraints:@[[arrow.widthAnchor constraintEqualToConstant:16],[arrow.heightAnchor constraintEqualToConstant:16],[arrow.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],[arrow.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]]];
        self.isAccessibilityElement=YES;[self updateDownloaded:downloaded total:total progress:progress];
    }
    return self;
}
- (void)updateDownloaded:(NSUInteger)downloaded total:(NSUInteger)total progress:(double)progress {
    SAPSetProgressRing(_progressRing,progress,self.window!=nil && !UIAccessibilityIsReduceMotionEnabled());
    self.accessibilityLabel=[NSString stringWithFormat:@"Partially downloaded, %lu of %lu tracks",(unsigned long)downloaded,(unsigned long)total];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if(!self.window)SAPSetProgressRing(_progressRing,_progressRing.strokeEnd,NO);
}
@end

NSString *SAPArtistReleaseCategoryTitle(NSDictionary *release) {
    NSString *category=release[@"category"];
    if(![category isEqualToString:@"Appears on"])return category;
    NSString *type;
    switch([release[@"type"]unsignedIntegerValue]) {
        case 1:type=@"Album";break;
        case 2:type=@"Single";break;
        case 3:type=@"Compilation";break;
        case 4:type=@"EP";break;
        default:type=@"Unknown type";break;
    }
    return [NSString stringWithFormat:@"Appears on (%@)",type];
}

NSString *SAPArtistTrackCounter(NSUInteger downloaded,NSUInteger total) {
    NSString *downloadedText=[NSString stringWithFormat:@"%lu",(unsigned long)downloaded];
    NSUInteger totalDigits=[NSString stringWithFormat:@"%lu",(unsigned long)total].length;
    if(downloadedText.length<totalDigits) {
        NSString *padding=[@"" stringByPaddingToLength:totalDigits-downloadedText.length withString:@" " startingAtIndex:0];
        downloadedText=[padding stringByAppendingString:downloadedText];
    }
    return [NSString stringWithFormat:@"%@ / %lu tracks",downloadedText,(unsigned long)total];
}

UIImageView *SAPArtistStateIcon(NSString *symbol,UIColor *color,NSString *label) {
    UIImageView *view=[[UIImageView alloc]initWithImage:[UIImage systemImageNamed:symbol]];
    view.tintColor=color;view.contentMode=UIViewContentModeScaleAspectFit;view.frame=CGRectMake(0,0,32,32);
    view.isAccessibilityElement=YES;view.accessibilityLabel=label;return view;
}


@implementation SAPArtistReleaseCell
- (void)cancelArtworkLoad {
    dispatch_block_t cancel=self.cancelArtwork;self.cancelArtwork=nil;
    if(cancel){cancel();objc_setAssociatedObject(self,&SAPArtistArtworkURLKey,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);}
}
- (void)prepareForReuse {[super prepareForReuse];[self cancelArtworkLoad];self.progressIndicator=nil;self.renderedRelease=nil;self.renderedState=nil;}
- (void)dealloc {if(_cancelArtwork)_cancelArtwork();}
- (UIView *)indicatorForState:(NSDictionary *)state {
    NSString *kind=state[@"state"];
    NSDictionary *stopped=state[@"stopped_visual"];
    BOOL frozen=![kind isEqual:@"downloaded"] && stopped.count && ([state[@"can_continue"]boolValue] || [state[@"stopping"]boolValue] || [state[@"stop_pending"]boolValue]);
    if([kind isEqual:@"partial"] || frozen) {
        NSDictionary *display=frozen?stopped:state;
        NSUInteger done=[display[@"downloaded_tracks"]unsignedIntegerValue],total=[display[@"total_tracks"]unsignedIntegerValue];double value=[display[@"progress"]doubleValue];
        if(!self.progressIndicator)self.progressIndicator=[[SAPArtistProgressAccessory alloc]initWithDownloaded:done total:total progress:value];
        else [self.progressIndicator updateDownloaded:done total:total progress:value];
        if(frozen)self.progressIndicator.accessibilityLabel=[NSString stringWithFormat:@"Stopped. Last download progress: %.0f percent",MIN(1,MAX(0,value))*100];
        self.indicatorKind=frozen?@"stopped":kind;return self.progressIndicator;
    }
    if(!self.staticIndicator)self.staticIndicator=SAPArtistStateIcon(@"arrow.down.circle",UIColor.secondaryLabelColor,@"Not downloaded");
    if(![self.indicatorKind isEqual:kind]) {
        BOOL full=[kind isEqual:@"downloaded"],unknown=[kind isEqual:@"unknown"];
        self.staticIndicator.image=[UIImage systemImageNamed:full?@"checkmark.circle":unknown?@"questionmark.circle":@"arrow.down.circle"];
        self.staticIndicator.tintColor=full?UIColor.systemGreenColor:UIColor.secondaryLabelColor;
        self.staticIndicator.accessibilityLabel=full?@"Downloaded":unknown?@"Download state unavailable":@"Not downloaded";
        self.indicatorKind=kind;
    }
    return self.staticIndicator;
}
- (void)installIndicatorLayout {
    if(!self.indicatorHost) {
        self.indicatorHost=[UIView new];self.indicatorHost.translatesAutoresizingMaskIntoConstraints=NO;
        self.indicatorHost.userInteractionEnabled=NO;self.indicatorHost.accessibilityIdentifier=@"PixieAlbumStatus";
    }
    if(self.indicatorHost.superview==self.contentView)return;
    [NSLayoutConstraint deactivateConstraints:self.indicatorConstraints?:@[]];
    [self.indicatorHost removeFromSuperview];[self.contentView addSubview:self.indicatorHost];
    self.indicatorConstraints=@[
        [self.indicatorHost.widthAnchor constraintEqualToConstant:40],
        [self.indicatorHost.heightAnchor constraintEqualToConstant:40],
        [self.indicatorHost.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],
        [self.indicatorHost.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ];
    [NSLayoutConstraint activateConstraints:self.indicatorConstraints];
}
- (void)setDownloadIndicator:(UIView *)indicator {
    [self installIndicatorLayout];
    if(self.downloadIndicator==indicator)return;
    [NSLayoutConstraint deactivateConstraints:self.indicatorChildConstraints?:@[]];
    for(UIView *previous in self.indicatorHost.subviews)[previous removeFromSuperview];
    _downloadIndicator=indicator;
    CGSize size=[indicator isKindOfClass:SAPArtistProgressAccessory.class]?CGSizeMake(40,40):CGSizeMake(32,32);indicator.translatesAutoresizingMaskIntoConstraints=NO;
    [self.indicatorHost addSubview:indicator];
    self.indicatorChildConstraints=@[
        [indicator.widthAnchor constraintEqualToConstant:size.width],
        [indicator.heightAnchor constraintEqualToConstant:size.height],
        [indicator.centerXAnchor constraintEqualToAnchor:self.indicatorHost.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:self.indicatorHost.centerYAnchor]
    ];[NSLayoutConstraint activateConstraints:self.indicatorChildConstraints];
}
@end


@implementation SAPArtistCategoryHeader
- (instancetype)initWithReuseIdentifier:(NSString *)identifier {
    if((self=[super initWithReuseIdentifier:identifier])) {
        self.categoryTitle=[UILabel new];self.categoryTitle.translatesAutoresizingMaskIntoConstraints=NO;
        self.categoryTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        self.categoryTitle.adjustsFontForContentSizeCategory=YES;self.categoryTitle.textColor=UIColor.secondaryLabelColor;
        self.categoryTitle.numberOfLines=1;
        self.catalogProgressLabel=[UILabel new];self.catalogProgressLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.catalogProgressLabel.textColor=UIColor.secondaryLabelColor;self.catalogProgressLabel.adjustsFontSizeToFitWidth=YES;self.catalogProgressLabel.minimumScaleFactor=.7;self.catalogProgressLabel.hidden=YES;
        UIStackView *titles=[[UIStackView alloc]initWithArrangedSubviews:@[self.categoryTitle,self.catalogProgressLabel]];titles.axis=UILayoutConstraintAxisHorizontal;titles.alignment=UIStackViewAlignmentCenter;titles.spacing=8;titles.translatesAutoresizingMaskIntoConstraints=NO;
        self.selectionButton=[UIButton buttonWithType:UIButtonTypeCustom];self.selectionButton.translatesAutoresizingMaskIntoConstraints=NO;
        UIImageSymbolConfiguration *selectionSymbol=[UIImageSymbolConfiguration configurationWithPointSize:17.0*1.2 weight:UIImageSymbolWeightRegular];
        [self.selectionButton setImage:[UIImage systemImageNamed:@"circle" withConfiguration:selectionSymbol] forState:UIControlStateNormal];
        [self.selectionButton setImage:[UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:selectionSymbol] forState:UIControlStateSelected];
        self.selectionButton.tintColor=UIColor.systemGreenColor;
        self.selectionButton.accessibilityIdentifier=@"PixieArtistCategorySelection";
        [self.contentView addSubview:titles];[self.contentView addSubview:self.selectionButton];
        UILayoutGuide *margins=self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [titles.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [titles.centerYAnchor constraintEqualToAnchor:self.selectionButton.centerYAnchor],
            [titles.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectionButton.leadingAnchor constant:-8],
            [titles.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
            [titles.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [self.selectionButton.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [self.selectionButton.widthAnchor constraintEqualToConstant:44],
            [self.selectionButton.heightAnchor constraintEqualToConstant:44],
            [self.selectionButton.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:4],
            [self.selectionButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4]
        ]];
    }
    return self;
}
@end

