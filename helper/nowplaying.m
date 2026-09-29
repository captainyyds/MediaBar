#import <Foundation/Foundation.h>
#include <libproc.h>
#include <dlfcn.h>

/// Reads the system's Now Playing session and prints it as one JSON line.
///
/// This has to be loaded into an Apple-signed interpreter — `/usr/bin/python3`
/// — rather than run as a compiled tool. MediaRemote hands its data to
/// interpreter-hosted processes and returns an empty dictionary to everything
/// else, which is why Pock's own Now Playing widget shows nothing.
///
/// Whatever owns the session answers: a browser, a music app, a video player.
/// Nothing here is specific to any of them.

typedef void (*GetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPID)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendCommand)(int, NSDictionary *);
typedef void (*RegisterNotifications)(dispatch_queue_t);
typedef void (*GetSupported)(dispatch_queue_t, void (^)(CFArrayRef));
typedef void (*SetElapsed)(double);

static NSString *const kPrefix = @"kMRMediaRemoteNowPlayingInfo";

static id field(NSDictionary *info, NSString *name) {
    return info[[kPrefix stringByAppendingString:name]];
}

/// Reads the session once and writes one JSON line. Shared by the one-shot
/// and the watcher so both speak exactly the same format.
static void emit(GetInfo getInfo, GetPID getPID) { @autoreleasepool {
    if (!getInfo) { printf("{\"ok\":false}\n"); fflush(stdout); return; }

    __block NSDictionary *info = nil;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    getInfo(dispatch_get_global_queue(0, 0), ^(NSDictionary *value) {
        info = [value copy];
        dispatch_semaphore_signal(gate);
    });
    if (dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC))) {
        printf("{\"ok\":false,\"reason\":\"timeout\"}\n");
        return;
    }
    if (info.count == 0) {
        printf("{\"ok\":true,\"playing\":false}\n");
        return;
    }

    NSMutableDictionary *out = [@{@"ok": @YES, @"playing": @YES} mutableCopy];
    for (NSString *name in @[@"Title", @"Artist", @"Album"]) {
        NSString *value = field(info, name);
        if ([value isKindOfClass:NSString.class] && value.length) out[name.lowercaseString] = value;
    }
    for (NSString *name in @[@"Duration", @"ElapsedTime", @"PlaybackRate"]) {
        NSNumber *value = field(info, name);
        if ([value isKindOfClass:NSNumber.class]) out[name.lowercaseString] = value;
    }
    // The anchor the live position is carried from: the moment the elapsed
    // time was true. That is `Timestamp`, when the info was published — not
    // `CurrentPlaybackDate`, which is the real-world date of the playback
    // position and only means something for a broadcast. Chrome happens to set
    // the two close together, which is how using the wrong one went unnoticed;
    // 汽水音乐 leaves CurrentPlaybackDate on one fixed day for every track, and
    // carrying from it put each of them twelve days past its end, pinned full.
    //
    // No fallback to CurrentPlaybackDate when Timestamp is missing: without an
    // anchor the widget shows the elapsed time standing still, which is at
    // worst stale, where a wrong anchor is wrong by any amount at all.
    NSDate *anchor = field(info, @"Timestamp");
    if ([anchor isKindOfClass:NSDate.class]) out[@"anchor"] = @(anchor.timeIntervalSince1970);

    NSData *artwork = field(info, @"ArtworkData");
    if ([artwork isKindOfClass:NSData.class]) out[@"artworkbytes"] = @(artwork.length);

    if (getPID) {
        __block int pid = 0;
        dispatch_semaphore_t pidGate = dispatch_semaphore_create(0);
        getPID(dispatch_get_global_queue(0, 0), ^(int value) {
            pid = value;
            dispatch_semaphore_signal(pidGate);
        });
        dispatch_semaphore_wait(pidGate, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        if (pid > 0) {
            // Identified from the process path rather than NSRunningApplication:
            // that one call is the only thing this helper needed AppKit for, and
            // loading AppKit into a fresh process cost more than everything else
            // here put together.
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_pidpath(pid, path, sizeof path) > 0) {
                NSString *executable = @(path);
                NSRange bundle = [executable rangeOfString:@".app/" options:NSBackwardsSearch];
                if (bundle.location != NSNotFound) {
                    NSString *root = [executable substringToIndex:bundle.location + 4];
                    NSString *plist = [root stringByAppendingPathComponent:@"Contents/Info.plist"];
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plist];
                    NSString *identifier = info[@"CFBundleIdentifier"];
                    NSString *name = info[@"CFBundleDisplayName"] ?: info[@"CFBundleName"];
                    if (identifier) out[@"app"] = identifier;
                    out[@"appname"] = name ?: root.lastPathComponent.stringByDeletingPathExtension;
                }
            }
        }
    }

    // Which transport commands the app actually answers. A page that never
    // registered a next-track handler should not be given a next-track button
    // that silently does nothing.
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    GetSupported getSupported = mr ? (GetSupported)dlsym(mr, "MRMediaRemoteGetSupportedCommands") : NULL;
    if (getSupported) {
        __block NSArray *list = nil;
        dispatch_semaphore_t gate = dispatch_semaphore_create(0);
        getSupported(dispatch_get_global_queue(0, 0), ^(CFArrayRef value) {
            list = value ? [(__bridge NSArray *)value copy] : nil;
            dispatch_semaphore_signal(gate);
        });
        if (!dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) {
            NSMutableArray *codes = [NSMutableArray new];
            for (id info in list) {
                if (![info respondsToSelector:@selector(command)]) continue;
                if (![[info valueForKey:@"enabled"] boolValue]) continue;
                NSNumber *code = [info valueForKey:@"command"];
                if (code) [codes addObject:code];
            }
            out[@"commands"] = codes;
        }
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:NULL];
    fwrite(json.bytes, 1, json.length, stdout);
    printf("\n");
    fflush(stdout);
}}

static void *openMediaRemote(void) {
    return dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
}

/// One reading, then exit.
void snapshot(void) {
    void *h = openMediaRemote();
    emit(h ? (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL,
         h ? (GetPID)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL);
}

/// Stays alive and writes a line whenever the session changes.
///
/// This replaces polling outright. MediaRemote posts on track changes, on
/// play/pause and on seeks — measured at under 300ms — and the position
/// between those events is arithmetic the widget already does for itself.
/// Nothing has to be asked on a timer.
void watch(void) { @autoreleasepool {
    void *h = openMediaRemote();
    GetInfo getInfo = h ? (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    GetPID getPID = h ? (GetPID)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID") : NULL;
    RegisterNotifications reg = h ? (RegisterNotifications)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    if (!getInfo || !reg) { printf("{\"ok\":false}\n"); fflush(stdout); return; }

    reg(dispatch_get_main_queue());
    emit(getInfo, getPID);

    // The three arrive together for one change; coalesce so the widget is not
    // handed the same state three times in a row.
    __block NSTimeInterval lastEmit = 0;
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRNowPlayingPlaybackQueueChangedNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
            usingBlock:^(NSNotification *note) {
                NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
                if (now - lastEmit < 0.15) return;
                lastEmit = now;
                emit(getInfo, getPID);
            }];
    }
    [NSRunLoop.mainRunLoop run];
}}

/// Sends a transport command to whatever owns the session.
///
/// The codes are MediaRemote's own: 0 play, 1 pause, 2 toggle, 3 stop,
/// 4 next, 5 previous. Like reading, this only works from an interpreter
/// host, so the widget routes control through here too rather than trying
/// to call MediaRemote itself.
void command(int code) { @autoreleasepool {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    SendCommand send = handle ? (SendCommand)dlsym(handle, "MRMediaRemoteSendCommand") : NULL;
    if (!send) { printf("{\"ok\":false}\n"); return; }
    Boolean accepted = send(code, nil);
    // The send is asynchronous. Returning here lets the interpreter tear the
    // process down before the message has actually gone out, which is why a
    // single press used to be dropped and three or four in a row were needed.
    // Spin briefly so it leaves.
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    printf("{\"ok\":%s}\n", accepted ? "true" : "false");
    fflush(stdout);
}}

/// Jumps playback to an absolute offset in seconds.
void seekTo(double seconds) { @autoreleasepool {
    void *handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    SetElapsed set = handle ? (SetElapsed)dlsym(handle, "MRMediaRemoteSetElapsedTime") : NULL;
    if (!set) { printf("{\"ok\":false}\n"); return; }
    set(seconds);
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
    printf("{\"ok\":true}\n");
    fflush(stdout);
}}

/// Writes the current track's cover as base64, or `ok:false` if there is none.
///
/// Deliberately not part of `snapshot()`. The artwork is tens of kilobytes and
/// does not change within a track, so folding it into the reading that runs
/// every second would be paying for the same bytes over and over. The widget
/// asks for it once, when the title changes, and only while it has somewhere
/// to show it.
void artwork(void) { @autoreleasepool {
    void *h = openMediaRemote();
    GetInfo getInfo = h ? (GetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    if (!getInfo) { printf("{\"ok\":false}\n"); fflush(stdout); return; }

    __block NSData *data = nil;
    dispatch_semaphore_t gate = dispatch_semaphore_create(0);
    getInfo(dispatch_get_global_queue(0, 0), ^(NSDictionary *info) {
        id value = field(info, @"ArtworkData");
        if ([value isKindOfClass:NSData.class]) data = [value copy];
        dispatch_semaphore_signal(gate);
    });
    if (dispatch_semaphore_wait(gate, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) || !data.length) {
        printf("{\"ok\":false}\n");
        fflush(stdout);
        return;
    }
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    printf("{\"ok\":true,\"artwork\":\"%s\"}\n", encoded.UTF8String);
    fflush(stdout);
}}
