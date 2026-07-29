#import <substrate.h>
#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <UserNotifications/UserNotifications.h>
#import <BackgroundTasks/BackgroundTasks.h>
#import <NetworkExtension/NetworkExtension.h>
#import <objc/runtime.h>
#import <time.h>

// ========== 文件日志（沙盒 Documents，注入 dylib 不能写系统目录） ==========
#define LOG_MAX_SIZE (512 * 1024)
#define LOG_KEEP_SIZE (256 * 1024)

static NSFileHandle *logHandle = nil;
static NSDateFormatter *logFmt = nil;
static NSString *logPath = nil;

static void BA_Log(NSString *fmt, ...) {
    if (!logPath) {
        NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        logPath = [docs stringByAppendingPathComponent:@"BlockAlipay_debug.log"];
    }
    va_list args;
    va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    if (!logFmt) {
        logFmt = [NSDateFormatter new];
        logFmt.dateFormat = @"MM-dd HH:mm:ss";
    }
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [logFmt stringFromDate:[NSDate date]], msg];
    @try {
        NSDictionary *attr = [[NSFileManager defaultManager] attributesOfItemAtPath:logPath error:nil];
        if (attr && [attr[NSFileSize] unsignedLongLongValue] > LOG_MAX_SIZE) {
            NSData *existing = [NSData dataWithContentsOfFile:logPath];
            NSUInteger keepStart = existing.length > LOG_KEEP_SIZE ? existing.length - LOG_KEEP_SIZE : 0;
            NSData *keep = [existing subdataWithRange:NSMakeRange(keepStart, existing.length - keepStart)];
            [keep writeToFile:logPath atomically:YES];
            logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            [logHandle seekToEndOfFile];
        }
        if (!logHandle) {
            [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
            logHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
            [logHandle seekToEndOfFile];
        }
        [logHandle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) {}
}

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
        BA_Log(@"频繁唤醒，封锁 %ds", BLOCK_DURATION);
    }
}

// ========== 1. 静默推送拦截 ==========
static IMP orig_DidFinishLaunching = NULL;
static IMP orig_DidReceiveRemote = NULL;
static IMP orig_SetDelegate = NULL;

static BOOL hook_DidFinishLaunching(id self, SEL _cmd, UIApplication *app, NSDictionary *opts) {
    NSDictionary *push = opts[UIApplicationLaunchOptionsRemoteNotificationKey];
    if (push && push[@"aps"] && push[@"aps"][@"content-available"]) {
        BA_Log(@"静默推送冷启动，退出进程");
        FloodTick();
        if (FloodLocked()) {
            BA_Log(@"封锁期内，直接退出");
        }
        exit(0);
    }
    return ((BOOL(*)(id,SEL,UIApplication*,NSDictionary*))orig_DidFinishLaunching)(self, _cmd, app, opts);
}

static void hook_DidReceiveRemote(id self, SEL _cmd, UIApplication *app, NSDictionary *info, void (^done)(UIBackgroundFetchResult)) {
    if (info[@"aps"] && info[@"aps"][@"content-available"]) {
        BA_Log(@"后台静默推送，丢弃");
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

    BA_Log(@"AppDelegate hooks installed on %@", NSStringFromClass(cls));
}

// ========== 2. BGTask ==========
%hook BGTaskScheduler
- (BOOL)submitTaskRequest:(BGTaskRequest *)req error:(NSError **)err {
    BA_Log(@"拦截 BGTask 注册: %@", req);
    if (err) *err = [NSError errorWithDomain:@"BlockAlipay" code:-999 userInfo:nil];
    return NO;
}
%end

// ========== 3. Hotspot ==========
%hook NEHotspotHelper
+ (BOOL)registerWithOptions:(NSDictionary *)opts queue:(dispatch_queue_t)q handler:(id)h {
    BA_Log(@"拦截 Hotspot 网络监听");
    return NO;
}
%end

// ========== 4. 位置 ==========
%hook CLLocationManager
- (void)startMonitoringSignificantLocationChanges {
    BA_Log(@"拦截显著位置变化监听");
}
- (void)startMonitoringForRegion:(CLRegion *)region {
    BA_Log(@"拦截地理围栏: %@", region.identifier);
}
%end

// ========== 5. 入口 ==========
%ctor {
    BA_Log(@"========== BlockAlipayApp v1.1 注入 ==========");

    Method sm = class_getInstanceMethod([UIApplication class], @selector(setDelegate:));
    if (sm) {
        orig_SetDelegate = method_getImplementation(sm);
        method_setImplementation(sm, (IMP)hook_SetDelegate);
        BA_Log(@"setDelegate: hook installed");
    } else {
        BA_Log(@"ERROR: setDelegate: not found");
    }
}
