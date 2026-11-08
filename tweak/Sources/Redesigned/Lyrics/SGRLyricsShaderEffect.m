#import "SGRLyricsShaderEffect.h"
#import "SGRLyricsShaderSource.h"
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
static dispatch_queue_t renderQueue;

static void preparePipeline(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = MTLCreateSystemDefaultDevice();
        if (!device) return;
        queue = [device newCommandQueue];
        renderQueue = dispatch_queue_create("spoti.pw.lyrics.shader", DISPATCH_QUEUE_SERIAL);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
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
            id<MTLRenderPipelineState> built = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
            if (!built) SGLog(@"lyrics shader: %@", error.localizedDescription ?: @"Metal pipeline unavailable");
            dispatch_async(dispatch_get_main_queue(), ^{ pipeline = built; });
        });
    });
}

static UIImage *glyphMask(UILabel *source, CGFloat scale) {
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
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = scale;
    format.opaque = NO;
    format.preferredRange = UIGraphicsImageRendererFormatRangeStandard;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:source.bounds.size format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) { (void)context; [copy drawTextInRect:copy.bounds]; }];
}

typedef struct { vector_float2 position, uv, field; } SGRLyricsVertex;
typedef struct { float time, intensity; uint32_t style; float padding; } SGRLyricsUniforms;

@interface SGRLyricsShaderSubmission : NSObject
@property (atomic) BOOL enabled;
@end
@implementation SGRLyricsShaderSubmission
@end

@implementation SGRLyricsShaderEffect {
    __weak UIView *_root;
    NSArray<UILabel *> *_labels;
    NSArray<id<MTLTexture>> *_textures;
    CAMetalLayer *_surface;
    dispatch_semaphore_t _available;
    SGRLyricsShaderSubmission *_submission;
    NSUInteger _maskCount, _pixels, _surfacePixels;
    CGFloat _speed, _intensity;
    NSInteger _style;
    BOOL _failed;
}

+ (NSUInteger)activeMaskCount { return liveMasks; }
+ (NSUInteger)activeMaskPixels { return livePixels; }

- (instancetype)initWithLabels:(NSArray<UILabel *> *)labels root:(UIView *)root style:(NSInteger)style intensity:(CGFloat)intensity speed:(CGFloat)speed {
    if (!(self = [super init])) return nil;
    if (style < 1 || style > 5 || !labels.count || !isfinite(intensity) || intensity <= 0 || !isfinite(speed)) return nil;
    CGSize size = root.bounds.size;
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 || size.width > 1024 || size.height > 128) return nil;
    CGFloat scale = MIN(2, root.traitCollection.displayScale ?: 2);
    NSUInteger pixels = 0;
    for (UILabel *label in labels) {
        CGSize glyphSize = label.bounds.size;
        if (!isfinite(glyphSize.width) || !isfinite(glyphSize.height) || glyphSize.width <= 0 || glyphSize.height <= 0 || glyphSize.width > 2048 || glyphSize.height > 256) return nil;
        pixels += (NSUInteger)ceil(glyphSize.width * scale) * (NSUInteger)ceil(glyphSize.height * scale);
        if (pixels > kPixelLimit) return nil;
    }
    NSUInteger surfacePixels = (NSUInteger)ceil(size.width * scale) * (NSUInteger)ceil(size.height * 2 * scale);
    if (labels.count > kMaskLimit - liveMasks || pixels > kPixelLimit - livePixels ||
        liveSurfaces >= kSurfaceLimit || surfacePixels > kSurfacePixelLimit - liveSurfacePixels) return nil;
    preparePipeline();
    if (!device || !queue) return nil;
    MTKTextureLoader *loader = [[MTKTextureLoader alloc] initWithDevice:device];
    NSMutableArray *textures = [NSMutableArray arrayWithCapacity:labels.count];
    for (UILabel *label in labels) {
        UIImage *mask = glyphMask(label, scale);
        id<MTLTexture> texture = mask.CGImage ? [loader newTextureWithCGImage:mask.CGImage options:@{MTKTextureLoaderOptionSRGB: @NO, MTKTextureLoaderOptionOrigin: MTKTextureLoaderOriginTopLeft} error:nil] : nil;
        if (!texture) return nil;
        [textures addObject:texture];
    }
    _root = root;
    _labels = [labels copy];
    _textures = textures;
    _style = style;
    _intensity = MIN(1, intensity);
    _speed = MAX(0.35, MIN(2, speed));
    _available = dispatch_semaphore_create(1);
    _submission = [SGRLyricsShaderSubmission new];
    _surface = [CAMetalLayer layer];
    _surface.name = @"spoti.pw.lyrics.shader";
    _surface.device = device;
    _surface.pixelFormat = MTLPixelFormatBGRA8Unorm;
    _surface.opaque = NO;
    _surface.framebufferOnly = YES;
    _surface.contentsScale = scale;
    _surface.maximumDrawableCount = 3;
    _surface.allowsNextDrawableTimeout = YES;
    _surface.frame = CGRectMake(0, -size.height / 2, size.width, size.height * 2);
    _surface.drawableSize = CGSizeMake(ceil(size.width * scale), ceil(size.height * 2 * scale));
    _surface.hidden = YES;
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
    return self;
}

- (void)showTime:(double)seconds running:(BOOL)running {
    UIView *root = _root;
    if (!_surface || !isfinite(seconds)) return;
    BOOL visible = running && root.window && !root.hidden && !UIAccessibilityIsReduceMotionEnabled() && !_failed;
    _submission.enabled = visible;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _surface.hidden = !visible || !pipeline;
    [CATransaction commit];
    if (!visible || !pipeline || dispatch_semaphore_wait(_available, DISPATCH_TIME_NOW)) return;
    SGRLyricsUniforms uniforms = {(float)(MIN(1e9, MAX(0, seconds)) * _speed), (float)_intensity, (uint32_t)_style, 0};
    NSMutableData *geometry = [NSMutableData dataWithLength:sizeof(SGRLyricsVertex) * 6 * _labels.count];
    SGRLyricsVertex *vertices = geometry.mutableBytes;
    CGSize size = root.bounds.size, canvas = _surface.bounds.size;
    const vector_float2 uv[] = {{0,0},{0,1},{1,0},{1,0},{0,1},{1,1}};
    for (NSUInteger i = 0; i < _labels.count; i++) {
        UILabel *label = _labels[i];
        SGRLyricsVertex *quad = vertices + i * 6;
        if (label.hidden || label.alpha <= 0) continue;
        for (NSUInteger j = 0; j < 6; j++) {
            CGPoint local = CGPointMake(CGRectGetMinX(label.bounds) + uv[j].x * label.bounds.size.width,
                                       CGRectGetMinY(label.bounds) + uv[j].y * label.bounds.size.height);
            CGPoint position = [label convertPoint:local toView:root];
            quad[j].position = (vector_float2){position.x / canvas.width * 2 - 1, 1 - (position.y + size.height / 2) / canvas.height * 2};
            CGFloat x = label == root ? local.x : label.center.x - label.bounds.size.width / 2 + local.x;
            quad[j].field = (vector_float2){x / size.height, local.y / size.height};
            quad[j].uv = uv[j];
        }
    }
    dispatch_semaphore_t available = _available;
    SGRLyricsShaderSubmission *submission = _submission;
    CAMetalLayer *surface = _surface;
    NSArray<id<MTLTexture>> *textures = _textures;
    id<MTLRenderPipelineState> currentPipeline = pipeline;
    __weak SGRLyricsShaderEffect *weakSelf = self;
    dispatch_async(renderQueue, ^{
        @autoreleasepool {
            if (!submission.enabled) {
                dispatch_semaphore_signal(available);
                return;
            }
            id<CAMetalDrawable> drawable = [surface nextDrawable];
            id<MTLCommandBuffer> command = drawable ? [queue commandBuffer] : nil;
            if (!command) {
                dispatch_semaphore_signal(available);
                return;
            }
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = drawable.texture;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
            id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
            if (!encoder) {
                dispatch_semaphore_signal(available);
                return;
            }
            [encoder setRenderPipelineState:currentPipeline];
            [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
            const SGRLyricsVertex *quads = geometry.bytes;
            for (NSUInteger i = 0; i < textures.count; i++) {
                [encoder setVertexBytes:quads + i * 6 length:sizeof(SGRLyricsVertex) * 6 atIndex:0];
                [encoder setFragmentTexture:textures[i] atIndex:0];
                [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            }
            [encoder endEncoding];
            [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                dispatch_semaphore_signal(available);
                if (completed.status == MTLCommandBufferStatusError) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        SGRLyricsShaderEffect *effect = weakSelf;
                        if (!effect) return;
                        effect->_failed = YES;
                        [effect showTime:0 running:NO];
                        SGLog(@"lyrics shader: render failed, keeping static text (%@)", completed.error.localizedDescription);
                    });
                }
            }];
            [command presentDrawable:drawable];
            [command commit];
        }
    });
}

- (void)invalidate {
    _submission.enabled = NO;
    [_surface removeFromSuperlayer];
    if (_surfacePixels) liveSurfaces--;
    liveMasks -= _maskCount;
    livePixels -= _pixels;
    liveSurfacePixels -= _surfacePixels;
    _maskCount = _pixels = _surfacePixels = 0;
    _surface = nil;
    _labels = nil;
    _textures = nil;
}

- (void)dealloc { [self invalidate]; }
@end
