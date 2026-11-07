// The Shader background: an animated Metal field behind the player, one of eight built-in looks or a local Metal profile drawn by one
// fragment shader, moving with what plays (SGRSpectrum's bands, a bass level and a beat pulse read off the
// sound) and leaning with the phone's tilt (Core Motion's gravity). The cover's colors light it.
#import <UIKit/UIKit.h>

// The looks, by name, Nebula first.
NSArray<NSString *> *SGRShaderNames(void);
// The chosen look, stored under its own key; setting it applies at once to every shader view there is.
#define SGRKeyShaderStyle @"spotifyglass.redesign.player.shader"
NSInteger SGRShaderIndex(void);
void SGRSetShaderIndex(NSInteger index);
BOOL SGRShaderReady(void);

// Local Metal profiles use vert/frag and the documented Uniforms contract.
UIViewController *SGRShaderLibrarySettingsPage(void);
NSString *SGRShaderTemplateSource(void);
void SGRShaderValidateSource(NSString *source, void (^completion)(NSError *error));
void SGRShaderLibraryDidChange(void);
