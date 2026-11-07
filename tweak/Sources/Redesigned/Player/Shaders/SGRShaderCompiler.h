#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

id<MTLDevice> SGRShaderDevice(void);
// Called on the shader worker queue, never from the render or main thread.
id<MTLRenderPipelineState> SGRShaderBuildPipeline(NSString *source, NSError **error);
