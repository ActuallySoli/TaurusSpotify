#import "SGRLyricsShaderEffect.h"
#import "SGRLyricsShaderSource.h"
#import "SGRLyricsShaderPolicy.h"
#import "Core/SGLog.h"
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

static const NSUInteger kMaskLimit = 48, kPixelLimit = 512 * 1024;
static const NSUInteger kSurfaceLimit = 12, kSurfacePixelLimit = 2 * 1024 * 1024;
static NSUInteger liveMasks, livePixels, liveSurfaces, liveSurfacePixels;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;
static dispatch_queue_t resourceQueue, renderQueue;
static NSHashTable<SGRLyricsShaderEffect *> *effects;
static CFTimeInterval memoryCooldown;
static NSUInteger pendingPreparations;
static dispatch_semaphore_t frameSlots;
#if SGR_LYRICS_SHADER_TESTING
static NSTimeInterval testingRenderDelay;
#endif

static void preparePipeline(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        effects = [NSHashTable weakObjectsHashTable];
        frameSlots = dispatch_semaphore_create(kSurfaceLimit);
        resourceQueue = dispatch_queue_create("spoti.pw.lyrics.resources", DISPATCH_QUEUE_SERIAL);
        renderQueue = dispatch_queue_create("spoti.pw.lyrics.render", DISPATCH_QUEUE_CONCURRENT);
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            memoryCooldown = CACurrentMediaTime() + 15;
            for (SGRLyricsShaderEffect *effect in effects.allObjects) [effect invalidate];
        }];
        dispatch_async(resourceQueue, ^{
            @autoreleasepool {
                device = MTLCreateSystemDefaultDevice();
                queue = [device newCommandQueue];
                NSError *error = nil;
                id<MTLLibrary> library = [device newLibraryWithSource:SGRLyricsShaderSource options:nil error:&error];
                MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
                descriptor.vertexFunction = [library newFunctionWithName:@"lyricsVertex"];
                descriptor.fragmentFunction = [library newFunctionWithName:@"lyricsFragment"];
                MTLRenderPipelineColorAttachmentDescriptor *color = descriptor.colorAttachments[0];
                color.pixelFormat = MTLPixelFormatBGRA8Unorm;
                color.blendingEnabled = YES;
                color.sourceRGBBlendFactor = color.sourceAlphaBlendFactor = MTLBlendFactorOne;
                color.destinationRGBBlendFactor = color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
                pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
                if (!pipeline) SGLog(@"lyrics shader: %@", error.localizedDescription ?: @"Metal pipeline unavailable");
            }
        });
    });
}

static void drawGlyph(UILabel *source) {
    UILabel *copy = [[UILabel alloc] initWithFrame:source.bounds];
    copy.font = source.font;
    copy.text = source.text;
    copy.textColor = UIColor.whiteColor;
    copy.textAlignment = source.textAlignment;
    copy.baselineAdjustment = source.baselineAdjustment;
    copy.numberOfLines = source.numberOfLines;
    copy.lineBreakMode = source.lineBreakMode;
    if (source.attributedText) {
        NSMutableAttributedString *text = [source.attributedText mutableCopy];
        [text addAttribute:NSForegroundColorAttributeName value:UIColor.whiteColor range:NSMakeRange(0, text.length)];
        copy.attributedText = text;
    }
    [copy drawTextInRect:copy.bounds];
}

typedef struct { vector_float2 position, uv, field; } SGRLyricsVertex;
typedef struct { float time, intensity; uint32_t style; float padding; vector_float4 ink; } SGRLyricsUniforms;

@interface SGRLyricsShaderSubmission : NSObject
@property (atomic) BOOL enabled;
@property (atomic) BOOL cancelled;
@property (atomic) NSUInteger generation;
@end
@implementation SGRLyricsShaderSubmission
@end

@implementation SGRLyricsShaderEffect {
    __weak UIView *_root;
    NSArray<UILabel *> *_labels;
    NSArray<UIColor *> *_inks;
    NSArray *_attributed, *_clearAttributed;
    NSArray<NSValue *> *_rects;
    id<MTLTexture> _texture;
    id<MTLBuffer> _vertices;
    CAMetalLayer *_surface;
    dispatch_semaphore_t _available;
    SGRLyricsShaderSubmission *_submission;
    NSUInteger _maskCount, _pixels, _surfacePixels;
    CGFloat _speed, _intensity;
    CGSize _wordSize;
    vector_float4 _ink;
    NSInteger _style;
    BOOL _failed, _ready, _shown, _running;
    CFTimeInterval _lastFrame;
    double _lastTime;
}

+ (void)prepare { preparePipeline(); }
#if SGR_LYRICS_SHADER_TESTING
+ (void)setTestingRenderDelay:(NSTimeInterval)delay { testingRenderDelay = MAX(0, delay); }
#endif
+ (NSUInteger)activeMaskCount { return liveMasks; }
+ (NSUInteger)activeMaskPixels { return livePixels; }

- (instancetype)initWithLabels:(NSArray<UILabel *> *)labels root:(UIView *)root style:(NSInteger)style intensity:(CGFloat)intensity speed:(CGFloat)speed {
    if (!(self = [super init])) return nil;
    if (style < 1 || style > 5 || !labels.count || labels.count > kMaskLimit || !isfinite(intensity) || intensity <= 0 || !isfinite(speed)) return nil;
    CGSize size = root.bounds.size;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 || size.width > 1024 || size.height > 128) return nil;
    preparePipeline();
    if (pendingPreparations >= kSurfaceLimit) return nil;
    if (CACurrentMediaTime() < memoryCooldown || NSProcessInfo.processInfo.thermalState == NSProcessInfoThermalStateCritical) return nil;
    CGFloat scale = MIN(2, root.traitCollection.displayScale ?: 2);
    NSUInteger atlasWidth = 0, atlasHeight = 0;
    NSMutableArray<NSValue *> *tiles = [NSMutableArray arrayWithCapacity:labels.count];
    for (UILabel *label in labels) {
        CGSize glyph = label.bounds.size;
        if (!isfinite(glyph.width) || !isfinite(glyph.height) || glyph.width <= 0 || glyph.height <= 0 || glyph.width > 2048 || glyph.height > 256) return nil;
        NSUInteger width = (NSUInteger)ceil(glyph.width * scale), height = (NSUInteger)ceil(glyph.height * scale);
        [tiles addObject:[NSValue valueWithCGRect:CGRectMake(atlasWidth + 1, 1, width, height)]];
        atlasWidth += width + 2;
        atlasHeight = MAX(atlasHeight, height + 2);
    }
    if (atlasWidth > 8192) return nil;
    NSUInteger pixels = atlasWidth * atlasHeight;
    NSUInteger surfacePixels = (NSUInteger)ceil(size.width * scale) * (NSUInteger)ceil(size.height * 2 * scale);
    if (labels.count > kMaskLimit - liveMasks || pixels > kPixelLimit - livePixels ||
        liveSurfaces >= kSurfaceLimit || surfacePixels > kSurfacePixelLimit - liveSurfacePixels) return nil;
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(atlasWidth / scale, atlasHeight / scale) format:format];
    UIImage *atlas = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        for (NSUInteger i = 0; i < labels.count; i++) {
            CGRect tile = tiles[i].CGRectValue;
            CGContextSaveGState(context.CGContext);
            CGContextTranslateCTM(context.CGContext, tile.origin.x / scale, tile.origin.y / scale);
            CGContextClipToRect(context.CGContext, (CGRect){CGPointZero, labels[i].bounds.size});
            drawGlyph(labels[i]);
            CGContextRestoreGState(context.CGContext);
        }
    }];
    if (!atlas.CGImage) return nil;
    NSMutableArray *inks = [NSMutableArray array], *attributed = [NSMutableArray array], *clear = [NSMutableArray array];
    NSMutableArray *rects = [NSMutableArray array];
    for (NSUInteger i = 0; i < labels.count; i++) {
        UILabel *label = labels[i];
        [inks addObject:label.textColor ?: UIColor.whiteColor];
        [attributed addObject:label.attributedText ?: NSNull.null];
        NSMutableAttributedString *hidden = [label.attributedText mutableCopy];
        if (hidden.length) [hidden addAttribute:NSForegroundColorAttributeName value:UIColor.clearColor range:NSMakeRange(0, hidden.length)];
        [clear addObject:hidden ?: NSNull.null];
        CGRect tile = tiles[i].CGRectValue;
        [rects addObject:[NSValue valueWithCGRect:CGRectMake(tile.origin.x / atlasWidth, tile.origin.y / atlasHeight,
            label.bounds.size.width * scale / atlasWidth, label.bounds.size.height * scale / atlasHeight)]];
    }
    CGFloat r = 1, g = 1, b = 1, a = 1;
    [inks.firstObject getRed:&r green:&g blue:&b alpha:&a];
    _ink = (vector_float4){r,g,b,a};
    _root = root;
    _wordSize = size;
    _labels = [labels copy];
    _inks = inks;
    _attributed = attributed;
    _clearAttributed = clear;
    _rects = rects;
    _style = style;
    _intensity = MIN(1, intensity);
    _speed = MAX(0.35, MIN(2, speed));
    _lastTime = NAN;
    _available = dispatch_semaphore_create(1);
    _submission = [SGRLyricsShaderSubmission new];
    _surface = [CAMetalLayer layer];
    _surface.name = @"spoti.pw.lyrics.shader";
    _surface.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _surface.opaque = NO;
    _surface.framebufferOnly = YES;
    _surface.contentsScale = scale;
    _surface.maximumDrawableCount = 2;
    _surface.allowsNextDrawableTimeout = YES;
    _surface.frame = CGRectMake(0, -size.height / 2, size.width, size.height * 2);
    _surface.drawableSize = CGSizeMake(ceil(size.width * scale), ceil(size.height * 2 * scale));
    _surface.hidden = YES;
    _surface.shadowColor = labels.firstObject.layer.shadowColor;
    _surface.shadowOffset = CGSizeZero;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [root.layer addSublayer:_surface];
    [CATransaction commit];
    _maskCount = labels.count;
    _pixels = pixels;
    _surfacePixels = surfacePixels;
    liveMasks += _maskCount;
    livePixels += _pixels;
    liveSurfaces++;
    liveSurfacePixels += _surfacePixels;
    [effects addObject:self];
    __weak SGRLyricsShaderEffect *weakSelf = self;
    SGRLyricsShaderSubmission *submission = _submission;
    NSUInteger vertexCount = labels.count * 6;
    pendingPreparations++;
    dispatch_async(resourceQueue, ^{
        @autoreleasepool {
            if (submission.cancelled || !pipeline || !queue) {
                dispatch_async(dispatch_get_main_queue(), ^{ pendingPreparations--; });
                return;
            }
            MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:device];
            id<MTLTexture> texture = [loader newTextureWithCGImage:atlas.CGImage options:@{MTKTextureLoaderOptionSRGB:@NO, MTKTextureLoaderOptionOrigin:MTKTextureLoaderOriginTopLeft} error:nil];
            id<MTLBuffer> vertices = [device newBufferWithLength:sizeof(SGRLyricsVertex) * vertexCount options:MTLResourceStorageModeShared];
            dispatch_async(dispatch_get_main_queue(), ^{
                pendingPreparations--;
                SGRLyricsShaderEffect *effect = weakSelf;
                if (!effect || !effect->_surface) return;
                effect->_surface.device = device;
                effect->_texture = texture;
                effect->_vertices = vertices;
                effect->_ready = texture && vertices;
                effect->_failed = !effect->_ready;
            });
        }
    });
    return self;
}

- (void)setShaderVisible:(BOOL)visible {
    if (_shown == visible) return;
    _shown = visible;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _surface.hidden = !visible;
    for (NSUInteger i = 0; i < _labels.count; i++) {
        UILabel *label = _labels[i];
        id text = visible ? _clearAttributed[i] : _attributed[i];
        if (text != NSNull.null) label.attributedText = text;
        label.textColor = visible ? UIColor.clearColor : _inks[i];
    }
    [CATransaction commit];
}

- (void)showTime:(double)seconds running:(BOOL)running {
    UIView *root = _root;
    if (!_surface) return;
    NSUInteger fps = SGRLyricsShaderFrameRate(NSProcessInfo.processInfo.thermalState, NSProcessInfo.processInfo.lowPowerModeEnabled);
    BOOL visible = running && UIApplication.sharedApplication.applicationState == UIApplicationStateActive && isfinite(seconds) && root.window && !root.hidden && !UIAccessibilityIsReduceMotionEnabled() && !_failed && fps && CGSizeEqualToSize(root.bounds.size, _wordSize);
    BOOL seek = isfinite(_lastTime) && fabs(seconds - _lastTime) > 0.25;
    _lastTime = seconds;
    if (_running != visible || seek) {
        _running = visible;
        _submission.generation++;
        _lastFrame = 0;
        [self setShaderVisible:NO];
    }
    _submission.enabled = visible;
    if (!visible || !_ready) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - _lastFrame < 1.0 / fps - 0.001 || dispatch_semaphore_wait(_available, DISPATCH_TIME_NOW)) return;
    if (dispatch_semaphore_wait(frameSlots, DISPATCH_TIME_NOW)) {
        dispatch_semaphore_signal(_available);
        return;
    }
    _lastFrame = now;
    NSUInteger generation = _submission.generation;
    SGRLyricsUniforms uniforms = {(float)(MIN(1e9, MAX(0, seconds)) * _speed), (float)_intensity, (uint32_t)_style, 0, _ink};
    SGRLyricsVertex *vertices = _vertices.contents;
    CGSize size = _wordSize, canvas = _surface.bounds.size;
    const vector_float2 corners[] = {{0,0},{0,1},{1,0},{1,0},{0,1},{1,1}};
    CGFloat glowOpacity = 0, glowRadius = 0;
    memset(vertices, 0, sizeof(SGRLyricsVertex) * 6 * _labels.count);
    for (NSUInteger i = 0; i < _labels.count; i++) {
        UILabel *label = _labels[i];
        if (label.hidden || label.alpha <= 0) continue;
        if (label != root) {
            glowOpacity = MAX(glowOpacity, label.layer.shadowOpacity);
            glowRadius = MAX(glowRadius, label.layer.shadowRadius);
        }
        CGRect tile = _rects[i].CGRectValue;
        for (NSUInteger j = 0; j < 6; j++) {
            CGPoint local = CGPointMake(CGRectGetMinX(label.bounds) + corners[j].x * label.bounds.size.width,
                                       CGRectGetMinY(label.bounds) + corners[j].y * label.bounds.size.height);
            CGPoint position = [label convertPoint:local toView:root];
            SGRLyricsVertex *v = vertices + i * 6 + j;
            v->position = (vector_float2){position.x / canvas.width * 2 - 1, 1 - (position.y + size.height / 2) / canvas.height * 2};
            CGFloat x = label == root ? local.x : label.center.x - label.bounds.size.width / 2 + local.x;
            v->field = (vector_float2){x / size.height, local.y / size.height};
            v->uv = (vector_float2){tile.origin.x + corners[j].x * tile.size.width, tile.origin.y + corners[j].y * tile.size.height};
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _surface.shadowOpacity = glowOpacity;
    _surface.shadowRadius = glowRadius;
    [CATransaction commit];
    dispatch_semaphore_t available = _available;
    SGRLyricsShaderSubmission *submission = _submission;
    CAMetalLayer *surface = _surface;
    id<MTLTexture> texture = _texture;
    id<MTLBuffer> geometry = _vertices;
    NSUInteger count = _labels.count * 6;
    BOOL reveal = !_shown;
    __weak SGRLyricsShaderEffect *weakSelf = self;
#if SGR_LYRICS_SHADER_TESTING
    NSTimeInterval delay = testingRenderDelay;
#endif
    dispatch_async(renderQueue, ^{
        @autoreleasepool {
#if SGR_LYRICS_SHADER_TESTING
            if (delay > 0) [NSThread sleepForTimeInterval:delay];
#endif
            if (!submission.enabled || submission.generation != generation) {
                dispatch_semaphore_signal(frameSlots);
                dispatch_semaphore_signal(available);
                return;
            }
            id<CAMetalDrawable> drawable = [surface nextDrawable];
            if (!submission.enabled || submission.generation != generation) {
                dispatch_semaphore_signal(frameSlots);
                dispatch_semaphore_signal(available);
                return;
            }
            id<MTLCommandBuffer> command = drawable ? [queue commandBuffer] : nil;
            if (!command) {
                dispatch_semaphore_signal(frameSlots);
                dispatch_semaphore_signal(available);
                return;
            }
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = drawable.texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
            id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
            if (!encoder) {
                dispatch_semaphore_signal(frameSlots);
                dispatch_semaphore_signal(available);
                return;
            }
            [encoder setRenderPipelineState:pipeline];
            [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            [encoder setVertexBuffer:geometry offset:0 atIndex:0];
            [encoder setFragmentTexture:texture atIndex:0];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:count];
            [encoder endEncoding];
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                BOOL failed = completed.status == MTLCommandBufferStatusError;
                if (reveal || failed) dispatch_async(dispatch_get_main_queue(), ^{
                    SGRLyricsShaderEffect *effect = weakSelf;
                    if (!effect || !effect->_surface || submission.generation != generation) return;
                    if (failed) {
                        effect->_failed = YES;
                        [effect showTime:0 running:NO];
                        SGLog(@"lyrics shader: render failed, keeping static text (%@)", completed.error.localizedDescription);
                    } else if (submission.enabled) [effect setShaderVisible:YES];
                });
                dispatch_semaphore_signal(frameSlots);
                dispatch_semaphore_signal(available);
            }];
            [command presentDrawable:drawable];
            [command commit];
        }
    });
}

- (void)invalidate {
    _submission.cancelled = YES;
    _submission.enabled = NO;
    _submission.generation++;
    [self setShaderVisible:NO];
    [_surface removeFromSuperlayer];
    [effects removeObject:self];
    if (_surfacePixels) liveSurfaces--;
    liveMasks -= _maskCount;
    livePixels -= _pixels;
    liveSurfacePixels -= _surfacePixels;
    _maskCount = _pixels = _surfacePixels = 0;
    _surface = nil;
    _labels = nil;
    _texture = nil;
    _vertices = nil;
    _ready = NO;
}

- (void)dealloc { [self invalidate]; }
@end
