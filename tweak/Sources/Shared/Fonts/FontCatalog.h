#import <Foundation/Foundation.h>

@interface SGFontCatalogEntry : NSObject
@property (nonatomic, readonly, copy) NSString *family;
@property (nonatomic, readonly, copy) NSString *detail;
@property (nonatomic, readonly, copy) NSString *fileName;
@property (nonatomic, readonly, copy) NSString *sha256;
@property (nonatomic, readonly) NSUInteger byteCount;
@property (nonatomic, readonly) NSURL *downloadURL;
@property (nonatomic, readonly) NSURL *sourceURL;
@property (nonatomic, readonly) NSURL *licenseURL;
@property (nonatomic, readonly, copy) NSString *licenseText;
@property (nonatomic, readonly) NSDictionary<NSString *, id> *metadata;
@end

NSArray<SGFontCatalogEntry *> *SGFontCatalogEntries(void);
NSUInteger SGFontCatalogByteLimit(void);
BOOL SGFontCatalogValidateData(NSData *data, NSUInteger expectedSize, NSString *sha256, NSInteger status, NSError **error);
// Runs only on a user's request. Completion is on main; the caller removes the returned file's temporary directory.
void SGDownloadCatalogFont(SGFontCatalogEntry *entry, void (^completion)(NSURL *file, NSError *error));
