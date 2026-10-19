#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, turning an Objective-C exception into an NSError instead of a crash.
/// AVFoundation reports some audio device problems by raising, which Swift can't catch.
BOOL ClackyCatchException(NS_NOESCAPE void (^block)(void), NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
