#import <substrate.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <UserNotifications/UserNotifications.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <NetworkExtension/NetworkExtension.h>
#import <objc/runtime.h>
#import <time.h>

// ========== 限流配置 ==========
#define FLOOD_INTERVAL 3
#define FLOOD_MAX_COUNT 2
#define BLOCK_DURATION 120
static time_t lastTriggerTime = 0;
static int triggerCount = 0;
static time_t blockUntilTime = 0;

static BOOL FloodLocked(void) {
    return time(NULL) < blockUntilTime;
}
static void FloodTick(void) {
    time_t now = time(NULL);
    if (now - lastTriggerTime > FLOOD_INTERVAL) {
        triggerCount = 0;
        lastTriggerTime = now;
    }
    triggerCount++;
    if (triggerCount >= FLOOD_MAX_COUNT) {
        blockUntilTime = now + BLOCK_DURATION;
    }
}

// ========== 1. 静默推送拦截 ==========
static IMP orig_DidFinishLaunching = NULL;
static IMP orig_DidReceiveRemote = NULL;
static IMP orig_SetDelegate = NULL;

static BOOL hook_DidFinishLaunching(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    NSDictionary *push = opts[UIApplicationLaunchOptionsRemoteNotificationKey];
    if (push && push[@"aps"] && push[@"aps"][@"content-available"]) {
        FloodTick();
        if (FloodLocked()) {}
        exit(0);
    }
    return ((BOOL(*)(id,SEL,UIApplication*,NSDictionary*))orig_DidFinishLaunching)(self, _cmd, app, opts);
}

static void hook_DidReceiveRemote(id self, SEL _cmd, UIApplication *app, NSDictionary *info, void (^done)(UIBackgroundFetchResult)) {
    if (info[@"aps"] && info[@"aps"][@"content-available"]) {
        FloodTick();
        done(UIBackgroundFetchResultNoData);
        return;
    }
    ((void(*)(id,SEL,UIApplication*,NSDictionary*,void(^)(UIBackgroundFetchResult)))orig_DidReceiveRemote)(self, _cmd, app, info, done);
}

static void hook_SetDelegate(id self, SEL _cmd, id delegate) {
    if (orig_SetDelegate) {
        ((void(*)(id,SEL,id))orig_SetDelegate)(self, _cmd, delegate);
    }
    if (!delegate) return;
    Class cls = [delegate class];
    Method m;

    m = class_getInstanceMethod(cls, @selector(application:didFinishLaunchingWithOptions:));
    if (m && !orig_DidFinishLaunching) {
        orig_DidFinishLaunching = method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_DidFinishLaunching);
    }

    m = class_getInstanceMethod(cls, @selector(application:didReceiveRemoteNotification:fetchCompletionHandler:));
    if (m && !orig_DidReceiveRemote) {
        orig_DidReceiveRemote = method_getImplementation(m);
        method_setImplementation(m, (IMP)hook_DidReceiveRemote);
    }
}

// ========== 2. BGTask ==========
%hook BGTaskScheduler
- (BOOL)submitTaskRequest:(BGTaskRequest *)req error:(NSError **)err {
    if (err) *err = [NSError errorWithDomain:@"BlockAlipay" code:-999 userInfo:nil];
    return NO;
}
%end

// ========== 3. Hotspot ==========
%hook NEHotspotHelper
+ (BOOL)registerWithOptions:(NSDictionary *)opts queue:(dispatch_queue_t)q handler:(id)h {
    return NO;
}
%end

// ========== 4. 位置 ==========
%hook CLLocationManager
- (void)startMonitoringSignificantLocationChanges {}
- (void)startMonitoringForRegion:(CLRegion *)region {}
%end

// ========== 5. 入口 ==========
%ctor {
    Method sm = class_getInstanceMethod([UIApplication class], @selector(setDelegate:));
    if (sm) {
        orig_SetDelegate = method_getImplementation(sm);
        method_setImplementation(sm, (IMP)hook_SetDelegate);
    }
}
