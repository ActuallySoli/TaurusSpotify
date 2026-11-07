#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Jam.h"
#import "LocalJam.h"
#import "WebJam.h"

SGModSection *SGJamSettingsSection(void) {
    SGModRow *status = SGStatRow(@"Last Jam result", ^NSString *{ return SGJamLastResult(); });
    status.refreshOn = SGJamStatusDidChangeNotification;
    SGModRow *failure = SGStatRow(@"Last Jam failure", ^NSString *{ return SGJamLastFailure(); });
    failure.refreshOn = SGJamStatusDidChangeNotification;
    SGModRow *start = SGActionRow(@"Start a Jam", @"Opens Spotify's own Jam dialog", ^{
        if (!SGJamOpenStartSheet()) SGLog(@"jam: no link handler for the start sheet");
    });
    return SGNotedSection(@"Jam", @[
        SGWithSymbol(SGSwitchRow(@"Unlock Jam", @"Show available Jam options; this does not change your account subscription", SGKeyJamUnlock), @"lock.open"),
        SGWithSymbol(SGSwitchRow(@"Show Jam controls", @"Show Spotify's Jam entry points", SGKeyJamControls), @"person.2.wave.2"),
        SGWithSymbol(start, @"person.2.fill"),
        SGOptionRow(@"Jam compatibility", @"Use your real account identity; this does not grant Premium. Restart required", SGKeyJamAccountIdentity),
        SGPageRow(@"Local Jam", ^UIViewController *{ return SGLocalJamPage(); }),
        SGWithSymbol(SGPageRow(@"Web Jam", ^UIViewController *{ return SGWebJamPage(); }), @"globe"),
        status,
        failure,
    ], @"Restart Spotify after changing these options. To join a Premium host on a Free account, choose In person in Spotify's invitation. Remote listening requires Premium on the joining account too; the sender having Premium is not enough. Hosting and invitation access are decided by Spotify. Jam compatibility preserves Spotify's account identity while playback overrides remain separate. Last Jam failure distinguishes a server refusal from a connection error.");
}
