#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <simd/simd.h>
#import "Redesigned/Lyrics/SGRLyricsShaderSource.h"

static void require(BOOL condition, NSString *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}

typedef struct { vector_float2 position, uv, field; } Vertex;
typedef struct { float time, intensity; uint32_t style; float padding; } Uniforms;

static NSData *render(id<MTLDevice> device, id<MTLRenderPipelineState> pipeline, id<MTLCommandQueue> queue,
                      NSUInteger style, float time, float intensity) {
    const NSUInteger width = 128, height = 64;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [device newTextureWithDescriptor:descriptor];
    descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:2 height:2 mipmapped:NO];
    descriptor.usage = MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> glyph = [device newTextureWithDescriptor:descriptor];
    uint8_t mask[] = {255,255,255,0, 255,255,255,255, 255,255,255,0, 255,255,255,255};
    [glyph replaceRegion:MTLRegionMake2D(0,0,2,2) mipmapLevel:0 withBytes:mask bytesPerRow:8];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLCommandBuffer> buffer = [queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    Vertex vertices[] = {{{-1,1},{0,0},{0,0}}, {{-1,-1},{0,1},{0,1}}, {{1,1},{1,0},{2,0}},
                         {{1,1},{1,0},{2,0}}, {{-1,-1},{0,1},{0,1}}, {{1,-1},{1,1},{2,1}}};
    Uniforms uniforms = {time,intensity,(uint32_t)style,0};
    [encoder setRenderPipelineState:pipeline];
    [encoder setVertexBytes:vertices length:sizeof(vertices) atIndex:0];
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:glyph atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [encoder endEncoding];
    [buffer commit];
    [buffer waitUntilCompleted];
    require(buffer.status == MTLCommandBufferStatusCompleted, buffer.error.description ?: @"GPU render failed");
    NSMutableData *pixels = [NSMutableData dataWithLength:width*height*4];
    [target getBytes:pixels.mutableBytes bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
    return pixels;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, @"Metal device missing");
    NSError *error;
    id<MTLLibrary> library = [device newLibraryWithSource:SGRLyricsShaderSource options:nil error:&error];
    require(library != nil, error.description ?: @"Shader compile failed");
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"lyricsVertex"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"lyricsFragment"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    require(pipeline != nil, error.description ?: @"Pipeline failed");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    NSMutableArray *styles = [NSMutableArray array];
    for (NSUInteger style = 1; style <= 5; style++) {
        NSData *first = render(device,pipeline,queue,style,0,1);
        NSData *later = render(device,pipeline,queue,style,1.7,1);
        NSData *repeat = render(device,pipeline,queue,style,0,1);
        NSData *zero = render(device,pipeline,queue,style,0,0);
        NSData *half = render(device,pipeline,queue,style,0,0.5);
        require(![first isEqual:later], @"Effect must move with time");
        require([first isEqual:repeat], @"Seeking back must reproduce the same frame");
        require(![styles containsObject:first], @"Each shader must have a distinct appearance");
        [styles addObject:first];
        const uint8_t *bytes=first.bytes, *empty=zero.bytes, *dim=half.bytes;
        NSUInteger lit = 0;
        for (NSUInteger p=0; p<first.length; p+=4) {
            require(bytes[p]<=bytes[p+3] && bytes[p+1]<=bytes[p+3] && bytes[p+2]<=bytes[p+3], @"Output must have premultiplied alpha");
            require(empty[p]==0 && empty[p+1]==0 && empty[p+2]==0 && empty[p+3]==0, @"Zero intensity must be transparent");
            require(abs(2*dim[p+3]-bytes[p+3]) <= 1, @"Intensity must scale alpha");
            if (bytes[p+3]) lit++;
        }
        require(lit>0 && bytes[3]==0 && bytes[127*4+3]==255, @"Glyph mask must preserve clear and filled regions");
        printf("PASS style %lu: animation, seek, alpha, intensity and distinct output\n", (unsigned long)style);
    }
    return 0;
}}
