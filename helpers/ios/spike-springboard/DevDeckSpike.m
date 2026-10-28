// EXPERIMENT ONLY. Not part of the DevDeck companion app or its build.
//
// Feasibility spike: when injected into the iOS *simulator's* SpringBoard (DYLD_INSERT_LIBRARIES
// via the simulator's launchd), draws a small always-on-top pill near the top of the screen,
// controlled from the Mac by a host file (simulator processes can read host paths):
//   echo agent > /tmp/devdeck-spike-state   (purple "AGENT")
//   echo user  > /tmp/devdeck-spike-state   (green "YOU")
//   echo free  > /tmp/devdeck-spike-state   (hidden)
// It is a no-op in every process other than SpringBoard. See run-spike.sh.
#import <UIKit/UIKit.h>

static NSString *const kStatePath = @"/tmp/devdeck-spike-state";
static UIWindow *gWindow;
static UILabel *gPill;
static NSString *gLastState;

@interface DevDeckSpikeWindow : UIWindow
@end
@implementation DevDeckSpikeWindow
// Never take touches; everything passes through to whatever is below.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }
// Private UIKit hook: without it a visible top-level window hides SpringBoard's status bar.
- (BOOL)_canAffectStatusBarAppearance { return NO; }
@end

static void apply(NSString *state) {
    if ([state isEqualToString:gLastState]) return;
    gLastState = state;
    if ([state isEqualToString:@"agent"]) {
        gPill.text = @"AGENT";
        gPill.backgroundColor = UIColor.systemPurpleColor;
        gPill.hidden = NO;
    } else if ([state isEqualToString:@"user"]) {
        gPill.text = @"YOU";
        gPill.backgroundColor = [UIColor colorWithRed:0.451 green:0.859 blue:0.549 alpha:1];
        gPill.hidden = NO;
    } else {
        gPill.hidden = YES;
    }
    NSLog(@"[devdeck-spike] state -> %@", state);
}

// Variant B (default): no window of our own; the pill goes into SpringBoard's existing System
// Aperture (Dynamic Island) window, which already sits above apps. A separate SpringBoard
// UIWindow (variant A, -DSPIKE_OWN_WINDOW) works too but hides the status bar over apps.
static void install(void) {
#ifdef SPIKE_NO_WINDOW
    NSLog(@"[devdeck-spike] SPIKE_NO_WINDOW: not creating a window");
    return;
#endif
    UIWindowScene *mainScene = nil, *apertureScene = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        NSString *pid = s.session.persistentIdentifier;
        if ([pid isEqualToString:@"SB-main"]) mainScene = (UIWindowScene *)s;
        if ([pid isEqualToString:@"SB-systemAperture"]) apertureScene = (UIWindowScene *)s;
    }
    CGRect bounds = (mainScene ?: apertureScene).coordinateSpace.bounds;
    CGRect pillFrame = CGRectMake((bounds.size.width - 64) / 2, 62, 64, 20);

    UIView *host = nil;
#ifndef SPIKE_OWN_WINDOW
    for (UIWindow *w in apertureScene.windows) {
        NSLog(@"[devdeck-spike] aperture window %@", w);
        if (!host && !w.hidden && CGRectContainsRect(w.bounds, pillFrame)) host = w;
    }
#endif
    if (!host) {
        // Variant A: our own small window just below the status bar level.
        gWindow = [[DevDeckSpikeWindow alloc] initWithWindowScene:mainScene];
        gWindow.frame = pillFrame;
        gWindow.windowLevel = UIWindowLevelStatusBar - 1;
        gWindow.backgroundColor = UIColor.clearColor;
        gWindow.userInteractionEnabled = NO;
        gWindow.hidden = NO;
        host = gWindow;
        pillFrame.origin = CGPointZero;
    }
    NSLog(@"[devdeck-spike] hosting pill in %@", host);

    gPill = [UILabel new];
    gPill.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    gPill.textColor = UIColor.whiteColor;
    gPill.textAlignment = NSTextAlignmentCenter;
    gPill.layer.cornerRadius = 10;
    gPill.layer.masksToBounds = YES;
    gPill.userInteractionEnabled = NO;
    gPill.frame = pillFrame;
    gPill.hidden = YES;
    [host addSubview:gPill];

    // Poll the host file once a second (a spike; a real one would use a Darwin notification).
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        [gPill.superview bringSubviewToFront:gPill];
        NSString *s = [NSString stringWithContentsOfFile:kStatePath encoding:NSUTF8StringEncoding error:nil];
        apply([s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"free");
    }];
}

__attribute__((constructor)) static void DevDeckSpikeInit(void) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    NSLog(@"[devdeck-spike] loaded into SpringBoard (pid %d)", getpid());
    // Give SpringBoard time to finish bringing up its scenes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        install();
    });
}
