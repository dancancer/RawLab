#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// 仅测试目标链接的 XCTest 事件接口：整段手势一次下发，避免 IPC 间隔改变双击时间窗。
@interface XCPointerEventPath : NSObject
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(NSTimeInterval)offset NS_SWIFT_NAME(init(touchAt:offset:));
- (void)moveToPoint:(CGPoint)point atOffset:(NSTimeInterval)offset NS_SWIFT_NAME(move(to:at:));
- (void)liftUpAtOffset:(NSTimeInterval)offset NS_SWIFT_NAME(liftUp(at:));
@end

@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name NS_SWIFT_NAME(init(name:));
- (void)addPointerEventPath:(XCPointerEventPath *)path NS_SWIFT_NAME(add(_:));
- (BOOL)synthesizeWithError:(NSError * _Nullable * _Nullable)error;
@end

NS_ASSUME_NONNULL_END
