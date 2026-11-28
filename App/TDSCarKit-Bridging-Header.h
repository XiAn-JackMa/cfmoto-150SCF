#include "TDSCarKitCrypto.h"
#import "DirectAccessoryTransport.h"

#include "ikcp.h"

// 私有 API（自用，非 App Store）：程序化设置系统媒体音量。
// AVSystemController 位于 Celestial 私有框架，被 UIKit 间接加载，链接期符号可用。
@interface AVSystemController : NSObject
+ (instancetype)sharedAVSystemController;
- (BOOL)setVolumeTo:(float)volume forCategory:(NSString *)category;
@end

