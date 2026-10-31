#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
NSString *EeveeJBRootPath(NSString *path);

// 从上游 `EncoreBridge.m` 移植的**底色拦截**（A：迷你播放条按上游的写）。
//
// 给 `view.layer` 造一个**只有这个实例用**的 CALayer 子类：`setBackgroundColor:` 被改写成
// "只把颜色交给 sink，然后 super 传 NULL" ⇒ Spotify 之后再怎么重写都**画不出来**，
// 不需要"清 → 补清 → 0.5s 复查"那套轮询（那套的空窗期就是的闪烁）。
// 同时把 `-class` 覆写成原类，`isKindOfClass:` 之类照常。
//
// 返回 YES = 装上了（从现在起这一层的底色写不进去）；NO = 装不上（层类是 Swift 类 / KVO 子类 /
// 分配失败）—— 调用方应当退回"每次布局清一次"的老路。
// `EeveeRestoreBackground` 把类写回去（关开关时用），之后设置 `backgroundColor` 才真的落盘。
BOOL EeveeInterceptBackground(UIView *view, void (^sink)(UIColor *color));
void EeveeRestoreBackground(UIView *view);

// 从上游移植的换色桥（实现见 `ColorSwap.m`）。用途：AMOLED 纯黑 + 强调色。
//
// `EeveeInstallColorSwaps` 在**颜色出生点**装 swizzle（CALayer 底色 / CAGradientLayer 颜色 /
// CAShapeLayer 填充描边 / UIColor 的 red-green-blue 构造 / CA 动画关键帧），返回实际装上的
// 数量；`dispatch_once` 语义 ⇒ 进程内只装一次（改完要重启）。
// `EeveeColorSwapStats` 回报命中计数：底色变黑多少处、绿色换了几处。
int EeveeInstallColorSwaps(BOOL amoled, NSInteger accentRGB);
void EeveeColorSwapStats(long *grey, long *green, long *uiColor);

NS_ASSUME_NONNULL_END
