#import "SGRShaderCompiler.h"

id<MTLDevice> SGRShaderDevice(void) {
    static id<MTLDevice> device;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ device = MTLCreateSystemDefaultDevice(); });
    return device;
}

id<MTLRenderPipelineState> SGRShaderBuildPipeline(NSString *source, NSError **error) {
    if (error) *error = nil;
    id<MTLDevice> device = SGRShaderDevice();
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:error];
    id<MTLFunction> vertex = [library newFunctionWithName:@"vert"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"frag"];
    if (!vertex || !fragment) {
        if (error && !*error) *error = [NSError errorWithDomain:@"spotifyglass.redesign.shader" code:2 userInfo:@{NSLocalizedDescriptionKey: @"The shader needs vertex vert and fragment frag functions. See the template's Uniforms contract."}];
        return nil;
    }
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = vertex;
    descriptor.fragmentFunction = fragment;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    MTLRenderPipelineReflection *reflection;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:descriptor options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo reflection:&reflection error:error];
    if (!pipeline) return nil;
    BOOL uniforms = NO, valid = YES;
    for (id<MTLBinding> binding in reflection.vertexBindings) if (binding.used) valid = NO;
    for (id<MTLBinding> argument in reflection.fragmentBindings) {
        if (!argument.used) continue;
        if (argument.type != MTLBindingTypeBuffer || argument.index != 0 || ((id<MTLBufferBinding>)argument).bufferDataSize != 176) valid = NO;
        else uniforms = YES;
    }
    if (!valid || !uniforms) {
        if (error) *error = [NSError errorWithDomain:@"spotifyglass.redesign.shader" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Use the template's 176-byte Uniforms at fragment buffer(0), with no other buffers, textures or samplers."}];
        return nil;
    }
    return pipeline;
}

