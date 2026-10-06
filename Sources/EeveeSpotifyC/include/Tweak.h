#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
NSString *EeveeJBRootPath(NSString *path);

// ★ 2026-10-13：从上游移植的换色桥（实现见 `ColorSwap.m`）。用途：AMOLED 纯黑 + 强调色。
//
// `EeveeInstallColorSwaps` 在**颜色出生点**装 swizzle（CALayer 底色 / CAGradientLayer 颜色 /
// CAShapeLayer 填充描边 / UIColor 的 red-green-blue 构造 / CA 动画关键帧），返回实际装上的
// 数量；`dispatch_once` 语义 ⇒ 进程内只装一次（改完要重启）。
// `EeveeColorSwapStats` 回报命中计数：底色变黑多少处、绿色换了几处（用来在日志里证明
// "装上了**并且**真的生效"，而不是只看安装成功）。
int EeveeInstallColorSwaps(BOOL amoled, NSInteger accentRGB);
void EeveeColorSwapStats(long *grey, long *green, long *uiColor);

NS_ASSUME_NONNULL_END
