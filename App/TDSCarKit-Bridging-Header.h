#include "TDSCarKitCrypto.h"
#import "DirectAccessoryTransport.h"

#include "ikcp.h"

// 私有 API（自用，非 App Store）：设置系统媒体音量。实现见 TDSCarKitVolumeControl.m，
// 用 NSClassFromString + NSInvocation 动态调用，避免链接 Celestial 私有框架符号。
bool tds_set_system_volume(float volume);


