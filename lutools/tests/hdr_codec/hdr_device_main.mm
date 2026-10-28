#import <UIKit/UIKit.h>
#include <cstdio>

int rawlabHDRCodecMain(int argc, const char* argv[]);

@interface HDRCodecSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@property(nonatomic, strong) UILabel* status;
@end

@implementation HDRCodecSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
    UIViewController* controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [[UILabel alloc] initWithFrame:CGRectInset(self.window.bounds, 24, 100)];
    self.status.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.status.numberOfLines = 0;
    self.status.text = @"RawLab HDR codec verification is running.\nPrivate fixtures; Photos is not accessed.";
    self.status.textColor = UIColor.labelColor;
    [controller.view addSubview:self.status];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSURL* documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory
                inDomains:NSUserDomainMask].firstObject;
            NSURL* log = [documents URLByAppendingPathComponent:@"codec.log"];
            NSURL* reportURL = [documents URLByAppendingPathComponent:@"results.json"];
            NSString* runID = NSUUID.UUID.UUIDString;
            NSString* sourceRevision = NSBundle.mainBundle.infoDictionary[@"HDRSourceRevision"] ?: @"unknown";
            NSData* initial = [NSJSONSerialization dataWithJSONObject:@{@"status":@"running",@"run_id":runID,
                @"source_revision":sourceRevision} options:0 error:nil];
            [initial writeToURL:reportURL atomically:YES];
            [[NSData data] writeToURL:log atomically:YES];
            std::fflush(stdout); std::fflush(stderr);
            std::freopen(log.fileSystemRepresentation, "a", stdout);
            std::freopen(log.fileSystemRepresentation, "a", stderr);
            NSMutableArray* results = [NSMutableArray array];
            auto execute = [&](NSString* name, NSURL* input) {
                @autoreleasepool {
                    const char* args[] = {"hdr_codec_probe", name.UTF8String, input.fileSystemRepresentation};
                    const double started = NSDate.timeIntervalSinceReferenceDate;
                    const int code = rawlabHDRCodecMain(input ? 3 : 2, args);
                    [results addObject:@{@"case": input ? input.lastPathComponent : name, @"operation":name,
                        @"exit_code": @(code), @"seconds": @(NSDate.timeIntervalSinceReferenceDate - started)}];
                    std::fflush(stdout); std::fflush(stderr);
                }
            };
            for (NSString* name in @[@"iso", @"rgb_map", @"heic", @"orientation", @"bad_aux",
                    @"ultrahdr", @"dual_metadata"]) execute(name, nil);
#if RAWLAB_HDR_PRODUCTION
            for (NSString* name in @[@"production_iso",@"production_rgb_map",@"production_heic",@"production_orientation",
                    @"production_ultrahdr"]) execute(name,nil);
#endif
            NSArray<NSURL*>* fixtures = [NSBundle.mainBundle URLsForResourcesWithExtension:nil subdirectory:@"HDRFixtures"];
            for (NSURL* input in [fixtures sortedArrayUsingComparator:^NSComparisonResult(NSURL* a, NSURL* b) {
                    return [a.lastPathComponent compare:b.lastPathComponent];
                }]) {
                execute(@"external",input);
#if RAWLAB_HDR_PRODUCTION
                execute(@"production_external",input);
                if ([input.lastPathComponent isEqualToString:NSBundle.mainBundle.infoDictionary[@"HDRFinalFixtureName"]])
                    execute(@"production_external_final",input);
#endif
            }
            NSUInteger failed = 0;
            for (NSDictionary* result in results) if ([result[@"exit_code"] intValue] != 0) ++failed;
            NSDictionary* report = @{@"status":@"complete",@"run_id":runID,@"source_revision":sourceRevision,
                @"sdk":NSBundle.mainBundle.infoDictionary[@"DTSDKName"] ?: @"unknown",
                @"os": UIDevice.currentDevice.systemVersion,
                @"model": UIDevice.currentDevice.model, @"tests": results, @"failed": @(failed),
                @"full_resolution_acceptance": @NO, @"physical_hdr_display_acceptance": @NO};
            NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
            [json writeToURL:reportURL atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.status.text = [NSString stringWithFormat:@"HDR codec: %lu tests, %lu failures.\n\nResults saved in this test app's Documents.\nThis does not certify HDR display or full-size editing.",
                    (unsigned long)results.count, (unsigned long)failed];
            });
        }
    });
}
@end

@interface HDRCodecAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation HDRCodecAppDelegate
- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
    UISceneConfiguration* configuration = [[UISceneConfiguration alloc] initWithName:@"HDR Codec" sessionRole:session.role];
    configuration.delegateClass = HDRCodecSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char* argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(HDRCodecAppDelegate.class)); }
}
