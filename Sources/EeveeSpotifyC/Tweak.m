#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Tweak.h"

// NO_JBROOT（Makefile: NO_JBROOT=1）给 IPA / TrollStore 用：不导入 libroot.h，
// 于是也不会链上 /var/jb/usr/lib/libroot.dylib。这很关键 —— libroot 是加载期
// 依赖，TrollStore 设备上没有 /var/jb，dyld 一失败整个 App 就起不来。
#if NO_JBROOT
// 故意什么都不导入。
#elif THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

NSString *EeveeJBRootPath(NSString *path) {
#if NO_JBROOT
    // 无越狱环境：路径本来就是对的（BundleHelper 先找 main bundle，
    // 只有找不到时才拿这里的返回值兜底）。
    return path;
#elif THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

// ── 底色拦截从上游 `EncoreBridge.m` 移植；A）
//
// 迷你播放条闪的就是这一条：我们把内容视图的底色清成透明 → Spotify 下一帧又写回
// `bg=#64204C`→ 我们靠"每拍清一次 + 50ms 补清 + 0.5s 复查"去追，
// 而**追的过程本身就是闪**。
//
// 上游的做法是在**层**上断根：给这一层的 CALayer 造一个只有它自己用的子类，
// 把 `setBackgroundColor:` 改写成"只回报颜色，永远不落盘"。
static char kEeveeColorSinkKey;
static char kEeveeOriginalLayerClassKey;

BOOL EeveeInterceptBackground(UIView *view, void (^sink)(UIColor *color)) {
    if (!view) return NO;
    CALayer *layer = view.layer;
    Class original = object_getClass(layer);
    NSString *originalName = NSStringFromClass(original);

    // 已经装过（同一个实例重复调用）⇒ 只更新 sink，别再包一层。
    objc_setAssociatedObject(layer, &kEeveeColorSinkKey, sink, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if ([originalName hasPrefix:@"EeveeBG_"]) return YES;
    // Swift 类名带 "."、KVO 子类带 NSKVONotifying_：这两类不适合再继承一层，直接放弃。
    if ([originalName containsString:@"."] || [originalName hasPrefix:@"NSKVONotifying_"]) return NO;

    NSString *name = [@"EeveeBG_" stringByAppendingString:originalName];
    Class subclass = NSClassFromString(name);
    if (!subclass) {
        subclass = objc_allocateClassPair(original, name.UTF8String, 0);
        if (!subclass) return NO;
        IMP setter = imp_implementationWithBlock(^(CALayer *self_, CGColorRef color) {
            void (^current)(UIColor *) = objc_getAssociatedObject(self_, &kEeveeColorSinkKey);
            if (current && color && CGColorGetAlpha(color) > 0.01) {
                current([UIColor colorWithCGColor:color]);
            }
            struct objc_super parent = { self_, original };
            ((void (*)(struct objc_super *, SEL, CGColorRef))objc_msgSendSuper)(
                &parent, @selector(setBackgroundColor:), current ? NULL : color);
        });
        class_addMethod(subclass, @selector(setBackgroundColor:), setter, "v@:^{CGColor=}");
        // `-class` 报原类：`isKindOfClass:` / 描述 / 第三方断言都照旧。
        class_addMethod(
            subclass, @selector(class),
            imp_implementationWithBlock(^Class(id self_) { return original; }),
            "#@:"
        );
        objc_registerClassPair(subclass);
    }

    objc_setAssociatedObject(
        layer, &kEeveeOriginalLayerClassKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC
    );
    // 换类之后把当前底色再写一次：会走新 setter ⇒ 立刻清掉（顺手把颜色报给 sink，用于还原）。
    // ⚠️ 这一层**可能本来就是透明的**（`backgroundColor == NULL`）—— 别对 NULL 做 retain。
    CGColorRef existing = layer.backgroundColor ? CGColorRetain(layer.backgroundColor) : NULL;
    object_setClass(layer, subclass);
    if (existing) {
        layer.backgroundColor = existing;
        CGColorRelease(existing);
    }
    return YES;
}

void EeveeRestoreBackground(UIView *view) {
    if (!view) return;
    CALayer *layer = view.layer;
    Class current = object_getClass(layer);
    if (![NSStringFromClass(current) hasPrefix:@"EeveeBG_"]) return;

    // 先撤 sink：写回真实类之后，调用方再设 backgroundColor 才会真的落盘。
    objc_setAssociatedObject(layer, &kEeveeColorSinkKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    Class original = objc_getAssociatedObject(layer, &kEeveeOriginalLayerClassKey);
    if (original) {
        object_setClass(layer, original);
        objc_setAssociatedObject(
            layer, &kEeveeOriginalLayerClassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC
        );
    }
}

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}
