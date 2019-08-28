//
//  SDLSecurityPrivate.m
//  SDLSecurity
//
//  Created by Joel Fischer on 1/28/16.
//  Copyright © 2016 livio. All rights reserved.
//

#import "_SDLTLSEngine.h"

#import <openssl/bio.h>
#import <openssl/ssl.h>
#import <openssl/err.h>
#import <openssl/conf.h>
#import <openssl/pkcs12.h>

#import "_SDLCertificateManager.h"
#import "SDLPrivateSecurityConstants.h"
#import "SDLSecurityConstants.h"


NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, SDLTLSEngineState) {
    SDLTLSEngineStateDisconnected,
    SDLTLSEngineStateInitialized,
};

static const int SDLTLSReadBufferSize = 4096;

@interface _SDLTLSEngine () {
    SSL *sslConnection;
    SSL_CTX *sslContext;
    BIO *readBIO;
    BIO *writeBIO;
}

@property (assign, nonatomic) SDLTLSEngineState state;
@property (strong, nonatomic) _SDLCertificateManager *certificateManager;
@property (copy, nonatomic) NSString *appId;

@end


@implementation _SDLTLSEngine

#pragma mark - Lifecycle

- (instancetype)init {
    return nil;
}

- (instancetype)initWithAppId:(NSString *)appId {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    
    _state = SDLTLSEngineStateDisconnected;
    _appId = appId;
    _certificateManager = [[_SDLCertificateManager alloc] initWithCertificateServerURL:[NSURL URLWithString:CertQAURL]];

    SSL_load_error_strings();
    ERR_load_BIO_strings();
    OpenSSL_add_all_algorithms();
    SSL_library_init();

    return self;
}


#pragma mark - Startup / Teardown

// http://stackoverflow.com/questions/6371775/how-to-load-a-pkcs12-file-in-openssl-programmatically
- (void)initializeTLSWithCompletionHandler:(void (^)(BOOL success, NSError * _Nullable))completionHandler {
    NSData *certData = self.certificateManager.certificateData;
    
    if (certData.length == 0) {
        [self.certificateManager retrieveNewCertificateWithAppId:self.appId completionHandler:^(BOOL success, NSError * _Nullable networkError) {
            if (!success) {
                return completionHandler(NO, networkError);
            }
            
            // Certificate has been downloaded. Recurse back into this method to try again with the new certificate data.
            return [self initializeTLSWithCompletionHandler:completionHandler];
        }];
    } else {
        NSError *tlsError = nil;
        BOOL success = [self initializeTLSWithCertificateData:certData error:&tlsError];

        if (!success) {
            if (tlsError.code == SDLTLSErrorCodeCertificateExpired) {
                [self.certificateManager retrieveNewCertificateWithAppId:self.appId completionHandler:^(BOOL success, NSError * _Nullable networkError) {
                    if (!success) {
                        return completionHandler(NO, networkError);
                    }

                    // Certificate has been downloaded. Recurse back into this method to try again with the new certificate data.
                    return [self initializeTLSWithCompletionHandler:completionHandler];
                }];
            } else {
                return completionHandler(NO, tlsError);
            }
        } else {
            return completionHandler(YES, nil);
        }
    }
}

- (BOOL)initializeTLSWithCertificateData:(NSData *)data error:(NSError * _Nullable __autoreleasing *)error {
    PKCS12 *p12 = NULL;
    EVP_PKEY *pkey = NULL;
    X509 *certX509 = NULL;
    RSA *rsa = NULL;
    BIO *pbio = NULL;
    BOOL success = NO;
    
    void *p12Buffer = (void *)data.bytes;

    SSL_load_error_strings();
    ERR_load_BIO_strings();
    OpenSSL_add_all_algorithms();
    SSL_library_init();

    sslContext = SSL_CTX_new(DTLSv1_server_method());
    SSL_CTX_set_verify(sslContext, SSL_VERIFY_NONE, NULL);
    
    long options = SSL_OP_NO_SSLv2 | SSL_OP_NO_COMPRESSION | SSL_OP_SINGLE_DH_USE | SSL_OP_SINGLE_ECDH_USE;
    SSL_CTX_set_options(sslContext, options);
    pbio = BIO_new_mem_buf(p12Buffer, (int)data.length);
    p12 = d2i_PKCS12_bio(pbio, NULL);
    if (p12 == NULL) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }

    // TODO: Swap out the hardcoded password for however we're getting it
    success = PKCS12_parse(p12, SDLTLSCertPassword, &pkey, &certX509, NULL);
    if (certX509 == NULL || pkey == NULL) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    // https://zakird.com/2013/10/13/certificate-parsing-with-openssl/
    // Check that the certificate has not already expired
    NSDate *certExpiryDate = sdlsec_certificateGetExpiryDate(certX509);
    if ([[NSDate date] compare:certExpiryDate] != NSOrderedAscending) {
        sdlsec_cleanUpInitialization(certX509, NULL, p12, pbio, pkey);
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:SDLTLSErrorCodeCertificateExpired userInfo:nil];
        return NO;
    }
    
    // Check that the certificate's issuer is correct
    NSString *certIssuer = [NSString stringWithUTF8String:X509_NAME_oneline(X509_get_issuer_name(certX509), NULL, 0)];
    if (![certIssuer isEqualToString:SDLTLSIssuer]) {
        sdlsec_cleanUpInitialization(certX509, NULL, p12, pbio, pkey);
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:SDLTLSErrorCodeCertificateInvalid userInfo:nil];
        return NO;
    }
    
    rsa = EVP_PKEY_get1_RSA(pkey);
    if (rsa == NULL) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    // Set up our SSL Context with the certificate and key
    success = SSL_CTX_use_certificate(sslContext, certX509);
    if (!success) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    success = SSL_CTX_use_RSAPrivateKey(sslContext, rsa);
    if (!success) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    success = SSL_CTX_check_private_key(sslContext);
    if (!success) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    success = SSL_CTX_set_cipher_list(sslContext, "ALL");
    if (!success) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    sslConnection = SSL_new(sslContext);
    if (sslConnection == NULL) {
        sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
        *error = [[self class] sdlsec_errorInitializationFailure];
        return NO;
    }
    
    readBIO = BIO_new(BIO_s_mem());
    writeBIO = BIO_new(BIO_s_mem());
    BIO_set_mem_eof_return(readBIO, -1);
    SSL_set_bio(sslConnection, readBIO, writeBIO);
    SSL_set_accept_state(sslConnection);
    sdlsec_cleanUpInitialization(certX509, rsa, p12, pbio, pkey);
    
    self.state = SDLTLSEngineStateInitialized;
    return YES;
}

- (void)shutdownTLS {
    if (self.state != SDLTLSEngineStateInitialized) {
        return;
    }
    
    if (sslConnection != NULL) {
        [self sdlsec_shutdown];
        SSL_free(sslConnection);
    }
    
    if (sslContext != NULL) {
        SSL_CTX_free(sslContext);
    }
    
    CONF_modules_unload(1);
    ERR_remove_state(0);
    ERR_free_strings();

    EVP_cleanup();

    sk_SSL_COMP_free(SSL_COMP_get_compression_methods());
    CRYPTO_cleanup_all_ex_data();
}

- (BOOL)sdlsec_TLSHandshake {
    if (sslConnection == NULL) {
        return NO;
    }
    
    if (!SSL_is_init_finished(sslConnection)) {
        SSL_do_handshake(sslConnection);
    }
    
    return SSL_is_init_finished(sslConnection);
}

- (void)sdlsec_shutdown {
    int retryCount = 0;
    for (int i = 0; i < 4; i++) {
        retryCount = SSL_shutdown(sslConnection);
        if (retryCount > 0) {
            break;
        }
    }
}

void sdlsec_cleanUpInitialization(X509 *_Nullable cert, RSA *_Nullable rsa, PKCS12 *_Nullable p12, BIO *_Nullable pbio, EVP_PKEY *_Nullable pkey) {
    if (cert != NULL) {
        X509_free(cert);
    }
    if (rsa != NULL) {
        RSA_free(rsa);
    }
    if (p12 != NULL) {
        PKCS12_free(p12);
    }
    if (pbio != NULL) {
        BIO_free(pbio);
    }
    if (pkey != NULL) {
        EVP_PKEY_free(pkey);
    }
}

#pragma mark - Certificate Validity

// http://stackoverflow.com/questions/8850524/seccertificateref-how-to-get-the-certificate-information
static NSDate *sdlsec_certificateGetExpiryDate(X509 *certificateX509)
{
    NSDate *expiryDate = nil;
    
    if (certificateX509 != NULL) {
        ASN1_TIME *certificateExpiryASN1 = X509_get_notAfter(certificateX509);
        if (certificateExpiryASN1 != NULL) {
            ASN1_GENERALIZEDTIME *certificateExpiryASN1Generalized = ASN1_TIME_to_generalizedtime(certificateExpiryASN1, NULL);
            if (certificateExpiryASN1Generalized != NULL) {
                unsigned char *certificateExpiryData = ASN1_STRING_data(certificateExpiryASN1Generalized);
                
                // ASN1 generalized times look like this: "20131114230046Z"
                //                                format:  YYYYMMDDHHMMSS
                //                               indices:  01234567890123
                //                                                   1111
                // There are other formats (e.g. specifying partial seconds or
                // time zones) but this is good enough for our purposes since
                // we only use the date and not the time.
                //
                // (Source: http://www.obj-sys.com/asn1tutorial/node14.html)
                
                NSString *expiryTimeStr = [NSString stringWithUTF8String:(char *)certificateExpiryData];
                NSDateComponents *expiryDateComponents = [[NSDateComponents alloc] init];
                
                expiryDateComponents.year = [[expiryTimeStr substringWithRange:NSMakeRange(0, 4)] intValue];
                expiryDateComponents.month = [[expiryTimeStr substringWithRange:NSMakeRange(4, 2)] intValue];
                expiryDateComponents.day = [[expiryTimeStr substringWithRange:NSMakeRange(6, 2)] intValue];
                expiryDateComponents.hour = [[expiryTimeStr substringWithRange:NSMakeRange(8, 2)] intValue];
                expiryDateComponents.minute = [[expiryTimeStr substringWithRange:NSMakeRange(10, 2)] intValue];
                expiryDateComponents.second = [[expiryTimeStr substringWithRange:NSMakeRange(12, 2)] intValue];
                
                NSCalendar *calendar = [NSCalendar currentCalendar];
                expiryDate = [calendar dateFromComponents:expiryDateComponents];
            }
        }
    }
    
    return expiryDate;
}


#pragma mark - Encrypt / Decrypt

- (nullable NSData *)encryptData:(NSData *)decryptedData withError:(NSError * _Nullable __autoreleasing *)error {
    if (![self sdlsec_TLSHandshake]) {
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:SDLTLSErrorCodeNotInitialized userInfo:nil];
        return nil;
    }
    
    [self sdlsec_SSLWriteDataToServer:decryptedData withError:error];
    if (*error != nil) {
        return nil;
    }
    
    NSData *encryptedData = [self sdlsec_BIOReadDataFromServerWithError:error];
    if (*error != nil) {
        return nil;
    }

    return encryptedData;
}

- (nullable NSData *)decryptData:(NSData *)encryptedData withError:(NSError * _Nullable __autoreleasing * _Nullable)error {
    if (![self sdlsec_TLSHandshake]) {
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:SDLTLSErrorCodeNotInitialized userInfo:nil];
        return nil;
    }
    
    [self sdlsec_BIOWriteDataToServer:encryptedData withError:error];
    if (*error != nil) {
        return nil;
    }
    
    NSData *data = [self sdlsec_SSLReadDataFromServerWithError:error];
    if (*error != nil) {
        return nil;
    }
    
    return data;
}


#pragma mark - Handshake

- (nullable NSData *)runHandshakeWithClientData:(NSData *)data error:(NSError * _Nullable __autoreleasing *)error {
    if ([self sdlsec_BIOWriteDataToServer:data withError:error] <= 0) {
        return nil;
    }
    
    [self sdlsec_TLSHandshake];
    
    NSData *dataToSend = [self sdlsec_BIOReadDataFromServerWithError:error];
    
    [self sdlsec_TLSHandshake];
    
    return dataToSend;
}


#pragma mark - Send / Receive

//- (int)BIODataPending {
//    return BIO_pending(readBIO);
//}
//
//- (int)SSLDataPending {
//    return SSL_pending(sslConnection);
//}

#pragma mark SSL

- (int)sdlsec_SSLWriteDataToServer:(NSData *)data withError:(NSError * __autoreleasing*)error {
    int length = (int)data.length;
    void *buffer = (void *)data.bytes;
    int retVal = SSL_write(sslConnection, buffer, length);

    SDLTLSErrorCode errorCode = [self.class sdlsec_errorCodeFromSSL:sslConnection value:retVal length:length isWrite:NO];
    if ((errorCode != SDLTLSErrorCodeNone) && (*error != nil)) {
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:errorCode userInfo:nil];
    }

    return retVal;
}

- (nullable NSData *)sdlsec_SSLReadDataFromServerWithError:(NSError * __autoreleasing*)error {
    NSData *returnData = nil;
    
    int length = SDLTLSReadBufferSize;
    void *buffer = malloc(SDLTLSReadBufferSize);
    int bufferLength = SSL_read(sslConnection, buffer, length);

    if (bufferLength > 0) {
        returnData = [NSData dataWithBytes:buffer length:bufferLength];
    }
    free(buffer);
    
    SDLTLSErrorCode errorCode = [self.class sdlsec_errorCodeFromSSL:sslConnection value:bufferLength length:length isWrite:NO];
    if ((errorCode != SDLTLSErrorCodeNone) && (*error != nil)) {
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:errorCode userInfo:nil];
    }
    
    return returnData;
}


#pragma mark BIO

- (int)sdlsec_BIOWriteDataToServer:(NSData *)data withError:(NSError * __autoreleasing*)error {
    int length = (int)data.length;
    void *buffer = (void *)data.bytes;
    int retVal = BIO_write(readBIO, buffer, length);

    SDLTLSErrorCode errorCode = [self.class sdlsec_errorCodeFromSSL:sslConnection value:retVal length:length isWrite:NO];
    if ((errorCode != SDLTLSErrorCodeNone) && (*error != nil)) {
        *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:errorCode userInfo:nil];
    }

    return retVal;
}

- (nullable NSData *)sdlsec_BIOReadDataFromServerWithError:(NSError * __autoreleasing*)error {
    NSMutableData *returnData = [NSMutableData data];
    int length = SDLTLSReadBufferSize;
    void *buffer = malloc(SDLTLSReadBufferSize);
    int bufferLength = 0;

    while ((bufferLength = BIO_read(writeBIO, buffer, length)) >= 0) {
        [returnData appendBytes:buffer length:bufferLength];

        SDLTLSErrorCode errorCode = [self.class sdlsec_errorCodeFromSSL:sslConnection value:bufferLength length:length isWrite:NO];
        if ((errorCode != SDLTLSErrorCodeNone) && (*error != nil)) {
            *error = [NSError errorWithDomain:SDLSecurityErrorDomain code:errorCode userInfo:nil];
        }
    }

    return returnData;
}


#pragma mark - Error

+ (SDLTLSErrorCode)sdlsec_errorCodeFromSSL:(SSL *)ssl value:(int)value length:(int)length isWrite:(BOOL)isWrite {
    int error = SSL_get_error(ssl, value);
    
    switch(error) {
        case SSL_ERROR_NONE:
            if((length != value) && isWrite) {
                return SDLTLSErrorCodeWriteFailed;
            } else {
                return SDLTLSErrorCodeNone;
            }
        case SSL_ERROR_SSL: {
            return SDLTLSErrorCodeSSL;
        }
        case SSL_ERROR_WANT_READ: {
            return SDLTLSErrorCodeWantRead;
        }
        case SSL_ERROR_WANT_WRITE: {
            return SDLTLSErrorCodeWantWrite;
        }
        default: {
            return SDLTLSErrorCodeGeneric;
        }
    }
}

+ (NSError *)sdlsec_errorInitializationFailure {
    return [NSError errorWithDomain:SDLSecurityErrorDomain code:SDLTLSErrorCodeInitializationFailure userInfo:nil];
}

@end

NS_ASSUME_NONNULL_END
