#import "SGRShaderLibrary.h"
#include <math.h>

NSUInteger const SGRShaderSourceLimit = 64 * 1024;
NSUInteger const SGRShaderProfileLimit = 16;
NSNotificationName const SGRShaderLibraryChangedNotification = @"spotifyglass.redesign.shaderLibraryChanged";
static NSString *const kSession = @"spotifyglass.redesign.shader.session";
static NSString *const kQuarantine = @"spotifyglass.redesign.shader.quarantine";

static NSError *libraryError(NSString *message) {
    return [NSError errorWithDomain:@"spotifyglass.redesign.shader" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface SGRShaderLibraryStore ()
@property (atomic, copy) NSArray<NSDictionary *> *profileSnapshot;
@property (atomic, copy) NSArray<NSString *> *blockedSnapshot;
@end

@implementation SGRShaderLibraryStore {
    NSURL *_url;
    NSUserDefaults *_defaults;
    NSString *_loadError;
}

- (instancetype)initWithURL:(NSURL *)url defaults:(NSUserDefaults *)defaults {
    if (!(self = [super init])) return nil;
    _url = url;
    _defaults = defaults;
    self.profileSnapshot = @[];
    self.blockedSnapshot = [self readQuarantinedIDs];
    id pending = [defaults objectForKey:kSession];
    if ([pending isKindOfClass:NSDictionary.class] && [pending[@"id"] isKindOfClass:NSString.class]) {
        NSMutableArray *blocked = [self.blockedSnapshot mutableCopy];
        if (![blocked containsObject:pending[@"id"]]) [blocked addObject:pending[@"id"]];
        self.blockedSnapshot = blocked;
        [defaults setObject:blocked forKey:kQuarantine];
        [defaults removeObjectForKey:kSession];
    }
    NSNumber *size;
    [url getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
    if (size.unsignedLongLongValue > 2 * 1024 * 1024) {
        _loadError = @"The saved library exceeds 2 MiB. It has been left untouched.";
        return self;
    }
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:nil];
    if (!data) return self;
    id document = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    id rows = [document isKindOfClass:NSDictionary.class] ? document[@"profiles"] : nil;
    if (![document isKindOfClass:NSDictionary.class] || ![document[@"version"] isEqual:@1] || ![rows isKindOfClass:NSArray.class] || [rows count] > SGRShaderProfileLimit) {
        _loadError = @"The saved library could not be read. It has been left untouched.";
        return self;
    }
    NSMutableArray *valid = [NSMutableArray array];
    NSMutableSet *ids = [NSMutableSet set];
    for (id row in rows) {
        NSDictionary *profile = [self validatedProfile:row error:nil];
        if (!profile || [ids containsObject:profile[@"id"]]) {
            _loadError = @"The saved library contains an invalid profile. It has been left untouched.";
            return self;
        }
        [ids addObject:profile[@"id"]];
        [valid addObject:profile];
    }
    self.profileSnapshot = [valid copy];
    return self;
}

- (NSArray<NSDictionary *> *)profiles { return self.profileSnapshot; }
- (NSString *)loadError { @synchronized(self) { return _loadError; } }

- (NSDictionary *)validatedProfile:(id)value error:(NSError **)error {
    NSString *message;
    if (![value isKindOfClass:NSDictionary.class]) message = @"A shader profile must be a JSON object.";
    else {
        id name = value[@"name"], source = value[@"source"], fps = value[@"fps"], scale = value[@"scale"], identifier = value[@"id"];
        NSData *bytes = [source isKindOfClass:NSString.class] ? [source dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO] : nil;
        if (![value[@"version"] isEqual:@1]) message = @"This shader profile version is not supported.";
        else if (![name isKindOfClass:NSString.class] || ![name length] || [name length] > 60 ||
                 [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
                 ![name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)
            message = @"Use a shader name of 1–60 characters without control characters.";
        else if (!bytes.length || bytes.length > SGRShaderSourceLimit ||
                 [source rangeOfString:[NSString stringWithFormat:@"%C", (unichar)0]].location != NSNotFound)
            message = @"Metal source must be valid UTF-8, contain no NUL characters, and fit within 64 KiB.";
        else if (![fps isKindOfClass:NSNumber.class] || !isfinite([fps doubleValue]) || [fps doubleValue] < 1 || [fps doubleValue] > 60 || floor([fps doubleValue]) != [fps doubleValue])
            message = @"The frame limit must be a whole number from 1 to 60.";
        else if (![scale isKindOfClass:NSNumber.class] || !isfinite([scale doubleValue]) || [scale doubleValue] < 0.1 || [scale doubleValue] > 0.5)
            message = @"Render scale must be between 0.1 and 0.5 of the screen's native scale.";
        else if (identifier && (![identifier isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:identifier]))
            message = @"The shader identifier must be a UUID.";
        else return @{@"version": @1, @"id": identifier ? [[NSUUID alloc] initWithUUIDString:identifier].UUIDString : NSUUID.UUID.UUIDString,
                      @"name": [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],
                      @"source": [source copy], @"fps": @([fps integerValue]), @"scale": @([scale doubleValue])};
    }
    if (error) *error = libraryError(message);
    return nil;
}

- (BOOL)writeProfiles:(NSArray *)profiles error:(NSError **)error {
    if (_loadError) { if (error) *error = libraryError(_loadError); return NO; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @1, @"profiles": profiles} options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;
    if (data.length > 2 * 1024 * 1024) { if (error) *error = libraryError(@"The encoded library exceeds 2 MiB. Reduce the source size before saving."); return NO; }
    if (![NSFileManager.defaultManager createDirectoryAtURL:_url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    if (![data writeToURL:_url options:NSDataWritingAtomic error:error]) return NO;
    self.profileSnapshot = [profiles copy];
    return YES;
}

- (BOOL)saveProfile:(NSDictionary *)profile error:(NSError **)error {
    @synchronized(self) {
        NSDictionary *valid = [self validatedProfile:profile error:error];
        if (!valid) return NO;
        NSMutableArray *rows = [self.profileSnapshot mutableCopy];
        NSUInteger index = [rows indexOfObjectPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) { return [row[@"id"] isEqual:valid[@"id"]]; }];
        if (index == NSNotFound) {
            if (rows.count >= SGRShaderProfileLimit) { if (error) *error = libraryError(@"The library holds up to 16 shaders. Delete one before adding another."); return NO; }
            [rows addObject:valid];
        } else rows[index] = valid;
        return [self writeProfiles:rows error:error];
    }
}

- (BOOL)deleteProfile:(NSString *)identifier error:(NSError **)error {
    @synchronized(self) {
        NSMutableArray *rows = [self.profileSnapshot mutableCopy];
        NSIndexSet *indices = [rows indexesOfObjectsPassingTest:^BOOL(NSDictionary *row, NSUInteger i, BOOL *stop) { return [row[@"id"] isEqual:identifier]; }];
        [rows removeObjectsAtIndexes:indices];
        BOOL saved = [self writeProfiles:rows error:error];
        if (saved) [self retryProfile:identifier];
        return saved;
    }
}

- (NSArray *)readQuarantinedIDs {
    id value = [_defaults objectForKey:kQuarantine];
    if (![value isKindOfClass:NSArray.class]) return @[];
    return [value filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id value, NSDictionary *bindings) { return [value isKindOfClass:NSString.class]; }]];
}
- (BOOL)isQuarantined:(NSString *)identifier { return [self.blockedSnapshot containsObject:identifier]; }
- (void)retryProfile:(NSString *)identifier {
    @synchronized(self) {
        NSMutableArray *rows = [self.blockedSnapshot mutableCopy];
        [rows removeObject:identifier];
        self.blockedSnapshot = rows;
        [_defaults setObject:rows forKey:kQuarantine];
    }
}
- (NSString *)beginSession:(NSString *)identifier {
    @synchronized(self) {
        NSString *token = NSUUID.UUID.UUIDString;
        [_defaults setObject:@{@"id": identifier, @"token": token} forKey:kSession];
        if ([_defaults synchronize]) return token;
        [_defaults removeObjectForKey:kSession];
        return nil;
    }
}
- (void)endSession:(NSString *)token {
    @synchronized(self) {
        id session = [_defaults objectForKey:kSession];
        if ([session isKindOfClass:NSDictionary.class] && [session[@"token"] isEqual:token]) {
            [_defaults removeObjectForKey:kSession];
            [_defaults synchronize];
        }
    }
}
@end

SGRShaderLibraryStore *SGRShaderLibrary(void) {
    static SGRShaderLibraryStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *root = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
        store = [[SGRShaderLibraryStore alloc] initWithURL:[root URLByAppendingPathComponent:@"spotifyglass.redesign.shaders/library.json"] defaults:NSUserDefaults.standardUserDefaults];
    });
    return store;
}
