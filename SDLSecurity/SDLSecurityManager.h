//
//  SDLSecurityManager.h
//  SDLSecurity
//
//  Created by Joel Fischer on 1/21/16.
//  Copyright © 2016 livio. All rights reserved.
//

#import <Foundation/Foundation.h>

#import "SDLSecurityType.h"

NS_ASSUME_NONNULL_BEGIN

@interface SDLSecurityManager : NSObject <SDLSecurityType>

@property (nonatomic, copy) NSString *appId;

- (void)initializeWithAppId:(NSString *)appId completionHandler:(void (^)(NSError * _Nullable))completionHandler;
- (void)stop;

- (nullable NSData *)runHandshakeWithClientData:(NSData *)data error:(NSError **)error;

- (nullable NSData *)encryptData:(NSData *)data withError:(NSError **)error;
- (nullable NSData *)decryptData:(NSData *)data withError:(NSError **)error;

+ (NSSet<NSString *> *)availableMakes;

@end

NS_ASSUME_NONNULL_END
