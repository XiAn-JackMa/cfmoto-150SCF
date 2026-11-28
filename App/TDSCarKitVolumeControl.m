// SPDX-License-Identifier: AGPL-3.0-only
//
// 私有 API：通过 AVSystemController 设置系统媒体音量（0~1）。
//
// 连上车机后 MPVolumeView 不再包含音量 slider（被路径名替换），公开 API 无法拨回音量。
// AVSystemController 位于 Celestial 私有框架，被 UIKit 间接加载。这里用
// NSClassFromString + NSInvocation 动态调用，避免在链接期直接引用私有框架的类符号。
// 仅自用（非 App Store）。

#import <Foundation/Foundation.h>
#import <string.h>

bool tds_set_system_volume(float volume) {
    Class controllerClass = NSClassFromString(@"AVSystemController");
    if (!controllerClass) {
        return false;
    }
    id controller = [controllerClass performSelector:@selector(sharedAVSystemController)];
    if (!controller) {
        return false;
    }

    SEL selector = @selector(setVolumeTo:forCategory:);
    NSMethodSignature *signature = [controller methodSignatureForSelector:selector];
    if (!signature) {
        return false;
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = controller;
    invocation.selector = selector;
    NSString *category = @"Audio/Video";
    // 参数索引：0=self, 1=_cmd, 2=volume, 3=category。
    [invocation setArgument:&volume atIndex:2];
    [invocation setArgument:&category atIndex:3];
    [invocation invoke];

    BOOL result = NO;
    if (strcmp(signature.methodReturnType, @encode(BOOL)) == 0) {
        [invocation getReturnValue:&result];
    }
    return result;
}
