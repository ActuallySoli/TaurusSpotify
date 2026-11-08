#import "FontCatalog.h"
#import <CommonCrypto/CommonDigest.h>

static NSString * const revision = @"2fe1e8c6b137fb13041a7cfca6fdcd8a910ea4dc";

static NSError *catalogError(NSString *message) {
    return [NSError errorWithDomain:@"spoti.pw.fonts" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface SGFontCatalogEntry ()
- (instancetype)initWithFamily:(NSString *)family detail:(NSString *)detail path:(NSString *)path bytes:(NSUInteger)bytes sha256:(NSString *)sha256 license:(NSString *)license;
@end

@implementation SGFontCatalogEntry
- (instancetype)initWithFamily:(NSString *)family detail:(NSString *)detail path:(NSString *)path bytes:(NSUInteger)bytes sha256:(NSString *)sha256 license:(NSString *)license {
    if (!(self = [super init])) return nil;
    _family = [family copy];
    _detail = [detail copy];
    _fileName = [path.lastPathComponent stringByRemovingPercentEncoding];
    _byteCount = bytes;
    _sha256 = [sha256 copy];
    _licenseText = [license copy];
    NSString *folder = [path stringByDeletingLastPathComponent];
    _downloadURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://raw.githubusercontent.com/google/fonts/%@/%@", revision, path]];
    _sourceURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://github.com/google/fonts/tree/%@/%@", revision, folder]];
    _licenseURL = [NSURL URLWithString:[NSString stringWithFormat:@"https://raw.githubusercontent.com/google/fonts/%@/%@/OFL.txt", revision, folder]];
    return self;
}

- (NSDictionary<NSString *, id> *)metadata {
    return @{@"family": self.family, @"revision": revision, @"sha256": self.sha256, @"bytes": @(self.byteCount), @"variable": @([self.detail hasPrefix:@"Variable"]),
             @"sourceURL": self.sourceURL.absoluteString, @"downloadURL": self.downloadURL.absoluteString,
             @"licenseURL": self.licenseURL.absoluteString, @"license": @"SIL Open Font License 1.1", @"licenseText": self.licenseText};
}
@end

static NSString * const oflTerms =
    @"-----------------------------------------------------------\n"
    @"SIL OPEN FONT LICENSE Version 1.1 - 26 February 2007\n"
    @"-----------------------------------------------------------\n"
    @"\n"
    @"PREAMBLE\n"
    @"The goals of the Open Font License (OFL) are to stimulate worldwide\n"
    @"development of collaborative font projects, to support the font creation\n"
    @"efforts of academic and linguistic communities, and to provide a free and\n"
    @"open framework in which fonts may be shared and improved in partnership\n"
    @"with others.\n"
    @"\n"
    @"The OFL allows the licensed fonts to be used, studied, modified and\n"
    @"redistributed freely as long as they are not sold by themselves. The\n"
    @"fonts, including any derivative works, can be bundled, embedded, \n"
    @"redistributed and/or sold with any software provided that any reserved\n"
    @"names are not used by derivative works. The fonts and derivatives,\n"
    @"however, cannot be released under any other type of license. The\n"
    @"requirement for fonts to remain under this license does not apply\n"
    @"to any document created using the fonts or their derivatives.\n"
    @"\n"
    @"DEFINITIONS\n"
    @"\"Font Software\" refers to the set of files released by the Copyright\n"
    @"Holder(s) under this license and clearly marked as such. This may\n"
    @"include source files, build scripts and documentation.\n"
    @"\n"
    @"\"Reserved Font Name\" refers to any names specified as such after the\n"
    @"copyright statement(s).\n"
    @"\n"
    @"\"Original Version\" refers to the collection of Font Software components as\n"
    @"distributed by the Copyright Holder(s).\n"
    @"\n"
    @"\"Modified Version\" refers to any derivative made by adding to, deleting,\n"
    @"or substituting -- in part or in whole -- any of the components of the\n"
    @"Original Version, by changing formats or by porting the Font Software to a\n"
    @"new environment.\n"
    @"\n"
    @"\"Author\" refers to any designer, engineer, programmer, technical\n"
    @"writer or other person who contributed to the Font Software.\n"
    @"\n"
    @"PERMISSION & CONDITIONS\n"
    @"Permission is hereby granted, free of charge, to any person obtaining\n"
    @"a copy of the Font Software, to use, study, copy, merge, embed, modify,\n"
    @"redistribute, and sell modified and unmodified copies of the Font\n"
    @"Software, subject to the following conditions:\n"
    @"\n"
    @"1) Neither the Font Software nor any of its individual components,\n"
    @"in Original or Modified Versions, may be sold by itself.\n"
    @"\n"
    @"2) Original or Modified Versions of the Font Software may be bundled,\n"
    @"redistributed and/or sold with any software, provided that each copy\n"
    @"contains the above copyright notice and this license. These can be\n"
    @"included either as stand-alone text files, human-readable headers or\n"
    @"in the appropriate machine-readable metadata fields within text or\n"
    @"binary files as long as those fields can be easily viewed by the user.\n"
    @"\n"
    @"3) No Modified Version of the Font Software may use the Reserved Font\n"
    @"Name(s) unless explicit written permission is granted by the corresponding\n"
    @"Copyright Holder. This restriction only applies to the primary font name as\n"
    @"presented to the users.\n"
    @"\n"
    @"4) The name(s) of the Copyright Holder(s) or the Author(s) of the Font\n"
    @"Software shall not be used to promote, endorse or advertise any\n"
    @"Modified Version, except to acknowledge the contribution(s) of the\n"
    @"Copyright Holder(s) and the Author(s) or with their explicit written\n"
    @"permission.\n"
    @"\n"
    @"5) The Font Software, modified or unmodified, in part or in whole,\n"
    @"must be distributed entirely under this license, and must not be\n"
    @"distributed under any other license. The requirement for fonts to\n"
    @"remain under this license does not apply to any document created\n"
    @"using the Font Software.\n"
    @"\n"
    @"TERMINATION\n"
    @"This license becomes null and void if any of the above conditions are\n"
    @"not met.\n"
    @"\n"
    @"DISCLAIMER\n"
    @"THE FONT SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND,\n"
    @"EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO ANY WARRANTIES OF\n"
    @"MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT\n"
    @"OF COPYRIGHT, PATENT, TRADEMARK, OR OTHER RIGHT. IN NO EVENT SHALL THE\n"
    @"COPYRIGHT HOLDER BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,\n"
    @"INCLUDING ANY GENERAL, SPECIAL, INDIRECT, INCIDENTAL, OR CONSEQUENTIAL\n"
    @"DAMAGES, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING\n"
    @"FROM, OUT OF THE USE OR INABILITY TO USE THE FONT SOFTWARE OR FROM\n"
    @"OTHER DEALINGS IN THE FONT SOFTWARE.\n";

NSArray<SGFontCatalogEntry *> *SGFontCatalogEntries(void) {
    static NSArray<SGFontCatalogEntry *> *entries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        entries = @[
            [[SGFontCatalogEntry alloc] initWithFamily:@"Inter" detail:@"Variable · Latin" path:@"ofl/inter/Inter%5Bopsz,wght%5D.ttf" bytes:876576 sha256:@"29160a80ff49ddcab2c97711247e08b1fab27a484a329ce8b813d820dc559031" license:[@"Copyright 2020 The Inter Project Authors (https://github.com/rsms/inter)\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\nThis license is copied below, and is also available with a FAQ at:\nhttps://scripts.sil.org/OFL\n\n\n" stringByAppendingString:oflTerms]],
            [[SGFontCatalogEntry alloc] initWithFamily:@"Manrope" detail:@"Variable · Latin" path:@"ofl/manrope/Manrope%5Bwght%5D.ttf" bytes:164700 sha256:@"3ae11c49db0455a3cc33e37d380f20fdb8c7f8b41dc07625c177e3d87a9d6ae6" license:[@"Copyright 2018 The Manrope Project Authors (https://github.com/googlefonts/manrope)\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\nThis license is copied below, and is also available with a FAQ at:\nhttp://scripts.sil.org/OFL\n\n\n" stringByAppendingString:oflTerms]],
            [[SGFontCatalogEntry alloc] initWithFamily:@"Space Mono" detail:@"Regular · Latin" path:@"ofl/spacemono/SpaceMono-Regular.ttf" bytes:99356 sha256:@"95837e182baeeada83368f7748db28357f0a1b75c6b84ff7065b5edf933c8e18" license:[@"Copyright 2016 The Space Mono Project Authors (https://github.com/googlefonts/spacemono)\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\nThis license is copied below, and is also available with a FAQ at:\nhttp://scripts.sil.org/OFL\n\n\n" stringByAppendingString:oflTerms]],
            [[SGFontCatalogEntry alloc] initWithFamily:@"Noto Sans Arabic" detail:@"Variable · Arabic" path:@"ofl/notosansarabic/NotoSansArabic%5Bwdth,wght%5D.ttf" bytes:844676 sha256:@"63111b5b2e074dd48cc67692e0a2726d86ee94c1c37fe8598257b7b4e87e869e" license:[@"Copyright 2022 The Noto Project Authors (https://github.com/notofonts/arabic)\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\nThis license is copied below, and is also available with a FAQ at:\nhttps://scripts.sil.org/OFL\n\n\n" stringByAppendingString:oflTerms]],
            [[SGFontCatalogEntry alloc] initWithFamily:@"Noto Sans Hebrew" detail:@"Variable · Hebrew" path:@"ofl/notosanshebrew/NotoSansHebrew%5Bwdth,wght%5D.ttf" bytes:112640 sha256:@"7ef36a2c3593758cdb622e1bdef4f84523e92fbc3ccc667438dd80ff54c2de88" license:[@"Copyright 2022 The Noto Project Authors (https://github.com/notofonts/hebrew)\n\nThis Font Software is licensed under the SIL Open Font License, Version 1.1.\nThis license is copied below, and is also available with a FAQ at:\nhttps://scripts.sil.org/OFL\n\n\n" stringByAppendingString:oflTerms]],
        ];
    });
    return entries;
}

NSUInteger SGFontCatalogByteLimit(void) { return 8 * 1024 * 1024; }

BOOL SGFontCatalogValidateData(NSData *data, NSUInteger expectedSize, NSString *sha256, NSInteger status, NSError **error) {
    NSString *failure = nil;
    if (status != 200) failure = @"The font server did not return a font. Try again later.";
    else if (!expectedSize || expectedSize > SGFontCatalogByteLimit() || data.length != expectedSize)
        failure = @"The download has an unexpected size. Your current font was kept.";
    else {
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
        NSMutableString *hex = [NSMutableString stringWithCapacity:64];
        for (NSUInteger i = 0; i < sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
        if (![hex isEqualToString:sha256]) failure = @"The download did not match the verified font. Your current font was kept.";
    }
    if (failure && error) *error = catalogError(failure);
    return !failure;
}

@interface SGFontDownload : NSObject <NSURLSessionDataDelegate>
@property (nonatomic) SGFontCatalogEntry *entry;
@property (nonatomic) NSURLSession *session;
@property (nonatomic) NSMutableData *data;
@property (nonatomic) NSError *failure;
@property (nonatomic) NSInteger status;
@property (nonatomic, copy) void (^completion)(NSURL *, NSError *);
@end

@implementation SGFontDownload
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    self.failure = catalogError(@"The font server redirected the request. Your current font was kept.");
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    int64_t length = response.expectedContentLength;
    if (self.status != 200 || (length >= 0 && (uint64_t)length != self.entry.byteCount)) {
        self.failure = catalogError(@"The font server returned an unexpected response. Your current font was kept.");
        completionHandler(NSURLSessionResponseCancel);
        return;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    if (data.length > MIN(self.entry.byteCount, SGFontCatalogByteLimit()) - self.data.length) {
        self.failure = catalogError(@"The download exceeded its expected size. Your current font was kept.");
        [task cancel];
        return;
    }
    [self.data appendData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSError *failure = self.failure ?: error;
    NSURL *file = nil, *folder = nil;
    if (!failure && SGFontCatalogValidateData(self.data, self.entry.byteCount, self.entry.sha256, self.status, &failure)) {
        NSFileManager *manager = NSFileManager.defaultManager;
        folder = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        file = [folder URLByAppendingPathComponent:self.entry.fileName];
        if (![manager createDirectoryAtURL:folder withIntermediateDirectories:YES attributes:nil error:&failure]
            || ![self.data writeToURL:file options:NSDataWritingAtomic error:&failure]
            || ![self.entry.licenseText writeToURL:[folder URLByAppendingPathComponent:@"OFL.txt"] atomically:YES encoding:NSUTF8StringEncoding error:&failure]) file = nil;
    }
    if (failure && folder) [NSFileManager.defaultManager removeItemAtURL:folder error:nil];
    void (^done)(NSURL *, NSError *) = self.completion;
    self.completion = nil;
    [session finishTasksAndInvalidate];
    self.session = nil;
    dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(file, failure); });
}
@end

void SGDownloadCatalogFont(SGFontCatalogEntry *entry, void (^completion)(NSURL *, NSError *)) {
    if (![SGFontCatalogEntries() containsObject:entry]) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, catalogError(@"Choose a font from the catalog.")); });
        return;
    }
    SGFontDownload *download = [SGFontDownload new];
    download.entry = entry;
    download.data = [NSMutableData data];
    download.completion = completion;
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 30;
    configuration.timeoutIntervalForResource = 60;
    configuration.URLCache = nil;
    configuration.HTTPCookieStorage = nil;
    configuration.HTTPShouldSetCookies = NO;
    configuration.URLCredentialStorage = nil;
    configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    download.session = [NSURLSession sessionWithConfiguration:configuration delegate:download delegateQueue:queue];
    [[download.session dataTaskWithURL:entry.downloadURL] resume];
}
