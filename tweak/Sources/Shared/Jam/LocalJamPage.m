// Local Jam's own page inside Mod Settings: the master switch, hosting and
// joining, the aux, and the live state of the room. Rows that come and go use
// visible blocks, which the page re-reads every second it is on screen.
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "LocalJam.h"

// The hand-on subpage: one tap per nearby host, fresh at open. The join list
// cannot live in the main page's sections because there a row's text is fixed.
static UIViewController *SGLocalJamJoinSubpage(void) {
    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSString *key in SGLocalJamNearbyNames())
        [rows addObject:SGWithSymbol(SGActionRow(key, @"Join and follow their Jam", ^{
            if (!SGLocalJamJoinNamed(key))
                [SGLocalJamHubShared() setStatusLine:
                    @"They did not answer · open this page and try again"];
        }), @"person.2")];
    if (!rows.count)
        [rows addObject:SGActionRow(@"Nobody is hosting right now",
            @"Come back once someone has tapped Start hosting", nil)];
    return [[SGModPage alloc] initWithTitle:@"Join nearby" intro:nil
        sections:@[SGSection(nil, rows)]
        footer:@"Hosts appear while their Spotify is open with a Jam running. "
               @"Both phones need the Local Network permission for this to work."];
}

UIViewController *SGLocalJamPage(void) {
    SGLocalJamHub *at = SGLocalJamHubShared();

    SGModRow *master = SGWithSymbol(SGOptionRow(@"Local Jam",
        @"Listen together over this Wi-Fi, no Spotify account needed for the link · restart required",
        SGKeyLocalJam), @"person.2.wave.2");

    SGModRow *start = SGWithSymbol(SGActionRow(@"Start hosting", nil, ^{
        [at startHost];
    }), @"play.circle");
    start.visible = ^{ return (BOOL)!at.joined; };

    SGModRow *join = SGWithSymbol(SGPageRow(@"Join nearby…", ^UIViewController *{
        return SGLocalJamJoinSubpage();
    }), @"antenna.radiowaves.left.and.right");
    join.visible = ^{ return (BOOL)!at.joined; };

    SGModRow *leave = SGActionRow(@"Leave the Jam", nil, ^{ [at leave]; });
    leave.visible = ^{ return at.joined; };

    SGModRow *aux = SGOptionRow(@"Pass the aux",
        @"Guests' next, back and seek move your player", SGKeyLocalJamAux);
    aux.visible = ^{ return at.hosting; };
    aux.waitsOn = SGKeyLocalJam;
    aux.changed = ^(BOOL on) { at.guestControl = on; };

    SGModRow *add = SGActionRow(@"Add this song to the Jam", nil, ^{
        [at queueCurrentTrack];
    });
    add.visible = ^{ return at.joined; };

    SGModRow *status = SGStatRow(@"Room", ^NSString *{ return at.status.length ? at.status : @"Not in a Jam"; });
    status.refreshOn = SGLocalJamDidChangeNotification;
    SGModRow *members = SGStatRow(@"Listeners", ^NSString *{
        return at.joined ? [at.memberNames componentsJoinedByString:@" · "] : @"";
    });
    members.refreshOn = SGLocalJamDidChangeNotification;
    SGModRow *song = SGStatRow(@"Playing", ^NSString *{ return at.nowPlayingTitle ?: @""; });
    song.refreshOn = SGLocalJamDidChangeNotification;
    SGModRow *queue = SGStatRow(@"Shared queue", ^NSString *{
        if (!at.queue.count) return @"";
        SGLocalJamEntry *head = at.queue.firstObject;
        return [NSString stringWithFormat:@"%lu queued · next %@ — %@",
            (unsigned long)at.queue.count, head.title, head.artist];
    });
    queue.refreshOn = SGLocalJamDidChangeNotification;
    SGModRow *ping = SGStatRow(@"Round trip", ^NSString *{
        if (!at.joined || at.hosting || at.ping < 0) return @"";
        return [NSString stringWithFormat:@"%ld ms", (long)at.ping];
    });
    ping.refreshOn = SGLocalJamDidChangeNotification;

    return [[SGModPage alloc] initWithTitle:@"Local Jam"
        intro:nil
        sections:@[
            SGNotedSection(@"Session", @[master, start, join, leave, aux], SGRestartNote),
            SGNotedSection(@"In the room", @[add, status, members, song, queue, ping],
                @"The host's Spotify plays the room's radio: one song at a time from the "
                @"shared queue, with everyone following. Keep both phones unlocked for "
                @"the first seconds of a track while the positions line up."),
        ]
        footer:@"Spotify itself never learns about any of this: the room lives on "
               @"your Wi-Fi. Guests who cannot reach a song keep following the "
               @"moment they open it."];
}
