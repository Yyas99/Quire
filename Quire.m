// Quire: a fast, quiet Markdown notes app for macOS.
// One Objective-C file, AppKit + TextKit 1. Opens an Obsidian-style vault (a folder of .md and .canvas files) in place.
// Build: double-click "Build Quire.command", or run ./quire. Needs only Apple's Command Line Tools.
// MIT licence (see LICENSE).

#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <CoreText/CoreText.h>

#pragma mark - Settings keys

static NSString *const kVaultPath   = @"vaultPath";
static NSString *const kLastNote    = @"lastNote";
static NSString *const kExpanded    = @"expandedFolders";
static NSString *const kSortMode    = @"sortMode";
static NSString *const kFolds       = @"folds";
static NSString *const kCarets      = @"carets";
static NSString *const kFontSize    = @"fontSize";
static NSString *const kPageWidth   = @"pageWidth";
static NSString *const kDailyFmt    = @"dailyFormat";
static NSString *const kWeeklyFmt   = @"weeklyFormat";
static NSString *const kNewNoteLoc  = @"newNoteLocation";   // 0 next to current note, 1 vault root
static NSString *const kSidebarW    = @"sidebarWidth";
static NSString *const kSidebarHide = @"sidebarHidden";

static NSUserDefaults *Defaults(void) { return NSUserDefaults.standardUserDefaults; }

#pragma mark - Palette and type

static NSColor *Hex(uint32_t h) {
    return [NSColor colorWithSRGBRed:((h >> 16) & 0xFF) / 255.0 green:((h >> 8) & 0xFF) / 255.0 blue:(h & 0xFF) / 255.0 alpha:1];
}
static NSColor *HexA(uint32_t h, CGFloat a) { return [Hex(h) colorWithAlphaComponent:a]; }

// Graphite: a dotted desk with a darker page laid on it.
static NSColor *qDesk, *qDot, *qPage, *qPageEdge, *qSide, *qSideHover, *qSideSel, *qSideActive, *qText, *qHead,
               *qBody2, *qFolder, *qMuted, *qFaint, *qMark, *qLink, *qLinkLine, *qCode, *qCodeBg, *qInlineCodeBg,
               *qRule, *qHighlight, *qTag, *qBorder, *qQuoteBar, *qBox, *qBoxDone;

static void InitPalette(void) {
    qDesk = Hex(0x121212);      qDot = Hex(0x262626);       qPage = Hex(0x121212);   qPageEdge = Hex(0x1c1c1c);
    qSide = Hex(0x161616);      qSideHover = Hex(0x1d1d1d); qSideSel = Hex(0x222222); qSideActive = Hex(0x262626);
    qText = Hex(0xd9d7d2);      qHead = Hex(0xf1efea);      qBody2 = Hex(0xa3a09a);  qFolder = Hex(0xbdbab4);
    qMuted = Hex(0x6f6d69);     qFaint = Hex(0x55534f);     qMark = Hex(0x45433f);
    qLink = Hex(0xe6e2d8);      qLinkLine = Hex(0x5a5751);
    qCode = Hex(0xcfcac0);      qCodeBg = Hex(0x181818);    qInlineCodeBg = Hex(0x1f1f1f);
    qRule = Hex(0x2c2c2c);      qHighlight = HexA(0xe8d9a8, 0.17); qTag = Hex(0x9a958c);
    qBorder = Hex(0x262626);    qQuoteBar = Hex(0x3a3835);  qBox = Hex(0x4a4844);    qBoxDone = Hex(0xcfccc5);
}

static CGFloat gBase = 17;                 // body text size
static NSMutableDictionary *gFontCache;

static NSFont *Serif(CGFloat size, BOOL bold, BOOL italic) {
    NSString *key = [NSString stringWithFormat:@"%.2f-%d-%d", size, bold, italic];
    NSFont *f = gFontCache[key];
    if (f) return f;
    f = [NSFont fontWithName:@"Charter-Roman" size:size];
    if (!f) f = [NSFont fontWithName:@"Iowan Old Style" size:size];
    if (!f) f = [NSFont fontWithName:@"Georgia" size:size];
    if (!f) f = [NSFont systemFontOfSize:size];
    NSFontManager *fm = NSFontManager.sharedFontManager;
    if (bold) f = [fm convertFont:f toHaveTrait:NSBoldFontMask];
    if (italic) f = [fm convertFont:f toHaveTrait:NSItalicFontMask];
    gFontCache[key] = f;
    return f;
}
static NSFont *Mono(CGFloat size) { return [NSFont monospacedSystemFontOfSize:size weight:NSFontWeightRegular]; }
static NSFont *UIFont(CGFloat size, NSFontWeight w) { return [NSFont systemFontOfSize:size weight:w]; }

#pragma mark - Small helpers

static NSString *Trim(NSString *s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }

static NSImage *Symbol(NSString *name, CGFloat pt, NSFontWeight w) {
    NSImage *im = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!im) return nil;
    return [im imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pt weight:w]];
}

static NSString *SafeName(NSString *s) {
    NSMutableString *m = [Trim(s ?: @"") mutableCopy];
    for (NSString *bad in @[@"/", @":", @"\\", @"\n", @"\r", @"\t"])
        [m replaceOccurrencesOfString:bad withString:@"-" options:0 range:NSMakeRange(0, m.length)];
    while ([m hasPrefix:@"."]) [m deleteCharactersInRange:NSMakeRange(0, 1)];
    return m.length ? m : @"Untitled";
}

// dir/base.ext, or dir/base 1.ext, dir/base 2.ext ... whichever is free. ext may be empty (folders).
static NSString *FreePath(NSString *dir, NSString *base, NSString *ext) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *(^make)(NSString *) = ^NSString *(NSString *b) {
        NSString *p = [dir stringByAppendingPathComponent:b];
        return ext.length ? [p stringByAppendingPathExtension:ext] : p;
    };
    NSString *p = make(base);
    for (int i = 1; [fm fileExistsAtPath:p]; i++) p = make([NSString stringWithFormat:@"%@ %d", base, i]);
    return p;
}

static NSDate *ModDate(NSString *path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}

static NSString *ReadText(NSString *path) {
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSWindowsCP1252StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    return s;
}

static NSRegularExpression *RX(NSString *pattern, NSRegularExpressionOptions o) {
    NSError *e = nil;
    NSRegularExpression *r = [NSRegularExpression regularExpressionWithPattern:pattern options:o error:&e];
    if (!r) NSLog(@"Quire: bad regex %@: %@", pattern, e);
    return r;
}

static void RoundRect(NSRect r, CGFloat radius, NSColor *fill) {
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius] fill];
}

static NSTextField *Label(NSString *s, NSFont *f, NSColor *c) {
    NSTextField *t = [NSTextField labelWithString:s ?: @""];
    t.font = f; t.textColor = c; t.drawsBackground = NO; t.bezeled = NO; t.editable = NO; t.selectable = NO;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    return t;
}

// Paths as the user's notes are named: "Folder/Note" without the extension.
static NSString *Pretty(NSString *rel) {
    NSString *ext = rel.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"md"]) return [rel stringByDeletingPathExtension];
    return rel;
}

#pragma mark - Custom text attributes

static NSString *const QLinkAttr      = @"QLink";       // wikilink target
static NSString *const QURLAttr       = @"QURL";        // web address
static NSString *const QTagAttr       = @"QTag";        // #tag
static NSString *const QTaskAttr      = @"QTask";       // NSNumber 0/1 on the "[ ]" characters
static NSString *const QBulletAttr    = @"QBullet";     // on a "-", "*" or "+" list marker
static NSString *const QHRAttr        = @"QHR";         // horizontal rule line
static NSString *const QQuoteAttr     = @"QQuote";      // block quote line
static NSString *const QCodeBlockAttr = @"QCodeBlock";  // fenced code block line
static NSString *const QHeadingAttr   = @"QHeading";    // heading level on a heading line

#pragma mark - Interfaces

@class QApp, QEditor, QSidebar, QCanvasView, QTextView;
static QApp *gApp;

@interface QNode : NSObject
@property (copy) NSString *name, *path, *rel, *ext;
@property BOOL isDir;
@property (strong) NSMutableArray<QNode *> *children;
@property (weak) QNode *parent;
@property (strong) NSDate *mtime, *ctime;
@end

typedef NS_ENUM(NSInteger, QSort) { QSortNameAZ, QSortNameZA, QSortModNew, QSortModOld, QSortCreNew, QSortCreOld };

@interface QVault : NSObject
@property (copy) NSString *root;
@property (strong) QNode *tree;
@property (strong) NSArray<QNode *> *notes;      // every .md and .canvas file
@property (strong) NSDictionary<NSString *, QNode *> *byPath;
- (instancetype)initWithRoot:(NSString *)root;
- (void)rescan;
- (QNode *)nodeForPath:(NSString *)path;
- (NSString *)rel:(NSString *)path;
- (QNode *)resolve:(NSString *)target;
- (NSString *)name;
@end

@interface QWatcher : NSObject
- (instancetype)initWithPath:(NSString *)path handler:(void (^)(NSArray<NSString *> *paths, NSArray<NSNumber *> *flags))h;
- (void)stop;
@end

@interface QIndex : NSObject
+ (NSString *)textOf:(QNode *)n;
+ (void)forget:(NSString *)path;
+ (NSArray<NSString *> *)tagsIn:(NSString *)text;
@end

@interface QHeading : NSObject
@property NSRange line;        // heading line without its newline
@property NSInteger level;
@property (copy) NSString *key;
@property NSRange hide;        // characters hidden when folded (may be empty)
@end

@interface QTextView : NSTextView
@property (weak) QEditor *editor;
@property CGFloat pageWidth;
@property NSInteger hoverHeading;
@property (strong) NSTextField *titleField;
- (NSRect)pageRect;
- (void)updateGeometry;
@end

@interface QIconButton : NSButton
@property (nonatomic) BOOL active;
+ (instancetype)symbol:(NSString *)sym size:(CGFloat)pt tip:(NSString *)tip target:(id)t action:(SEL)a;
@end

@interface QDragBar : NSView
@end

@interface QCanvasView : NSView <NSTextViewDelegate>
@property (copy) NSString *path;
@property (readonly) NSUInteger cardCount;
- (BOOL)loadPath:(NSString *)path;
- (void)saveNow;
- (void)zoomToFit;
- (void)reloadIfChanged;
@end

@interface QEditor : NSObject <NSTextStorageDelegate, NSTextViewDelegate, NSLayoutManagerDelegate, NSTextFieldDelegate>
@property (strong) NSView *view;
@property (strong) QTextView *textView;
@property (strong) NSScrollView *scroll;
@property (strong) QCanvasView *canvas;
@property (strong) QDragBar *topBar;
@property (strong) NSTextField *crumb, *status;
@property (strong) QIconButton *backButton, *forwardButton;
@property (strong) NSView *emptyView;
@property (copy) NSString *path;
@property (strong) NSArray<QHeading *> *headings;
@property (strong) NSArray<NSValue *> *hidden;
@property (strong) NSMutableSet<NSString *> *folded;
@property BOOL dirty;
- (void)openPath:(NSString *)path;
- (void)openPath:(NSString *)path history:(BOOL)h;
- (void)saveNow;
- (void)closeNote;
- (void)openLink:(NSString *)target;
- (void)openURL:(NSString *)url;
- (void)searchTag:(NSString *)tag;
- (void)toggleTaskAt:(NSRange)r;
- (void)toggleFoldAtHeading:(NSInteger)i;
- (void)foldAll:(BOOL)fold;
- (void)foldHere:(BOOL)fold;
- (void)selectQuery:(NSString *)query;
- (void)goBack;
- (void)goForward;
- (void)applySettings;
- (void)pathMoved:(NSString *)from to:(NSString *)to;
- (void)fileChanged:(NSString *)path;
- (void)layoutForSidebarHidden:(BOOL)hidden;
- (void)focusTitle;
- (void)rememberCaret;
- (BOOL)isHiddenChar:(NSUInteger)ci;
@end

@interface QSidebar : NSView <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTableViewDataSource, NSTableViewDelegate,
                              NSTextFieldDelegate, NSSearchFieldDelegate, NSMenuDelegate>
- (void)reload;
- (void)revealPath:(NSString *)path;
- (void)showSearch:(NSString *)query;
- (void)showFiles;
- (void)newNote;
- (void)newFolder;
- (void)refreshFooter;
@end

@interface QSwitcher : NSPanel <NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate>
+ (void)show;
@end

@interface QSettings : NSWindowController <NSTextFieldDelegate>
+ (void)show;
@end

@interface QSplit : NSSplitView
@end

@interface QApp : NSObject <NSApplicationDelegate, NSWindowDelegate, NSSplitViewDelegate>
@property (strong) NSWindow *window;
@property (strong) QVault *vault;
@property (strong) QEditor *editor;
@property (strong) QSidebar *sidebar;
@property (strong) QSplit *split;
@property (strong) QWatcher *watcher;
@property BOOL sidebarHidden;
- (void)openVault:(NSString *)path;
- (void)chooseVault;
- (void)rescanSoon;
- (void)rescanNow;
- (NSString *)createNoteIn:(NSString *)dir name:(NSString *)name;
- (NSString *)defaultNoteDir;
- (void)toggleSidebar:(id)sender;
- (void)openPeriodic:(NSString *)formatKey;
@end

#pragma mark - Vault

@implementation QNode
@end

@implementation QHeading
@end

static void SortChildren(QNode *n, QSort s) {
    [n.children sortUsingComparator:^NSComparisonResult(QNode *a, QNode *b) {
        if (a.isDir != b.isDir) return a.isDir ? NSOrderedAscending : NSOrderedDescending;
        if (a.isDir || s == QSortNameAZ) return [a.name localizedStandardCompare:b.name];
        if (s == QSortNameZA) return [b.name localizedStandardCompare:a.name];
        BOOL byMod = (s == QSortModNew || s == QSortModOld);
        NSDate *da = byMod ? a.mtime : a.ctime, *db = byMod ? b.mtime : b.ctime;
        NSComparisonResult r = (da && db) ? [da compare:db] : NSOrderedSame;
        if (s == QSortModNew || s == QSortCreNew) r = (NSComparisonResult)(-r);
        return r != NSOrderedSame ? r : [a.name localizedStandardCompare:b.name];
    }];
    for (QNode *c in n.children) if (c.isDir) SortChildren(c, s);
}

@implementation QVault

- (instancetype)initWithRoot:(NSString *)root {
    if ((self = [super init])) { _root = root.stringByStandardizingPath; [self rescan]; }
    return self;
}

- (NSString *)name { return self.root.lastPathComponent; }

- (NSString *)rel:(NSString *)path {
    NSString *r = self.root;
    if ([path isEqualToString:r]) return @"";
    if ([path hasPrefix:[r stringByAppendingString:@"/"]]) return [path substringFromIndex:r.length + 1];
    return path;
}

- (void)scan:(QNode *)dir into:(NSMutableArray *)notes map:(NSMutableDictionary *)map {
    NSArray *keys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLCreationDateKey, NSURLIsPackageKey];
    NSArray<NSURL *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtURL:[NSURL fileURLWithPath:dir.path]
                                    includingPropertiesForKeys:keys options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    for (NSURL *u in items) {
        NSDictionary *v = [u resourceValuesForKeys:keys error:nil];
        BOOL isDir = [v[NSURLIsDirectoryKey] boolValue] && ![v[NSURLIsPackageKey] boolValue];
        NSString *ext = u.pathExtension.lowercaseString;
        if (!isDir && ![ext isEqualToString:@"md"] && ![ext isEqualToString:@"canvas"]) continue;
        QNode *n = [QNode new];
        n.path = u.path.stringByStandardizingPath;
        n.rel = [self rel:n.path];
        n.isDir = isDir;
        n.ext = isDir ? @"" : ext;
        n.name = isDir ? u.lastPathComponent : u.lastPathComponent.stringByDeletingPathExtension;
        n.mtime = v[NSURLContentModificationDateKey];
        n.ctime = v[NSURLCreationDateKey];
        n.parent = dir;
        n.children = [NSMutableArray array];
        [dir.children addObject:n];
        map[n.path] = n;
        if (isDir) [self scan:n into:notes map:map];
        else [notes addObject:n];
    }
}

- (void)rescan {
    QNode *t = [QNode new];
    t.path = self.root; t.rel = @""; t.isDir = YES; t.name = self.name; t.ext = @"";
    t.children = [NSMutableArray array];
    NSMutableArray *notes = [NSMutableArray array];
    NSMutableDictionary *map = [NSMutableDictionary dictionary];
    map[t.path] = t;
    [self scan:t into:notes map:map];
    SortChildren(t, (QSort)[Defaults() integerForKey:kSortMode]);
    self.tree = t;
    self.notes = notes;
    self.byPath = map;
}

- (QNode *)nodeForPath:(NSString *)path {
    return path ? self.byPath[path.stringByStandardizingPath] : nil;
}

// Wikilink target -> note. Accepts "Note", "Folder/Note", "Note.md", "Note#Heading", "Note|Alias".
- (QNode *)resolve:(NSString *)target {
    NSString *t = target;
    NSRange cut = [t rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"|#^"]];
    if (cut.location != NSNotFound) t = [t substringToIndex:cut.location];
    t = Trim(t);
    if (!t.length) return nil;
    t = t.stringByRemovingPercentEncoding ?: t;
    NSString *lower = t.lowercaseString;
    BOOL hasExt = [lower hasSuffix:@".md"] || [lower hasSuffix:@".canvas"];
    QNode *best = nil;
    for (QNode *n in self.notes) {
        NSString *rel = n.rel.lowercaseString;
        NSString *relNoExt = [n.ext isEqualToString:@"md"] ? rel.stringByDeletingPathExtension : rel;
        NSString *cmp = hasExt ? rel : relNoExt;
        if ([cmp isEqualToString:lower]) return n;
        NSString *base = hasExt ? n.path.lastPathComponent.lowercaseString : ([n.ext isEqualToString:@"md"] ? n.name.lowercaseString : n.path.lastPathComponent.lowercaseString);
        if ([base isEqualToString:lower.lastPathComponent] && (!best || n.rel.length < best.rel.length)) best = n;
    }
    return best;
}

@end

#pragma mark - File watching

@interface QWatcher () {
    FSEventStreamRef _stream;
}
@property (copy) void (^handler)(NSArray<NSString *> *, NSArray<NSNumber *> *);
@end

static void QFSCallback(ConstFSEventStreamRef stream, void *info, size_t count, void *paths,
                        const FSEventStreamEventFlags *flags, const FSEventStreamEventId *ids) {
    QWatcher *w = (__bridge QWatcher *)info;
    NSArray *ps = (__bridge NSArray *)paths;
    NSMutableArray *fl = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) [fl addObject:@(flags[i])];
    if (w.handler) w.handler(ps, fl);
}

@implementation QWatcher
- (instancetype)initWithPath:(NSString *)path handler:(void (^)(NSArray<NSString *> *, NSArray<NSNumber *> *))h {
    if ((self = [super init])) {
        _handler = [h copy];
        FSEventStreamContext ctx = {0, (__bridge void *)self, NULL, NULL, NULL};
        _stream = FSEventStreamCreate(NULL, &QFSCallback, &ctx, (__bridge CFArrayRef)@[path], kFSEventStreamEventIdSinceNow, 0.25,
                                      kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer);
        if (_stream) {
            FSEventStreamSetDispatchQueue(_stream, dispatch_get_main_queue());
            FSEventStreamStart(_stream);
        }
    }
    return self;
}
- (void)stop {
    if (!_stream) return;
    FSEventStreamStop(_stream);
    FSEventStreamInvalidate(_stream);
    FSEventStreamRelease(_stream);
    _stream = NULL;
}
- (void)dealloc { [self stop]; }
@end

#pragma mark - Text cache for search and tags

static NSMutableDictionary *gTextCache;   // path -> @[mtime, text]

@implementation QIndex
+ (NSString *)textOf:(QNode *)n {
    if (!n || n.isDir) return @"";
    @synchronized (gTextCache) {
        NSArray *hit = gTextCache[n.path];
        if (hit && n.mtime && [hit[0] isEqual:n.mtime]) return hit[1];
    }
    NSString *s = ReadText(n.path) ?: @"";
    if ([n.ext isEqualToString:@"canvas"]) {
        // Search a canvas by the text on its cards.
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data] options:0 error:nil];
        NSMutableArray *bits = [NSMutableArray array];
        if ([j isKindOfClass:NSDictionary.class])
            for (NSDictionary *node in j[@"nodes"])
                if ([node isKindOfClass:NSDictionary.class] && [node[@"text"] isKindOfClass:NSString.class]) [bits addObject:node[@"text"]];
        s = [bits componentsJoinedByString:@"\n"];
    }
    @synchronized (gTextCache) { gTextCache[n.path] = @[n.mtime ?: [NSDate date], s]; }
    return s;
}
+ (void)forget:(NSString *)path { @synchronized (gTextCache) { [gTextCache removeObjectForKey:path]; } }

+ (NSArray<NSString *> *)tagsIn:(NSString *)text {
    static NSRegularExpression *tagRx, *fmRx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        tagRx = RX(@"(?<![\\w/&#\\]\\)])#([\\p{L}_][\\p{L}\\p{N}_/-]*)", 0);
        fmRx = RX(@"\\A---\\n([\\s\\S]*?)\\n---", 0);
    });
    NSMutableOrderedSet *out = [NSMutableOrderedSet orderedSet];
    // Front matter: tags: [a, b]  or  tags:\n  - a
    NSTextCheckingResult *fm = [fmRx firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    NSUInteger bodyStart = 0;
    if (fm) {
        bodyStart = NSMaxRange(fm.range);
        NSString *yaml = [text substringWithRange:[fm rangeAtIndex:1]];
        BOOL inTags = NO;
        for (NSString *line in [yaml componentsSeparatedByString:@"\n"]) {
            NSString *t = Trim(line);
            if ([t hasPrefix:@"tags:"] || [t hasPrefix:@"tag:"]) {
                NSString *rest = Trim([t substringFromIndex:[t rangeOfString:@":"].location + 1]);
                rest = [[rest stringByReplacingOccurrencesOfString:@"[" withString:@""] stringByReplacingOccurrencesOfString:@"]" withString:@""];
                for (NSString *p in [rest componentsSeparatedByString:@","]) {
                    NSString *v = [Trim(p) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"#\"' "]];
                    if (v.length) [out addObject:v];
                }
                inTags = rest.length == 0;
            } else if (inTags && [t hasPrefix:@"- "]) {
                NSString *v = [Trim([t substringFromIndex:2]) stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"#\"' "]];
                if (v.length) [out addObject:v];
            } else if (t.length) inTags = NO;
        }
    }
    // Inline tags, skipping fenced code.
    __block BOOL inCode = NO;
    NSString *body = [text substringFromIndex:bodyStart];
    [body enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([t hasPrefix:@"```"] || [t hasPrefix:@"~~~"]) { inCode = !inCode; return; }
        if (inCode) return;
        for (NSTextCheckingResult *m in [tagRx matchesInString:line options:0 range:NSMakeRange(0, line.length)]) {
            NSString *tag = [line substringWithRange:[m rangeAtIndex:1]];
            BOOL hasLetter = [tag rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location != NSNotFound;
            if (hasLetter) [out addObject:tag];
        }
    }];
    return out.array;
}
@end

#pragma mark - Small views

@interface QIconButton ()
@property BOOL hover;
@end

@implementation QIconButton
+ (instancetype)symbol:(NSString *)sym size:(CGFloat)pt tip:(NSString *)tip target:(id)t action:(SEL)a {
    QIconButton *b = [[QIconButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 26)];
    b.bordered = NO;
    [b setButtonType:NSButtonTypeMomentaryChange];
    b.imagePosition = NSImageOnly;
    NSImage *im = Symbol(sym, pt, NSFontWeightRegular);
    if (im) b.image = im; else b.title = tip.length ? [tip substringToIndex:1] : @"?";
    b.contentTintColor = qMuted;
    b.toolTip = tip;
    b.target = t; b.action = a;
    b.focusRingType = NSFocusRingTypeNone;
    return b;
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *ta in self.trackingAreas.copy) [self removeTrackingArea:ta];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { self.hover = YES; [self refreshTint]; }
- (void)mouseExited:(NSEvent *)e { self.hover = NO; [self refreshTint]; }
- (void)setActive:(BOOL)active { _active = active; [self refreshTint]; }
- (void)refreshTint { self.contentTintColor = (self.active || self.hover) ? qText : qMuted; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)r {
    if (self.active) RoundRect(NSInsetRect(self.bounds, 1, 1), 6, qSideActive);
    else if (self.hover) RoundRect(NSInsetRect(self.bounds, 1, 1), 6, qSideHover);
    [super drawRect:r];
}
@end

@implementation QDragBar
- (BOOL)mouseDownCanMoveWindow { return YES; }
- (BOOL)isFlipped { return YES; }
- (void)mouseUp:(NSEvent *)e {
    if (e.clickCount == 2) [self.window performZoom:nil];   // standard title bar double-click
    else [super mouseUp:e];
}
- (void)drawRect:(NSRect)r { [qDesk setFill]; NSRectFill(r); }
@end

@interface QFlip : NSView
@end
@implementation QFlip
- (BOOL)isFlipped { return YES; }
@end

@implementation QSplit
- (NSColor *)dividerColor { return Hex(0x1a1a1a); }
- (CGFloat)dividerThickness { return 1; }
@end

#pragma mark - Markdown: structure

static NSRange FrontMatter(NSString *s) {
    if (![s hasPrefix:@"---\n"] && ![s hasPrefix:@"---\r\n"]) return NSMakeRange(NSNotFound, 0);
    NSUInteger pos = NSMaxRange([s lineRangeForRange:NSMakeRange(0, 0)]);
    while (pos < s.length) {
        NSRange lr = [s lineRangeForRange:NSMakeRange(pos, 0)];
        NSString *t = Trim([s substringWithRange:lr]);
        if ([t isEqualToString:@"---"] || [t isEqualToString:@"..."]) return NSMakeRange(0, NSMaxRange(lr));
        if (NSMaxRange(lr) <= pos) break;
        pos = NSMaxRange(lr);
    }
    return NSMakeRange(NSNotFound, 0);
}

static BOOL IsFence(NSString *s, NSRange lr) {
    NSUInteger i = lr.location, end = NSMaxRange(lr), sp = 0;
    while (i < end && [s characterAtIndex:i] == ' ' && sp < 4) { i++; sp++; }
    if (sp > 3 || i + 3 > end) return NO;
    unichar c = [s characterAtIndex:i];
    if (c != '`' && c != '~') return NO;
    return [s characterAtIndex:i + 1] == c && [s characterAtIndex:i + 2] == c;
}

// Fenced code blocks, each from its opening fence line to the end of its closing fence line.
static NSArray<NSValue *> *CodeBlocks(NSString *s, NSRange front) {
    NSMutableArray *out = [NSMutableArray array];
    NSUInteger len = s.length, pos = (front.location == NSNotFound) ? 0 : NSMaxRange(front), open = NSNotFound;
    while (pos < len) {
        NSRange lr = [s lineRangeForRange:NSMakeRange(pos, 0)];
        if (lr.length == 0) break;
        if (IsFence(s, lr)) {
            if (open == NSNotFound) open = lr.location;
            else { [out addObject:[NSValue valueWithRange:NSMakeRange(open, NSMaxRange(lr) - open)]]; open = NSNotFound; }
        }
        pos = NSMaxRange(lr);
    }
    if (open != NSNotFound) [out addObject:[NSValue valueWithRange:NSMakeRange(open, len - open)]];
    return out;
}

static NSArray<QHeading *> *Headings(NSString *s, NSArray<NSValue *> *blocks, NSRange front) {
    NSMutableArray<QHeading *> *out = [NSMutableArray array];
    NSMutableArray<QHeading *> *stack = [NSMutableArray array];
    NSUInteger len = s.length, pos = (front.location == NSNotFound) ? 0 : NSMaxRange(front), bi = 0;
    while (pos < len) {
        NSUInteger start = 0, end = 0, cend = 0;
        [s getLineStart:&start end:&end contentsEnd:&cend forRange:NSMakeRange(pos, 0)];
        while (bi < blocks.count && NSMaxRange(blocks[bi].rangeValue) <= start) bi++;
        BOOL inCode = bi < blocks.count && NSLocationInRange(start, blocks[bi].rangeValue);
        if (!inCode && cend > start && [s characterAtIndex:start] == '#') {
            NSUInteger n = 0;
            while (start + n < cend && n < 7 && [s characterAtIndex:start + n] == '#') n++;
            if (n <= 6 && (start + n == cend || [s characterAtIndex:start + n] == ' ' || [s characterAtIndex:start + n] == '\t')) {
                QHeading *h = [QHeading new];
                h.line = NSMakeRange(start, cend - start);
                h.level = (NSInteger)n;
                while (stack.count && stack.lastObject.level >= h.level) [stack removeLastObject];
                NSString *text = Trim([s substringWithRange:NSMakeRange(start + n, cend - start - n)]);
                h.key = [NSString stringWithFormat:@"%@/%lu:%@", stack.count ? stack.lastObject.key : @"", (unsigned long)n, text];
                [stack addObject:h];
                [out addObject:h];
            }
        }
        if (end <= pos) break;
        pos = end;
    }
    for (NSUInteger i = 0; i < out.count; i++) {
        QHeading *h = out[i];
        NSUInteger stop = len;
        for (NSUInteger j = i + 1; j < out.count; j++) if (out[j].level <= h.level) { stop = out[j].line.location; break; }
        NSUInteger from = NSMaxRange(h.line);
        NSUInteger to = (stop < len) ? stop - 1 : len;   // keep the newline that ends the folded block
        h.hide = (to > from) ? NSMakeRange(from, to - from) : NSMakeRange(from, 0);
    }
    return out;
}

static NSUInteger WordCount(NSString *s) {
    __block NSUInteger n = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                          options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                       usingBlock:^(NSString *w, NSRange r, NSRange er, BOOL *stop) { n++; }];
    return n;
}

#pragma mark - Markdown: styling

static NSMutableDictionary *gParaCache;

static NSParagraphStyle *Para(NSString *kind, CGFloat indent, NSInteger level) {
    NSString *key = [NSString stringWithFormat:@"%@-%.1f-%ld-%.1f", kind, indent, (long)level, gBase];
    NSParagraphStyle *p = gParaCache[key];
    if (p) return p;
    NSMutableParagraphStyle *m = [NSMutableParagraphStyle new];
    m.lineSpacing = round(gBase * 0.48);
    m.paragraphSpacing = round(gBase * 0.18);
    if ([kind isEqualToString:@"h"]) {
        m.lineSpacing = round(gBase * 0.2);
        m.paragraphSpacingBefore = round(gBase * (level <= 2 ? 1.0 : 0.6));
        m.paragraphSpacing = round(gBase * 0.3);
    } else if ([kind isEqualToString:@"code"]) {
        m.lineSpacing = round(gBase * 0.24);
        m.paragraphSpacing = 0;
        m.firstLineHeadIndent = 16; m.headIndent = 16; m.tailIndent = -16;
    } else if ([kind isEqualToString:@"tight"]) {
        m.lineSpacing = round(gBase * 0.2);
        m.paragraphSpacing = 0;
    } else if ([kind isEqualToString:@"indent"] || [kind isEqualToString:@"quote"]) {
        m.headIndent = indent;
        m.firstLineHeadIndent = 0;
        m.paragraphSpacing = round(gBase * 0.12);
    }
    gParaCache[key] = m;
    return m;
}

static CGFloat HeadingSize(NSInteger level) {
    switch (level) {
        case 1: return round(gBase * 1.76);
        case 2: return round(gBase * 1.38);
        case 3: return round(gBase * 1.18);
        case 4: return round(gBase * 1.06);
        default: return gBase;
    }
}

static NSRegularExpression *rxHeading, *rxHR, *rxQuote, *rxList, *rxCode, *rxWiki, *rxMdLink, *rxURL,
                           *rxBold, *rxItalicStar, *rxItalicUnd, *rxStrike, *rxHigh, *rxTag;

static void InitRegexes(void) {
    rxHeading    = RX(@"^(#{1,6})(?:[ \\t]+|$)", 0);
    rxHR         = RX(@"^ {0,3}([-*_])(?:[ \\t]*\\1){2,}[ \\t]*$", 0);
    rxQuote      = RX(@"^(?: {0,3}>[ \\t]?)+", 0);
    rxList       = RX(@"^([ \\t]*)([-*+]|\\d{1,9}[.)])([ \\t]+|$)(\\[([ xX])\\](?:[ \\t]+|$))?", 0);
    rxCode       = RX(@"(`+)([^`\\n]+?)\\1", 0);
    rxWiki       = RX(@"(!?)\\[\\[([^\\[\\]\\n]+?)\\]\\]", 0);
    rxMdLink     = RX(@"(!?)\\[([^\\]\\n]*)\\]\\(([^)\\s]+)(?:\\s+\"[^\"]*\")?\\)", 0);
    rxURL        = RX(@"(?<![(<\\[\\w])https?://[^\\s<>)\\]]+", 0);
    rxBold       = RX(@"(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1", 0);
    rxItalicStar = RX(@"(?<![*\\w\\\\])\\*(?=[^\\s*])(.+?)(?<=[^\\s*\\\\])\\*(?![*\\w])", 0);
    rxItalicUnd  = RX(@"(?<![_\\w\\\\])_(?=[^\\s_])(.+?)(?<=[^\\s_\\\\])_(?![_\\w])", 0);
    rxStrike     = RX(@"~~(?=\\S)(.+?)(?<=\\S)~~", 0);
    rxHigh       = RX(@"==(?=\\S)(.+?)(?<=\\S)==", 0);
    rxTag        = RX(@"(?<![\\w/&#\\])])#([\\p{L}_][\\p{L}\\p{N}_/-]*)", 0);
}

static void Faint(NSTextStorage *ts, NSRange r) {
    if (r.length) [ts addAttribute:NSForegroundColorAttributeName value:qMark range:r];
}
static void LinkStyle(NSTextStorage *ts, NSRange r) {
    [ts addAttributes:@{NSForegroundColorAttributeName: qLink,
                        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
                        NSUnderlineColorAttributeName: qLinkLine} range:r];
}
static void AddTrait(NSTextStorage *ts, NSRange r, NSFontTraitMask t) {
    [ts enumerateAttribute:NSFontAttributeName inRange:r options:0 usingBlock:^(NSFont *f, NSRange sub, BOOL *stop) {
        if (f) [ts addAttribute:NSFontAttributeName value:[NSFontManager.sharedFontManager convertFont:f toHaveTrait:t] range:sub];
    }];
}

static void StyleInline(NSTextStorage *ts, NSString *line, NSUInteger o, NSUInteger from, CGFloat size) {
    if (from >= line.length) return;
    NSRange r = NSMakeRange(from, line.length - from);
    NSMutableIndexSet *taken = [NSMutableIndexSet indexSet];
    BOOL (^isFree)(NSRange) = ^BOOL(NSRange x) { return ![taken intersectsIndexesInRange:x]; };
    NSRange (^at)(NSRange) = ^NSRange(NSRange x) { return NSMakeRange(o + x.location, x.length); };

    for (NSTextCheckingResult *m in [rxCode matchesInString:line options:0 range:r]) {
        NSRange all = m.range, tick = [m rangeAtIndex:1], inner = [m rangeAtIndex:2];
        [ts addAttributes:@{NSFontAttributeName: Mono(round(size * 0.84)), NSForegroundColorAttributeName: qCode,
                            NSBackgroundColorAttributeName: qInlineCodeBg} range:at(inner)];
        Faint(ts, at(NSMakeRange(all.location, tick.length)));
        Faint(ts, at(NSMakeRange(NSMaxRange(all) - tick.length, tick.length)));
        [taken addIndexesInRange:all];
    }
    for (NSTextCheckingResult *m in [rxWiki matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        NSRange all = m.range, inner = [m rangeAtIndex:2];
        NSString *body = [line substringWithRange:inner];
        NSRange bar = [body rangeOfString:@"|"];
        NSString *target = bar.location == NSNotFound ? body : [body substringToIndex:bar.location];
        Faint(ts, at(NSMakeRange(all.location, inner.location - all.location)));
        Faint(ts, at(NSMakeRange(NSMaxRange(inner), NSMaxRange(all) - NSMaxRange(inner))));
        NSRange shown = inner;
        if (bar.location != NSNotFound) {
            Faint(ts, at(NSMakeRange(inner.location, bar.location + 1)));
            shown = NSMakeRange(inner.location + bar.location + 1, inner.length - bar.location - 1);
        }
        if (shown.length) {
            LinkStyle(ts, at(shown));
            [ts addAttribute:QLinkAttr value:target range:at(shown)];
        }
        [taken addIndexesInRange:all];
    }
    for (NSTextCheckingResult *m in [rxMdLink matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        NSRange all = m.range, text = [m rangeAtIndex:2], url = [m rangeAtIndex:3];
        NSString *u = [line substringWithRange:url];
        Faint(ts, at(NSMakeRange(all.location, text.location - all.location)));
        Faint(ts, at(NSMakeRange(NSMaxRange(text), NSMaxRange(all) - NSMaxRange(text))));
        if (text.length) {
            LinkStyle(ts, at(text));
            BOOL web = [u containsString:@"://"] || [u hasPrefix:@"mailto:"];
            [ts addAttribute:(web ? QURLAttr : QLinkAttr) value:(web ? u : (u.stringByRemovingPercentEncoding ?: u)) range:at(text)];
        }
        [taken addIndexesInRange:all];
    }
    for (NSTextCheckingResult *m in [rxURL matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        LinkStyle(ts, at(m.range));
        [ts addAttribute:QURLAttr value:[line substringWithRange:m.range] range:at(m.range)];
        [taken addIndexesInRange:m.range];
    }
    for (NSTextCheckingResult *m in [rxBold matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        NSRange mk = [m rangeAtIndex:1], inner = [m rangeAtIndex:2];
        AddTrait(ts, at(inner), NSBoldFontMask);
        Faint(ts, at(NSMakeRange(m.range.location, mk.length)));
        Faint(ts, at(NSMakeRange(NSMaxRange(m.range) - mk.length, mk.length)));
    }
    for (NSRegularExpression *rx in @[rxItalicStar, rxItalicUnd]) {
        for (NSTextCheckingResult *m in [rx matchesInString:line options:0 range:r]) {
            if (!isFree(m.range)) continue;
            AddTrait(ts, at([m rangeAtIndex:1]), NSItalicFontMask);
            Faint(ts, at(NSMakeRange(m.range.location, 1)));
            Faint(ts, at(NSMakeRange(NSMaxRange(m.range) - 1, 1)));
        }
    }
    for (NSTextCheckingResult *m in [rxStrike matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        [ts addAttributes:@{NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle), NSStrikethroughColorAttributeName: qMuted,
                            NSForegroundColorAttributeName: qBody2} range:at([m rangeAtIndex:1])];
        Faint(ts, at(NSMakeRange(m.range.location, 2)));
        Faint(ts, at(NSMakeRange(NSMaxRange(m.range) - 2, 2)));
    }
    for (NSTextCheckingResult *m in [rxHigh matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        [ts addAttribute:NSBackgroundColorAttributeName value:qHighlight range:at([m rangeAtIndex:1])];
        Faint(ts, at(NSMakeRange(m.range.location, 2)));
        Faint(ts, at(NSMakeRange(NSMaxRange(m.range) - 2, 2)));
    }
    for (NSTextCheckingResult *m in [rxTag matchesInString:line options:0 range:r]) {
        if (!isFree(m.range)) continue;
        NSString *tag = [line substringWithRange:[m rangeAtIndex:1]];
        if ([tag rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) continue;
        [ts addAttributes:@{NSForegroundColorAttributeName: qTag, QTagAttr: tag} range:at(m.range)];
    }
}

static void StyleLine(NSTextStorage *ts, NSString *s, NSRange lr, NSRange cr, NSArray<NSValue *> *blocks, NSRange front) {
    [ts setAttributes:@{NSFontAttributeName: Serif(gBase, NO, NO), NSForegroundColorAttributeName: qText,
                        NSParagraphStyleAttributeName: Para(@"body", 0, 0)} range:lr];
    if (front.location != NSNotFound && NSLocationInRange(lr.location, front)) {
        [ts addAttributes:@{NSFontAttributeName: Mono(round(gBase * 0.76)), NSForegroundColorAttributeName: qMuted,
                            NSParagraphStyleAttributeName: Para(@"tight", 0, 0)} range:lr];
        return;
    }
    for (NSValue *v in blocks) {
        NSRange b = v.rangeValue;
        if (NSLocationInRange(lr.location, b)) {
            BOOL fence = IsFence(s, lr);
            [ts addAttributes:@{NSFontAttributeName: Mono(round(gBase * 0.8)), NSForegroundColorAttributeName: fence ? qFaint : qCode,
                                NSParagraphStyleAttributeName: Para(@"code", 0, 0), QCodeBlockAttr: @YES} range:lr];
            return;
        }
        if (b.location > lr.location) break;
    }
    NSString *line = [s substringWithRange:cr];
    NSRange whole = NSMakeRange(0, line.length);
    NSUInteger o = cr.location;

    NSTextCheckingResult *m = [rxHeading firstMatchInString:line options:0 range:whole];
    if (m) {
        NSInteger level = (NSInteger)[m rangeAtIndex:1].length;
        CGFloat size = HeadingSize(level);
        [ts addAttributes:@{NSFontAttributeName: Serif(size, YES, NO), NSForegroundColorAttributeName: level >= 6 ? qBody2 : qHead,
                            NSParagraphStyleAttributeName: Para(@"h", 0, level), QHeadingAttr: @(level)} range:lr];
        Faint(ts, NSMakeRange(o, m.range.length));
        StyleInline(ts, line, o, m.range.length, size);
        return;
    }
    if (line.length && [rxHR firstMatchInString:line options:0 range:whole]) {
        [ts addAttributes:@{NSForegroundColorAttributeName: NSColor.clearColor, QHRAttr: @YES} range:cr];
        return;
    }
    m = [rxQuote firstMatchInString:line options:0 range:whole];
    if (m) {
        NSString *prefix = [line substringToIndex:m.range.length];
        CGFloat w = [prefix sizeWithAttributes:@{NSFontAttributeName: Serif(gBase, NO, NO)}].width;
        [ts addAttributes:@{NSFontAttributeName: Serif(gBase, NO, YES), NSForegroundColorAttributeName: qBody2,
                            NSParagraphStyleAttributeName: Para(@"quote", round(w), 0), QQuoteAttr: @YES} range:lr];
        [ts addAttribute:NSForegroundColorAttributeName value:NSColor.clearColor range:NSMakeRange(o, m.range.length)];
        StyleInline(ts, line, o, m.range.length, gBase);
        return;
    }
    NSUInteger from = 0;
    m = [rxList firstMatchInString:line options:0 range:whole];
    if (m) {
        NSRange mk = [m rangeAtIndex:2], task = [m rangeAtIndex:4], tick = [m rangeAtIndex:5];
        NSString *prefix = [line substringToIndex:m.range.length];
        CGFloat w = [prefix sizeWithAttributes:@{NSFontAttributeName: Serif(gBase, NO, NO)}].width;
        [ts addAttribute:NSParagraphStyleAttributeName value:Para(@"indent", round(w), 0) range:lr];
        NSString *marker = [line substringWithRange:mk];
        BOOL isTask = task.location != NSNotFound;
        // A task shows only its box; a plain item shows a bullet in place of "-", "*" or "+".
        [ts addAttribute:NSForegroundColorAttributeName value:(isTask && marker.length == 1 ? NSColor.clearColor : qMuted)
                   range:NSMakeRange(o + mk.location, mk.length)];
        if (!isTask && marker.length == 1 && [@"-*+" containsString:marker])
            [ts addAttribute:QBulletAttr value:@YES range:NSMakeRange(o + mk.location, 1)];
        if (task.location != NSNotFound) {
            BOOL done = ![[line substringWithRange:tick] isEqualToString:@" "];
            [ts addAttributes:@{NSForegroundColorAttributeName: NSColor.clearColor, QTaskAttr: @(done)}
                        range:NSMakeRange(o + task.location, 3)];
            if (done && cr.length > m.range.length)
                [ts addAttributes:@{NSForegroundColorAttributeName: qMuted, NSStrikethroughStyleAttributeName: @(NSUnderlineStyleSingle),
                                    NSStrikethroughColorAttributeName: qFaint}
                            range:NSMakeRange(o + m.range.length, cr.length - m.range.length)];
        }
        from = m.range.length;
    }
    StyleInline(ts, line, o, from, gBase);
}

// Styles every line touched by `range`.
static void StyleRange(NSTextStorage *ts, NSRange range, NSArray<NSValue *> *blocks, NSRange front) {
    NSString *s = ts.string;
    NSUInteger len = s.length;
    if (!len) return;
    if (range.location > len) range.location = len;
    if (NSMaxRange(range) > len) range.length = len - range.location;
    NSRange para = [s lineRangeForRange:range];
    NSUInteger pos = para.location;
    while (pos < NSMaxRange(para)) {
        NSUInteger start = 0, end = 0, cend = 0;
        [s getLineStart:&start end:&end contentsEnd:&cend forRange:NSMakeRange(pos, 0)];
        StyleLine(ts, s, NSMakeRange(start, end - start), NSMakeRange(start, cend - start), blocks, front);
        if (end <= pos) break;
        pos = end;
    }
}

#pragma mark - The page

static const CGFloat kTopPad = 54, kTitleH = 50, kTitleGap = 14, kPagePad = 60, kDotStep = 20;

@implementation QTextView

- (BOOL)isOpaque { return YES; }

- (CGFloat)insetX { return MAX(kPagePad + 24, floor((NSWidth(self.bounds) - self.pageWidth) / 2)); }

- (NSPoint)textContainerOrigin { return NSMakePoint(self.insetX, kTopPad + kTitleH + kTitleGap); }

- (void)setFrameSize:(NSSize)s {
    [super setFrameSize:s];
    [self updateGeometry];
}

- (void)updateGeometry {
    CGFloat ix = self.insetX;
    NSSize inset = NSMakeSize(ix, 150);
    if (!NSEqualSizes(inset, self.textContainerInset)) self.textContainerInset = inset;
    CGFloat w = MAX(100, NSWidth(self.bounds) - 2 * ix);
    self.titleField.frame = NSMakeRect(ix - 2, kTopPad, w + 4, kTitleH);
}

- (NSRect)pageRect {
    CGFloat ix = self.insetX;
    CGFloat w = MAX(100, NSWidth(self.bounds) - 2 * ix);
    return NSMakeRect(ix - kPagePad, 0, w + 2 * kPagePad, NSHeight(self.bounds));
}

// Container-space rect of the line fragment holding character ci, in view coordinates.
- (NSRect)lineRectForChar:(NSUInteger)ci used:(BOOL)used {
    NSLayoutManager *lm = self.layoutManager;
    if (ci >= self.string.length && ci > 0) ci = self.string.length - 1;
    NSUInteger gi = [lm glyphIndexForCharacterAtIndex:ci];
    if (gi >= lm.numberOfGlyphs) return NSZeroRect;
    NSRect r = used ? [lm lineFragmentUsedRectForGlyphAtIndex:gi effectiveRange:NULL]
                    : [lm lineFragmentRectForGlyphAtIndex:gi effectiveRange:NULL];
    NSPoint o = self.textContainerOrigin;
    return NSOffsetRect(r, o.x, o.y);
}

- (NSRect)rectForCharRange:(NSRange)cr {
    NSLayoutManager *lm = self.layoutManager;
    NSRange gr = [lm glyphRangeForCharacterRange:cr actualCharacterRange:NULL];
    NSRect r = [lm boundingRectForGlyphRange:gr inTextContainer:self.textContainer];
    NSPoint o = self.textContainerOrigin;
    return NSOffsetRect(r, o.x, o.y);
}

- (NSRange)visibleCharRange:(NSRect)rect {
    NSLayoutManager *lm = self.layoutManager;
    NSPoint o = self.textContainerOrigin;
    NSRect cr = NSOffsetRect(rect, -o.x, -o.y);
    NSRange gr = [lm glyphRangeForBoundingRectWithoutAdditionalLayout:cr inTextContainer:self.textContainer];
    return [lm characterRangeForGlyphRange:gr actualGlyphRange:NULL];
}

- (void)drawViewBackgroundInRect:(NSRect)rect {
    [qDesk setFill];
    NSRectFill(rect);
    NSRect page = self.pageRect;

    // Dot grid on the desk, outside the page.
    NSInteger x0 = (NSInteger)floor(NSMinX(rect) / kDotStep), x1 = (NSInteger)ceil(NSMaxX(rect) / kDotStep);
    NSInteger y0 = (NSInteger)floor(NSMinY(rect) / kDotStep), y1 = (NSInteger)ceil(NSMaxY(rect) / kDotStep);
    NSInteger cap = (x1 - x0 + 1) * (y1 - y0 + 1);
    if (cap > 0 && cap < 200000) {
        NSRect *dots = malloc(sizeof(NSRect) * (size_t)cap);
        NSInteger n = 0;
        for (NSInteger yi = y0; yi <= y1; yi++)
            for (NSInteger xi = x0; xi <= x1; xi++) {
                CGFloat x = xi * kDotStep + 10, y = yi * kDotStep + 10;
                if (x > NSMinX(page) - 4 && x < NSMaxX(page) + 4) continue;
                dots[n++] = NSMakeRect(x, y, 1.2, 1.2);
            }
        [qDot setFill];
        NSRectFillList(dots, n);
        free(dots);
    }
    // The page and its hairline edges.
    [qPage setFill];
    NSRectFill(NSIntersectionRect(page, rect));
    [qPageEdge setFill];
    NSRectFill(NSIntersectionRect(NSMakeRect(NSMinX(page) - 1, 0, 1, NSHeight(self.bounds)), rect));
    NSRectFill(NSIntersectionRect(NSMakeRect(NSMaxX(page), 0, 1, NSHeight(self.bounds)), rect));

    if (!self.string.length) return;
    NSTextStorage *ts = self.textStorage;
    NSRange vis = [self visibleCharRange:rect];
    if (!vis.length) return;
    NSPoint o = self.textContainerOrigin;
    CGFloat cw = self.textContainer.size.width;

    // Code block panels.
    [ts enumerateAttribute:QCodeBlockAttr inRange:vis options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        if (!v || [self.editor isHiddenChar:r.location]) return;
        NSRange full = r;
        [ts attribute:QCodeBlockAttr atIndex:r.location longestEffectiveRange:&full inRange:NSMakeRange(0, ts.length)];
        NSRect a = [self lineRectForChar:full.location used:NO];
        NSRect b = [self lineRectForChar:NSMaxRange(full) - 1 used:NO];
        NSRect box = NSMakeRect(o.x - 2, NSMinY(a) - 4, cw + 4, NSMaxY(b) - NSMinY(a) + 8);
        RoundRect(box, 7, qCodeBg);
    }];
    // Quote bars.
    [ts enumerateAttribute:QQuoteAttr inRange:vis options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        if (!v || [self.editor isHiddenChar:r.location]) return;
        NSRect a = [self lineRectForChar:r.location used:YES];
        NSRect b = [self lineRectForChar:NSMaxRange(r) - 1 used:YES];
        [qQuoteBar setFill];
        NSRectFill(NSMakeRect(o.x + 1, NSMinY(a) + 2, 2, NSMaxY(b) - NSMinY(a) - 4));
    }];
    // Horizontal rules.
    [ts enumerateAttribute:QHRAttr inRange:vis options:0 usingBlock:^(id v, NSRange r, BOOL *stop) {
        if (!v || [self.editor isHiddenChar:r.location]) return;
        NSRect a = [self lineRectForChar:r.location used:YES];
        [qRule setFill];
        NSRectFill(NSMakeRect(o.x, floor(NSMidY(a)), cw, 1));
    }];
    // Task boxes.
    [ts enumerateAttribute:QTaskAttr inRange:vis options:0 usingBlock:^(NSNumber *v, NSRange r, BOOL *stop) {
        if (!v || [self.editor isHiddenChar:r.location]) return;
        NSRect g = [self rectForCharRange:r];
        NSFont *f = [ts attribute:NSFontAttributeName atIndex:r.location effectiveRange:NULL] ?: Serif(gBase, NO, NO);
        CGFloat side = round(gBase * 0.92);
        CGFloat cy = NSMinY(g) + f.ascender * 0.62 + 1;
        NSRect box = NSMakeRect(NSMinX(g) + 1, round(cy - side / 2), side, side);
        if (v.boolValue) {
            RoundRect(box, 4, qBoxDone);
            NSBezierPath *tick = [NSBezierPath bezierPath];
            [tick moveToPoint:NSMakePoint(NSMinX(box) + side * 0.25, NSMinY(box) + side * 0.52)];
            [tick lineToPoint:NSMakePoint(NSMinX(box) + side * 0.43, NSMinY(box) + side * 0.70)];
            [tick lineToPoint:NSMakePoint(NSMinX(box) + side * 0.76, NSMinY(box) + side * 0.32)];
            tick.lineWidth = 1.8; tick.lineCapStyle = NSLineCapStyleRound; tick.lineJoinStyle = NSLineJoinStyleRound;
            [qPage setStroke];
            [tick stroke];
        } else {
            NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(box, 0.75, 0.75) xRadius:4 yRadius:4];
            p.lineWidth = 1.5;
            [qBox setStroke];
            [p stroke];
        }
    }];
    // Fold chevrons and folded markers.
    NSArray<QHeading *> *hs = self.editor.headings;
    for (NSUInteger i = 0; i < hs.count; i++) {
        QHeading *h = hs[i];
        if (NSMaxRange(h.line) < vis.location || h.line.location > NSMaxRange(vis)) continue;
        if ([self.editor isHiddenChar:h.line.location]) continue;
        BOOL folded = [self.editor.folded containsObject:h.key] && h.hide.length;
        if (!folded && (NSInteger)i != self.hoverHeading) continue;
        if (!h.hide.length) continue;
        NSRect lr = [self lineRectForChar:h.line.location used:YES];
        NSFont *f = Serif(HeadingSize(h.level), YES, NO);
        CGFloat cy = NSMinY(lr) + f.ascender * 0.62 + 2;
        if (cy > NSMaxY(lr)) cy = NSMidY(lr);
        NSBezierPath *c = [NSBezierPath bezierPath];
        CGFloat cx = o.x - 18;
        if (folded) {
            [c moveToPoint:NSMakePoint(cx - 2, cy - 5)]; [c lineToPoint:NSMakePoint(cx + 3, cy)]; [c lineToPoint:NSMakePoint(cx - 2, cy + 5)];
        } else {
            [c moveToPoint:NSMakePoint(cx - 5, cy - 2)]; [c lineToPoint:NSMakePoint(cx, cy + 3)]; [c lineToPoint:NSMakePoint(cx + 5, cy - 2)];
        }
        c.lineWidth = 1.6; c.lineCapStyle = NSLineCapStyleRound; c.lineJoinStyle = NSLineJoinStyleRound;
        [(folded ? qMuted : qFaint) setStroke];
        [c stroke];
        if (folded) {
            NSRect pill = NSMakeRect(NSMaxX(lr) + 10, round(cy - 8), 26, 16);
            RoundRect(pill, 8, qInlineCodeBg);
            NSDictionary *a = @{NSFontAttributeName: UIFont(11, NSFontWeightBold), NSForegroundColorAttributeName: qMuted};
            NSSize sz = [@"···" sizeWithAttributes:a];
            [@"···" drawAtPoint:NSMakePoint(NSMidX(pill) - sz.width / 2, NSMidY(pill) - sz.height / 2) withAttributes:a];
        }
    }
}

#pragma mark Hit testing

- (NSUInteger)charAtPoint:(NSPoint)p {
    if (!self.string.length) return NSNotFound;
    NSPoint o = self.textContainerOrigin;
    NSPoint pc = NSMakePoint(p.x - o.x, p.y - o.y);
    NSLayoutManager *lm = self.layoutManager;
    CGFloat frac = 0;
    NSUInteger gi = [lm glyphIndexForPoint:pc inTextContainer:self.textContainer fractionOfDistanceThroughGlyph:&frac];
    if (gi >= lm.numberOfGlyphs) return NSNotFound;
    NSRect gr = [lm boundingRectForGlyphRange:NSMakeRange(gi, 1) inTextContainer:self.textContainer];
    if (!NSPointInRect(pc, NSInsetRect(gr, -3, -3))) return NSNotFound;
    NSUInteger ci = [lm characterIndexForGlyphAtIndex:gi];
    return ci < self.string.length ? ci : NSNotFound;
}

- (NSInteger)headingAtY:(CGFloat)y {
    NSArray<QHeading *> *hs = self.editor.headings;
    for (NSUInteger i = 0; i < hs.count; i++) {
        QHeading *h = hs[i];
        if ([self.editor isHiddenChar:h.line.location]) continue;
        NSRect lr = [self lineRectForChar:h.line.location used:NO];
        if (y >= NSMinY(lr) && y < NSMaxY(lr)) return (NSInteger)i;
        if (NSMinY(lr) > y) break;
    }
    return -1;
}

- (NSInteger)gutterHeadingAt:(NSPoint)p {
    CGFloat ox = self.textContainerOrigin.x;
    if (p.x < ox - 36 || p.x > ox - 2) return -1;
    NSInteger i = [self headingAtY:p.y];
    if (i >= 0 && self.editor.headings[(NSUInteger)i].hide.length == 0) return -1;
    return i;
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSInteger hi = [self gutterHeadingAt:p];
    if (hi >= 0) { [self.editor toggleFoldAtHeading:hi]; return; }
    NSEventModifierFlags mods = e.modifierFlags & (NSEventModifierFlagShift | NSEventModifierFlagOption | NSEventModifierFlagControl);
    if (e.clickCount == 1 && mods == 0) {
        NSUInteger ci = [self charAtPoint:p];
        if (ci != NSNotFound) {
            NSTextStorage *ts = self.textStorage;
            NSRange r;
            if ([ts attribute:QTaskAttr atIndex:ci effectiveRange:&r]) { [self.editor toggleTaskAt:r]; return; }
            NSString *link = [ts attribute:QLinkAttr atIndex:ci effectiveRange:NULL];
            if (link) { [self.editor openLink:link]; return; }
            NSString *url = [ts attribute:QURLAttr atIndex:ci effectiveRange:NULL];
            if (url) { [self.editor openURL:url]; return; }
            NSString *tag = [ts attribute:QTagAttr atIndex:ci effectiveRange:NULL];
            if (tag) { [self.editor searchTag:tag]; return; }
        }
    }
    [super mouseDown:e];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *ta in self.trackingAreas.copy) if (ta.owner == self && ta.userInfo[@"q"]) [self removeTrackingArea:ta];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
          owner:self userInfo:@{@"q": @YES}]];
}

// One owner for the cursor: the text view's own I-beam rects fought the hand cursor and made it flicker.
- (NSCursor *)cursorAt:(NSPoint)p {
    if ([self gutterHeadingAt:p] >= 0) return NSCursor.pointingHandCursor;
    NSUInteger ci = [self charAtPoint:p];
    if (ci != NSNotFound) {
        NSTextStorage *ts = self.textStorage;
        if ([ts attribute:QTaskAttr atIndex:ci effectiveRange:NULL] || [ts attribute:QLinkAttr atIndex:ci effectiveRange:NULL] ||
            [ts attribute:QURLAttr atIndex:ci effectiveRange:NULL] || [ts attribute:QTagAttr atIndex:ci effectiveRange:NULL])
            return NSCursor.pointingHandCursor;
    }
    NSRect page = self.pageRect;
    CGFloat ox = self.textContainerOrigin.x;
    NSRect column = NSMakeRect(ox, NSMinY(page), NSMaxX(page) - ox, NSHeight(page));
    return NSPointInRect(p, column) ? NSCursor.IBeamCursor : NSCursor.arrowCursor;
}

- (void)resetCursorRects {}

- (void)cursorUpdate:(NSEvent *)e {
    [[self cursorAt:[self convertPoint:e.locationInWindow fromView:nil]] set];
}

- (void)mouseMoved:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect page = self.pageRect;
    NSInteger h = NSPointInRect(p, page) ? [self headingAtY:p.y] : -1;
    if (h != self.hoverHeading) { self.hoverHeading = h; self.needsDisplay = YES; }
    [[self cursorAt:p] set];
}

- (void)mouseExited:(NSEvent *)e {
    [super mouseExited:e];
    if (self.hoverHeading != -1) { self.hoverHeading = -1; self.needsDisplay = YES; }
}

#pragma mark Writing helpers

- (NSRange)currentLineRange { return [self.string lineRangeForRange:NSMakeRange(self.selectedRange.location, 0)]; }

- (void)replace:(NSRange)r with:(NSString *)s select:(NSRange)sel {
    if ([self shouldChangeTextInRange:r replacementString:s]) {
        [self.textStorage replaceCharactersInRange:r withString:s];
        [self didChangeText];
        self.selectedRange = sel;
    }
}

// Continue lists and tasks on Return; Return on an empty item ends the list.
- (void)insertNewline:(id)sender {
    NSString *s = self.string;
    NSRange sel = self.selectedRange;
    NSRange lr = [s lineRangeForRange:NSMakeRange(sel.location, 0)];
    NSUInteger cend = lr.location;
    [s getLineStart:NULL end:NULL contentsEnd:&cend forRange:NSMakeRange(sel.location, 0)];
    NSString *line = [s substringWithRange:NSMakeRange(lr.location, cend - lr.location)];
    NSTextCheckingResult *m = sel.length == 0 ? [rxList firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] : nil;
    if (!m || sel.location < lr.location + m.range.length) {
        NSTextCheckingResult *q = sel.length == 0 ? [rxQuote firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] : nil;
        if (q && sel.location >= lr.location + q.range.length) {
            if (Trim([line substringFromIndex:q.range.length]).length == 0) {
                [self replace:NSMakeRange(lr.location, cend - lr.location) with:@"" select:NSMakeRange(lr.location, 0)];
                return;
            }
            NSString *ins = [@"\n" stringByAppendingString:[line substringToIndex:q.range.length]];
            [self replace:sel with:ins select:NSMakeRange(sel.location + ins.length, 0)];
            return;
        }
        [super insertNewline:sender];
        return;
    }
    NSString *rest = [line substringFromIndex:m.range.length];
    if (Trim(rest).length == 0) {   // empty item: drop the marker
        [self replace:NSMakeRange(lr.location, cend - lr.location) with:@"" select:NSMakeRange(lr.location, 0)];
        return;
    }
    NSString *indent = [line substringWithRange:[m rangeAtIndex:1]];
    NSString *marker = [line substringWithRange:[m rangeAtIndex:2]];
    NSString *gap = [line substringWithRange:[m rangeAtIndex:3]];
    if (!gap.length) gap = @" ";
    unichar c0 = [marker characterAtIndex:0];
    if (c0 >= '0' && c0 <= '9') {
        NSInteger n = marker.integerValue + 1;
        marker = [NSString stringWithFormat:@"%ld%@", (long)n, [marker substringFromIndex:marker.length - 1]];
    }
    NSString *task = [m rangeAtIndex:4].location != NSNotFound ? @"[ ] " : @"";
    NSString *ins = [NSString stringWithFormat:@"\n%@%@%@%@", indent, marker, gap, task];
    [self replace:sel with:ins select:NSMakeRange(sel.location + ins.length, 0)];
}

- (BOOL)lineIsListItem:(NSRange)lr {
    NSString *line = [self.string substringWithRange:lr];
    return [rxList firstMatchInString:line options:0 range:NSMakeRange(0, line.length)] != nil;
}

- (void)insertTab:(id)sender {
    NSRange lr = [self currentLineRange];
    if (self.selectedRange.length == 0 && [self lineIsListItem:lr]) {
        NSRange sel = self.selectedRange;
        [self replace:NSMakeRange(lr.location, 0) with:@"\t" select:NSMakeRange(sel.location + 1, 0)];
        return;
    }
    [super insertTab:sender];
}

- (void)insertBacktab:(id)sender {
    NSRange lr = [self currentLineRange];
    NSString *s = self.string;
    NSRange sel = self.selectedRange;
    if (lr.length && [s characterAtIndex:lr.location] == '\t') {
        [self replace:NSMakeRange(lr.location, 1) with:@"" select:NSMakeRange(sel.location > lr.location ? sel.location - 1 : sel.location, 0)];
        return;
    }
    NSUInteger n = 0;
    while (n < 4 && lr.location + n < s.length && [s characterAtIndex:lr.location + n] == ' ') n++;
    if (n) [self replace:NSMakeRange(lr.location, n) with:@"" select:NSMakeRange(sel.location >= lr.location + n ? sel.location - n : lr.location, 0)];
}

- (void)wrapWith:(NSString *)open close:(NSString *)close {
    NSRange sel = self.selectedRange;
    NSString *s = self.string;
    NSUInteger ol = open.length, cl = close.length;
    if (sel.location >= ol && NSMaxRange(sel) + cl <= s.length &&
        [[s substringWithRange:NSMakeRange(sel.location - ol, ol)] isEqualToString:open] &&
        [[s substringWithRange:NSMakeRange(NSMaxRange(sel), cl)] isEqualToString:close]) {
        NSString *inner = [s substringWithRange:sel];
        [self replace:NSMakeRange(sel.location - ol, sel.length + ol + cl) with:inner select:NSMakeRange(sel.location - ol, sel.length)];
        return;
    }
    NSString *inner = [s substringWithRange:sel];
    NSString *out = [NSString stringWithFormat:@"%@%@%@", open, inner, close];
    [self replace:sel with:out select:NSMakeRange(sel.location + ol, sel.length)];
}

- (void)mdBold:(id)sender { [self wrapWith:@"**" close:@"**"]; }
- (void)mdItalic:(id)sender { [self wrapWith:@"*" close:@"*"]; }
- (void)mdStrike:(id)sender { [self wrapWith:@"~~" close:@"~~"]; }
- (void)mdHighlight:(id)sender { [self wrapWith:@"==" close:@"=="]; }
- (void)mdCode:(id)sender { [self wrapWith:@"`" close:@"`"]; }
- (void)mdLink:(id)sender { [self wrapWith:@"[[" close:@"]]"]; }

- (void)mdTask:(id)sender {
    NSRange lr = [self currentLineRange];
    NSString *s = self.string;
    NSUInteger cend = lr.location;
    [s getLineStart:NULL end:NULL contentsEnd:&cend forRange:NSMakeRange(lr.location, 0)];
    NSString *line = [s substringWithRange:NSMakeRange(lr.location, cend - lr.location)];
    NSRange sel = self.selectedRange;
    NSTextCheckingResult *m = [rxList firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    NSString *newLine;
    if (m && [m rangeAtIndex:4].location != NSNotFound) {
        NSRange tick = [m rangeAtIndex:5];
        BOOL done = ![[line substringWithRange:tick] isEqualToString:@" "];
        newLine = [line stringByReplacingCharactersInRange:tick withString:done ? @" " : @"x"];
    } else if (m) {
        NSUInteger at = NSMaxRange([m rangeAtIndex:3]);
        newLine = [line stringByReplacingCharactersInRange:NSMakeRange(at, 0) withString:@"[ ] "];
    } else {
        NSUInteger lead = 0;
        while (lead < line.length && ([line characterAtIndex:lead] == ' ' || [line characterAtIndex:lead] == '\t')) lead++;
        newLine = [line stringByReplacingCharactersInRange:NSMakeRange(lead, 0) withString:@"- [ ] "];
    }
    NSInteger delta = (NSInteger)newLine.length - (NSInteger)line.length;
    NSUInteger loc = (NSUInteger)MAX((NSInteger)lr.location, (NSInteger)sel.location + delta);
    [self replace:NSMakeRange(lr.location, line.length) with:newLine select:NSMakeRange(loc, 0)];
}

- (void)mdHeading:(NSMenuItem *)sender {
    NSInteger level = sender.tag;
    NSRange lr = [self currentLineRange];
    NSString *s = self.string;
    NSUInteger cend = lr.location;
    [s getLineStart:NULL end:NULL contentsEnd:&cend forRange:NSMakeRange(lr.location, 0)];
    NSString *line = [s substringWithRange:NSMakeRange(lr.location, cend - lr.location)];
    NSTextCheckingResult *m = [rxHeading firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
    NSString *text = m ? [line substringFromIndex:m.range.length] : line;
    NSInteger current = m ? (NSInteger)[m rangeAtIndex:1].length : 0;
    NSString *prefix = (level == 0 || level == current) ? @"" : [[@"" stringByPaddingToLength:(NSUInteger)level withString:@"#" startingAtIndex:0] stringByAppendingString:@" "];
    NSString *newLine = [prefix stringByAppendingString:text];
    [self replace:NSMakeRange(lr.location, line.length) with:newLine select:NSMakeRange(lr.location + newLine.length, 0)];
}

- (void)foldHeading:(id)sender { [self.editor foldHere:YES]; }
- (void)unfoldHeading:(id)sender { [self.editor foldHere:NO]; }
- (void)foldAllHeadings:(id)sender { [self.editor foldAll:YES]; }
- (void)unfoldAllHeadings:(id)sender { [self.editor foldAll:NO]; }

@end

#pragma mark - Editor

@interface QEditor ()
@property (strong) NSArray<NSValue *> *blocks;
@property NSRange front;
@property BOOL styling, loading;
@property (strong) NSTimer *saveTimer;
@property (strong) NSDate *savedMtime;
@property (strong) NSMutableArray<NSString *> *back, *forward;
@property NSUInteger words;
@property BOOL readOnly;
@end

@implementation QEditor

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _folded = [NSMutableSet set];
    _headings = @[]; _hidden = @[]; _blocks = @[];
    _front = NSMakeRange(NSNotFound, 0);
    _back = [NSMutableArray array]; _forward = [NSMutableArray array];
    [self buildViews];
    return self;
}

#pragma mark Views

- (void)buildViews {
    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 700)];
    v.wantsLayer = YES;
    v.layer.backgroundColor = qDesk.CGColor;
    self.view = v;

    // Top bar: back, forward, where you are.
    QDragBar *bar = [[QDragBar alloc] initWithFrame:NSMakeRect(0, 0, 900, 40)];
    self.topBar = bar;
    self.backButton = [QIconButton symbol:@"chevron.left" size:12 tip:@"Back (⌘[)" target:self action:@selector(goBack)];
    self.forwardButton = [QIconButton symbol:@"chevron.right" size:12 tip:@"Forward (⌘])" target:self action:@selector(goForward)];
    self.crumb = Label(@"", UIFont(12, NSFontWeightRegular), qMuted);
    [bar addSubview:self.backButton]; [bar addSubview:self.forwardButton]; [bar addSubview:self.crumb];
    [v addSubview:bar];

    // The page.
    NSTextStorage *ts = [NSTextStorage new];
    ts.delegate = self;
    NSLayoutManager *lm = [NSLayoutManager new];
    lm.delegate = self;
    lm.allowsNonContiguousLayout = YES;
    [ts addLayoutManager:lm];
    NSTextContainer *tc = [[NSTextContainer alloc] initWithSize:NSMakeSize(680, CGFLOAT_MAX)];
    tc.widthTracksTextView = YES;
    tc.lineFragmentPadding = 0;
    [lm addTextContainer:tc];

    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 900, 660)];
    sv.hasVerticalScroller = YES;
    sv.autohidesScrollers = YES;
    sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.scrollerKnobStyle = NSScrollerKnobStyleLight;
    sv.drawsBackground = YES;
    sv.backgroundColor = qDesk;
    sv.borderType = NSNoBorder;
    sv.contentView.postsBoundsChangedNotifications = YES;

    QTextView *tv = [[QTextView alloc] initWithFrame:NSMakeRect(0, 0, 900, 660) textContainer:tc];
    tv.editor = self;
    tv.hoverHeading = -1;
    tv.pageWidth = [Defaults() doubleForKey:kPageWidth] ?: 680;
    tv.minSize = NSMakeSize(0, 660);
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES;
    tv.horizontallyResizable = NO;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.richText = NO;
    tv.importsGraphics = NO;
    tv.allowsUndo = YES;
    tv.usesFindBar = YES;
    tv.incrementalSearchingEnabled = YES;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.automaticDashSubstitutionEnabled = NO;
    tv.automaticTextReplacementEnabled = NO;
    tv.automaticSpellingCorrectionEnabled = NO;
    tv.continuousSpellCheckingEnabled = YES;
    tv.smartInsertDeleteEnabled = NO;
    tv.drawsBackground = YES;
    tv.backgroundColor = qDesk;
    tv.insertionPointColor = qHead;
    tv.selectedTextAttributes = @{NSBackgroundColorAttributeName: Hex(0x34322e)};
    tv.linkTextAttributes = @{};
    tv.typingAttributes = @{NSFontAttributeName: Serif(gBase, NO, NO), NSForegroundColorAttributeName: qText,
                            NSParagraphStyleAttributeName: Para(@"body", 0, 0)};
    tv.delegate = self;

    NSTextField *title = [[NSTextField alloc] initWithFrame:NSMakeRect(0, kTopPad, 680, kTitleH)];
    title.bezeled = NO; title.bordered = NO; title.drawsBackground = NO; title.focusRingType = NSFocusRingTypeNone;
    title.font = Serif(round(gBase * 2.05), YES, NO);
    title.textColor = qHead;
    title.placeholderString = @"Untitled";
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.cell.usesSingleLineMode = YES;
    title.cell.scrollable = YES;
    title.delegate = self;
    [tv addSubview:title];
    tv.titleField = title;

    sv.documentView = tv;
    self.scroll = sv;
    self.textView = tv;
    [v addSubview:sv];

    self.canvas = [[QCanvasView alloc] initWithFrame:NSMakeRect(0, 0, 900, 660)];
    self.canvas.hidden = YES;
    [v addSubview:self.canvas];

    self.status = Label(@"", UIFont(11.5, NSFontWeightRegular), qFaint);
    self.status.alignment = NSTextAlignmentRight;
    [v addSubview:self.status];

    // Shown when nothing is open.
    NSView *empty = [[NSView alloc] initWithFrame:v.bounds];
    NSTextField *e1 = Label(@"Nothing open", Serif(26, YES, NO), qHead);
    NSTextField *e2 = Label(@"Pick a note on the left, press ⌘O to jump to one, or ⌘N to start a new one.", UIFont(13, NSFontWeightRegular), qMuted);
    e1.alignment = NSTextAlignmentCenter; e2.alignment = NSTextAlignmentCenter;
    e1.tag = 1; e2.tag = 2;
    [empty addSubview:e1]; [empty addSubview:e2];
    self.emptyView = empty;
    [v addSubview:empty];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(layout) name:NSViewFrameDidChangeNotification object:v];
    v.postsFrameChangedNotifications = YES;
    [self showEmpty:YES];
    [self layout];
}

- (void)layoutForSidebarHidden:(BOOL)hidden { [self layout]; }

- (void)layout {
    NSRect b = self.view.bounds;
    CGFloat barH = 36;
    BOOL flipped = self.view.isFlipped;
    NSRect barRect = flipped ? NSMakeRect(0, 0, NSWidth(b), barH) : NSMakeRect(0, NSHeight(b) - barH, NSWidth(b), barH);
    self.topBar.frame = barRect;
    CGFloat left = gApp.sidebarHidden ? 82 : 14;
    self.backButton.frame = NSMakeRect(left, 1, 26, 26);
    self.forwardButton.frame = NSMakeRect(left + 26, 1, 26, 26);
    self.crumb.frame = NSMakeRect(left + 62, 6, MAX(50, NSWidth(b) - left - 80), 16);
    NSRect body = flipped ? NSMakeRect(0, barH, NSWidth(b), NSHeight(b) - barH) : NSMakeRect(0, 0, NSWidth(b), NSHeight(b) - barH);
    self.scroll.frame = body;
    self.canvas.frame = body;
    self.emptyView.frame = body;
    NSTextField *e1 = [self.emptyView viewWithTag:1], *e2 = [self.emptyView viewWithTag:2];
    e1.frame = NSMakeRect(0, NSHeight(body) / 2 + 6, NSWidth(body), 34);
    e2.frame = NSMakeRect(20, NSHeight(body) / 2 - 22, NSWidth(body) - 40, 20);
    self.status.frame = NSMakeRect(NSWidth(b) - 320, 10, 300, 16);
    self.textView.minSize = NSMakeSize(0, NSHeight(body));
    [self.textView updateGeometry];
    self.textView.needsDisplay = YES;
}

- (void)showEmpty:(BOOL)empty {
    self.emptyView.hidden = !empty;
    self.scroll.hidden = empty || [self isCanvasPath:self.path];
    self.canvas.hidden = empty || ![self isCanvasPath:self.path];
    self.status.hidden = empty;
    self.backButton.hidden = self.forwardButton.hidden = empty && !self.back.count;
}

- (BOOL)isCanvasPath:(NSString *)p { return [p.pathExtension.lowercaseString isEqualToString:@"canvas"]; }

- (void)applySettings {
    gBase = [Defaults() doubleForKey:kFontSize] ?: 17;
    [gFontCache removeAllObjects];
    [gParaCache removeAllObjects];
    self.textView.pageWidth = [Defaults() doubleForKey:kPageWidth] ?: 680;
    self.textView.titleField.font = Serif(round(gBase * 2.05), YES, NO);
    self.textView.typingAttributes = @{NSFontAttributeName: Serif(gBase, NO, NO), NSForegroundColorAttributeName: qText,
                                       NSParagraphStyleAttributeName: Para(@"body", 0, 0)};
    [self restyleAll];
    [self layout];
}

#pragma mark Opening and saving

- (void)openPath:(NSString *)path { [self openPath:path history:YES]; }

- (void)openPath:(NSString *)path history:(BOOL)h {
    path = path.stringByStandardizingPath;
    if (!path || [path isEqualToString:self.path]) { [gApp.sidebar revealPath:path]; return; }
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) { NSBeep(); return; }
    if (self.textView.titleField.currentEditor) [self.view.window makeFirstResponder:self.textView];   // commits a rename first
    [self saveNow];
    [self rememberCaret];
    if (h && self.path) { [self.back addObject:self.path]; [self.forward removeAllObjects]; }
    self.path = path;

    if ([self isCanvasPath:path]) {
        self.textView.titleField.stringValue = [path.lastPathComponent stringByDeletingPathExtension];
        [self.canvas loadPath:path];
        [self showEmpty:NO];
        [self.view.window makeFirstResponder:self.canvas];
    } else {
        [self loadText];
        [self showEmpty:NO];
        [self restoreCaret];
        [self.view.window makeFirstResponder:self.textView];
    }
    [self updateCrumb];
    [self updateStatus];
    [Defaults() setObject:[gApp.vault rel:path] forKey:kLastNote];
    [gApp.sidebar revealPath:path];
}

- (void)loadText {
    NSString *read = ReadText(self.path);
    self.readOnly = (read == nil);   // couldn't decode: show nothing, never write back
    NSString *text = read ?: @"";
    self.savedMtime = ModDate(self.path);
    self.dirty = NO;
    NSArray *keys = [Defaults() dictionaryForKey:kFolds][[gApp.vault rel:self.path]];
    [self.folded removeAllObjects];
    if ([keys isKindOfClass:NSArray.class]) [self.folded addObjectsFromArray:keys];
    self.hidden = @[];
    self.loading = YES;
    NSTextStorage *ts = self.textView.textStorage;
    [ts beginEditing];
    [ts replaceCharactersInRange:NSMakeRange(0, ts.length) withString:text];
    [ts endEditing];
    self.loading = NO;
    [self.textView.undoManager removeAllActions];
    [self refreshStructureInvalidating:YES];
    self.textView.titleField.stringValue = [self.path.lastPathComponent stringByDeletingPathExtension];
    self.words = WordCount(text);
}

- (void)reloadFromDisk {
    NSRange sel = self.textView.selectedRange;
    NSPoint scroll = self.scroll.contentView.bounds.origin;
    [self loadText];
    NSUInteger len = self.textView.string.length;
    self.textView.selectedRange = NSMakeRange(MIN(sel.location, len), 0);
    [self.scroll.contentView scrollToPoint:scroll];
    [self.scroll reflectScrolledClipView:self.scroll.contentView];
    [self updateStatus];
}

- (void)closeNote {
    if (self.textView.titleField.currentEditor) [self.view.window makeFirstResponder:self.textView];
    [self saveNow];
    self.path = nil;
    NSTextStorage *ts = self.textView.textStorage;
    self.loading = YES;
    [ts replaceCharactersInRange:NSMakeRange(0, ts.length) withString:@""];
    self.loading = NO;
    [self.textView.undoManager removeAllActions];
    self.headings = @[]; self.hidden = @[];
    self.crumb.stringValue = @"";
    [self showEmpty:YES];
}

- (void)textDidChange:(NSNotification *)n {
    if (n.object != self.textView || !self.path) return;
    self.dirty = YES;
    [self.saveTimer invalidate];
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(saveNow) userInfo:nil repeats:NO];
}

- (void)saveNow {
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    if (!self.canvas.hidden) [self.canvas saveNow];
    if (!self.dirty || !self.path || [self isCanvasPath:self.path]) return;
    if (self.readOnly) { self.status.stringValue = @"This file couldn't be read as text, so Quire won't save over it."; return; }
    NSString *text = self.textView.string;
    // 5. Someone else (sync, git, another app) changed the file since we loaded it: keep both.
    NSDate *disk = ModDate(self.path);
    if (disk && self.savedMtime && [disk compare:self.savedMtime] == NSOrderedDescending) {
        NSString *name = [[self.path.lastPathComponent stringByDeletingPathExtension] stringByAppendingString:@" (conflict)"];
        NSString *copy = FreePath(self.path.stringByDeletingLastPathComponent, name, @"md");
        [text writeToFile:copy atomically:YES encoding:NSUTF8StringEncoding error:nil];
        self.dirty = NO;
        [self reloadFromDisk];
        self.status.stringValue = [NSString stringWithFormat:@"Changed on disk. Your edits are in \"%@\".", copy.lastPathComponent.stringByDeletingPathExtension];
        [gApp rescanSoon];
        return;
    }
    NSError *err = nil;
    if (![text writeToFile:self.path atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        self.status.stringValue = @"Couldn't save. Check that the vault folder still exists.";
        NSLog(@"Quire: save failed %@", err);
        return;
    }
    self.savedMtime = ModDate(self.path);
    self.dirty = NO;
    [QIndex forget:self.path];
    self.words = WordCount(text);
    [self updateStatus];
}

// The file changed on disk. Reload unless we're holding unsaved edits.
- (void)fileChanged:(NSString *)path {
    if (!self.path || ![path isEqualToString:self.path]) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) return;
    if ([self isCanvasPath:path]) { [self.canvas reloadIfChanged]; return; }
    NSDate *m = ModDate(path);
    if (m && self.savedMtime && [m isEqualToDate:self.savedMtime]) return;
    if (self.dirty) return;
    [self reloadFromDisk];
}

- (void)pathMoved:(NSString *)from to:(NSString *)to {
    if (!self.path) return;
    if ([self.path isEqualToString:from]) self.path = to;
    else if ([self.path hasPrefix:[from stringByAppendingString:@"/"]])
        self.path = [to stringByAppendingString:[self.path substringFromIndex:from.length]];
    else return;
    if ([self isCanvasPath:self.path]) self.canvas.path = self.path;
    self.textView.titleField.stringValue = [self.path.lastPathComponent stringByDeletingPathExtension];
    [self updateCrumb];
    [Defaults() setObject:[gApp.vault rel:self.path] forKey:kLastNote];
}

- (void)updateCrumb {
    if (!self.path) { self.crumb.stringValue = @""; return; }
    NSString *rel = Pretty([gApp.vault rel:self.path]);
    NSArray *parts = [rel componentsSeparatedByString:@"/"];
    NSMutableAttributedString *a = [NSMutableAttributedString new];
    NSDictionary *dim = @{NSFontAttributeName: UIFont(12, NSFontWeightRegular), NSForegroundColorAttributeName: qMuted};
    NSDictionary *hi = @{NSFontAttributeName: UIFont(12, NSFontWeightMedium), NSForegroundColorAttributeName: qBody2};
    for (NSUInteger i = 0; i < parts.count; i++) {
        BOOL last = i + 1 == parts.count;
        NSString *p = [self isCanvasPath:self.path] && last ? [parts[i] stringByDeletingPathExtension] : parts[i];
        [a appendAttributedString:[[NSAttributedString alloc] initWithString:p attributes:last ? hi : dim]];
        if (!last) [a appendAttributedString:[[NSAttributedString alloc] initWithString:@"  /  " attributes:dim]];
    }
    self.crumb.attributedStringValue = a;
    self.backButton.enabled = self.back.count > 0;
    self.forwardButton.enabled = self.forward.count > 0;
    self.backButton.hidden = self.forwardButton.hidden = NO;
}

- (void)updateStatus {
    if (!self.path) { self.status.stringValue = @""; return; }
    if ([self isCanvasPath:self.path]) {
        NSUInteger n = self.canvas.cardCount;
        self.status.stringValue = [NSString stringWithFormat:@"%lu card%@", (unsigned long)n, n == 1 ? @"" : @"s"];
        return;
    }
    self.status.stringValue = [NSString stringWithFormat:@"%lu word%@%@", (unsigned long)self.words, self.words == 1 ? @"" : @"s",
                               self.dirty ? @"" : @"  ·  saved"];
}

#pragma mark Caret memory

- (void)rememberCaret {
    if (!self.path || [self isCanvasPath:self.path]) return;
    NSMutableDictionary *d = [[Defaults() dictionaryForKey:kCarets] mutableCopy] ?: [NSMutableDictionary dictionary];
    d[[gApp.vault rel:self.path]] = @(self.textView.selectedRange.location);
    if (d.count > 400) [d removeObjectForKey:d.allKeys.firstObject];
    [Defaults() setObject:d forKey:kCarets];
}

- (void)restoreCaret {
    NSNumber *n = [Defaults() dictionaryForKey:kCarets][[gApp.vault rel:self.path]];
    NSUInteger len = self.textView.string.length;
    NSUInteger loc = MIN((NSUInteger)n.unsignedIntegerValue, len);
    if ([self isHiddenChar:loc]) loc = 0;
    self.textView.selectedRange = NSMakeRange(loc, 0);
    if (loc > 0) [self.textView scrollRangeToVisible:NSMakeRange(loc, 0)];
    else [self.scroll.contentView scrollToPoint:NSZeroPoint];
    [self.scroll reflectScrolledClipView:self.scroll.contentView];
}

#pragma mark Styling

// Folded text is collapsed two ways: hidden glyphs, and attributes that shrink every hidden line to nothing.
static NSDictionary *FoldAttrs(void) {
    static NSDictionary *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
        p.minimumLineHeight = 0; p.maximumLineHeight = 0.01;
        p.lineSpacing = 0; p.paragraphSpacing = 0; p.paragraphSpacingBefore = 0;
        a = @{NSFontAttributeName: [NSFont systemFontOfSize:0.01], NSForegroundColorAttributeName: NSColor.clearColor,
              NSParagraphStyleAttributeName: p};
    });
    return a;
}

- (void)applyFoldAttributes:(NSTextStorage *)ts {
    NSUInteger len = ts.length;
    for (NSValue *v in self.hidden) {
        NSRange r = NSIntersectionRange(v.rangeValue, NSMakeRange(0, len));
        if (r.length) [ts setAttributes:FoldAttrs() range:r];
    }
}

- (void)restyleAll {
    NSTextStorage *ts = self.textView.textStorage;
    self.front = FrontMatter(ts.string);
    self.blocks = CodeBlocks(ts.string, self.front);
    self.styling = YES;
    [ts beginEditing];
    StyleRange(ts, NSMakeRange(0, ts.length), self.blocks, self.front);
    [ts endEditing];
    self.styling = NO;
    [self refreshStructureInvalidating:YES];
}

- (void)textStorage:(NSTextStorage *)ts didProcessEditing:(NSTextStorageEditActions)mask range:(NSRange)edited changeInLength:(NSInteger)delta {
    if (self.styling || !(mask & NSTextStorageEditedCharacters)) return;
    self.styling = YES;
    NSString *s = ts.string;
    NSRange oldFront = self.front;
    NSUInteger oldBlocks = self.blocks.count;
    self.front = FrontMatter(s);
    self.blocks = CodeBlocks(s, self.front);
    NSRange lineRange = [s lineRangeForRange:NSMakeRange(MIN(edited.location, s.length), MIN(edited.length, s.length - MIN(edited.location, s.length)))];
    NSString *touched = [s substringWithRange:lineRange];
    BOOL full = self.loading || self.blocks.count != oldBlocks || oldFront.location != self.front.location ||
                (self.front.location != NSNotFound && NSMaxRange(oldFront) != NSMaxRange(self.front)) ||
                [touched containsString:@"```"] || [touched containsString:@"~~~"];
    // A line inside a code block changes how far that block reaches when fences are typed; restyle the block too.
    if (!full) for (NSValue *v in self.blocks) if (NSIntersectionRange(v.rangeValue, lineRange).length) { lineRange = NSUnionRange(lineRange, v.rangeValue); }
    StyleRange(ts, full ? NSMakeRange(0, s.length) : lineRange, self.blocks, self.front);
    if (self.loading) { self.styling = NO; return; }
    // Recompute folds now, before the layout manager regenerates glyphs for the edit.
    NSArray<NSValue *> *old = self.hidden;
    [self computeStructure];
    if (old.count != self.hidden.count) StyleRange(ts, NSMakeRange(0, s.length), self.blocks, self.front);   // a fold went away: restore its text
    [self applyFoldAttributes:ts];
    self.styling = NO;
    if (old.count || self.hidden.count) {
        NSMutableArray *rs = [old mutableCopy];
        [rs addObjectsFromArray:self.hidden];
        dispatch_async(dispatch_get_main_queue(), ^{ [self invalidateRanges:rs all:NO]; });
    }
}

- (void)computeStructure {
    NSString *s = self.textView.string;
    self.headings = Headings(s, self.blocks, self.front);
    NSMutableArray *hid = [NSMutableArray array];
    NSRange last = NSMakeRange(NSNotFound, 0);
    for (QHeading *h in self.headings) {
        if (!h.hide.length || ![self.folded containsObject:h.key]) continue;
        if (last.location != NSNotFound && NSLocationInRange(h.hide.location, last)) continue;   // inside an outer fold
        [hid addObject:[NSValue valueWithRange:h.hide]];
        last = h.hide;
    }
    self.hidden = hid;
}

- (void)invalidateRanges:(NSArray<NSValue *> *)ranges all:(BOOL)all {
    NSLayoutManager *lm = self.textView.layoutManager;
    NSUInteger len = self.textView.string.length;
    NSMutableArray *rs = [ranges mutableCopy];
    if (all) [rs addObject:[NSValue valueWithRange:NSMakeRange(0, len)]];
    for (NSValue *v in rs) {
        NSRange r = v.rangeValue;
        if (r.location > len) continue;
        NSUInteger from = r.location > 0 ? r.location - 1 : 0;
        NSUInteger to = MIN(len, NSMaxRange(r) + 1);
        if (to <= from) continue;
        NSRange wide = NSMakeRange(from, to - from);
        [lm invalidateGlyphsForCharacterRange:wide changeInLength:0 actualCharacterRange:NULL];
        [lm invalidateLayoutForCharacterRange:wide actualCharacterRange:NULL];
    }
    self.textView.needsDisplay = YES;
}

// Recompute headings and folds, then re-lay-out whatever changed.
- (void)refreshStructureInvalidating:(BOOL)force {
    NSArray<NSValue *> *old = self.hidden;
    [self computeStructure];
    NSTextStorage *ts = self.textView.textStorage;
    NSUInteger len = ts.length;
    self.styling = YES;
    [ts beginEditing];
    for (NSValue *v in old) {   // bring back text that was folded
        NSRange r = NSIntersectionRange(v.rangeValue, NSMakeRange(0, len));
        if (r.length) StyleRange(ts, r, self.blocks, self.front);
    }
    [self applyFoldAttributes:ts];
    [ts endEditing];
    self.styling = NO;
    NSMutableArray *rs = [old mutableCopy];
    [rs addObjectsFromArray:self.hidden];
    [self invalidateRanges:rs all:force];
}

- (BOOL)isHiddenChar:(NSUInteger)ci {
    for (NSValue *v in self.hidden) {
        NSRange r = v.rangeValue;
        if (ci >= r.location && ci < NSMaxRange(r)) return YES;
        if (r.location > ci) break;
    }
    return NO;
}

#pragma mark Folding (glyph generation)

- (NSUInteger)layoutManager:(NSLayoutManager *)lm shouldGenerateGlyphs:(const CGGlyph *)glyphs properties:(const NSGlyphProperty *)props
           characterIndexes:(const NSUInteger *)charIndexes font:(NSFont *)aFont forGlyphRange:(NSRange)glyphRange {
    NSTextStorage *ts = lm.textStorage;
    NSString *s = ts.string;
    NSUInteger n = glyphRange.length;
    BOOL touch = NO;
    for (NSUInteger i = 0; i < n && !touch; i++) {
        NSUInteger ci = charIndexes[i];
        if ([self isHiddenChar:ci]) touch = YES;
        else if (ci < s.length) {
            unichar c = [s characterAtIndex:ci];
            if ((c == '-' || c == '*' || c == '+') && [ts attribute:QBulletAttr atIndex:ci effectiveRange:NULL]) touch = YES;
        }
    }
    if (!touch) return 0;
    CGGlyph *g = malloc(sizeof(CGGlyph) * n);
    NSGlyphProperty *p = malloc(sizeof(NSGlyphProperty) * n);
    memcpy(g, glyphs, sizeof(CGGlyph) * n);
    memcpy(p, props, sizeof(NSGlyphProperty) * n);
    CGGlyph bulletGlyph = 0;
    UniChar bullet = 0x2022;
    CTFontGetGlyphsForCharacters((__bridge CTFontRef)aFont, &bullet, &bulletGlyph, 1);
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger ci = charIndexes[i];
        if ([self isHiddenChar:ci]) { p[i] = NSGlyphPropertyNull; continue; }
        if (ci < s.length && bulletGlyph) {
            unichar c = [s characterAtIndex:ci];
            if ((c == '-' || c == '*' || c == '+') && [ts attribute:QBulletAttr atIndex:ci effectiveRange:NULL]) g[i] = bulletGlyph;
        }
    }
    [lm setGlyphs:g properties:p characterIndexes:charIndexes font:aFont forGlyphRange:glyphRange];
    free(g); free(p);
    return n;
}

- (NSControlCharacterAction)layoutManager:(NSLayoutManager *)lm shouldUseAction:(NSControlCharacterAction)action forControlCharacterAtIndex:(NSUInteger)ci {
    if ([self isHiddenChar:ci]) return NSControlCharacterActionZeroAdvancement;
    return action;
}

- (void)saveFolds {
    if (!self.path) return;
    NSMutableDictionary *d = [[Defaults() dictionaryForKey:kFolds] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *rel = [gApp.vault rel:self.path];
    // Only keep keys that still exist in this note.
    NSMutableSet *live = [NSMutableSet set];
    for (QHeading *h in self.headings) [live addObject:h.key];
    [self.folded intersectSet:live];
    if (self.folded.count) d[rel] = self.folded.allObjects; else [d removeObjectForKey:rel];
    [Defaults() setObject:d forKey:kFolds];
}

- (void)setFold:(BOOL)fold forHeading:(QHeading *)h {
    if (fold && h.hide.length) [self.folded addObject:h.key];
    else [self.folded removeObject:h.key];
}

- (void)afterFoldChange {
    [self refreshStructureInvalidating:NO];
    // Keep the caret visible.
    NSRange sel = self.textView.selectedRange;
    if ([self isHiddenChar:sel.location]) {
        for (QHeading *h in self.headings)
            if (NSLocationInRange(sel.location, h.hide) && [self.folded containsObject:h.key]) { self.textView.selectedRange = NSMakeRange(NSMaxRange(h.line), 0); break; }
    }
    [self saveFolds];
    self.textView.needsDisplay = YES;
}

- (void)toggleFoldAtHeading:(NSInteger)i {
    if (i < 0 || (NSUInteger)i >= self.headings.count) return;
    QHeading *h = self.headings[(NSUInteger)i];
    [self setFold:![self.folded containsObject:h.key] forHeading:h];
    [self afterFoldChange];
}

- (QHeading *)headingAtCaret {
    NSUInteger loc = self.textView.selectedRange.location;
    QHeading *best = nil;
    for (QHeading *h in self.headings) {
        if (NSLocationInRange(loc, h.line) || loc == NSMaxRange(h.line)) return h;
        if (h.line.location <= loc && NSLocationInRange(loc, NSMakeRange(h.line.location, NSMaxRange(h.hide) - h.line.location + 1))) best = h;
    }
    return best;
}

- (void)foldHere:(BOOL)fold {
    QHeading *h = [self headingAtCaret];
    if (!h) { NSBeep(); return; }
    [self setFold:fold forHeading:h];
    if (fold) self.textView.selectedRange = NSMakeRange(NSMaxRange(h.line), 0);
    [self afterFoldChange];
}

- (void)foldAll:(BOOL)fold {
    if (!fold) [self.folded removeAllObjects];
    else for (QHeading *h in self.headings) [self setFold:YES forHeading:h];
    [self afterFoldChange];
}

#pragma mark Text view delegate

- (BOOL)textView:(NSTextView *)tv shouldChangeTextInRange:(NSRange)r replacementString:(NSString *)rep {
    // Typing Return at the end of a folded heading opens it first, so the new line isn't swallowed by the fold.
    // So does any edit at the newline that ends a folded block, so nothing typed lands out of sight.
    BOOL changed = NO;
    for (QHeading *h in self.headings) {
        if (![self.folded containsObject:h.key] || !h.hide.length) continue;
        BOOL newlineAtHeading = rep && [rep containsString:@"\n"] && r.location == NSMaxRange(h.line);
        if (newlineAtHeading || r.location == NSMaxRange(h.hide)) { [self.folded removeObject:h.key]; changed = YES; }
    }
    if (changed) [self afterFoldChange];
    return YES;
}

- (void)textViewDidChangeSelection:(NSNotification *)n {
    NSRange sel = self.textView.selectedRange;
    if (!self.hidden.count) return;
    BOOL changed = NO;
    for (QHeading *h in self.headings) {
        if (![self.folded containsObject:h.key]) continue;
        NSRange hide = h.hide;
        BOOL inside = (sel.location > hide.location && sel.location < NSMaxRange(hide)) ||
                      (sel.length && NSIntersectionRange(sel, hide).length && sel.location > hide.location);
        if (inside) { [self.folded removeObject:h.key]; changed = YES; }
    }
    if (changed) dispatch_async(dispatch_get_main_queue(), ^{ [self afterFoldChange]; });
}

- (NSArray<NSString *> *)textView:(NSTextView *)tv completions:(NSArray<NSString *> *)words forPartialWordRange:(NSRange)r indexOfSelectedItem:(NSInteger *)i {
    return @[];
}

#pragma mark Title (rename)

- (void)focusTitle {
    [self.view.window makeFirstResponder:self.textView.titleField];
    [self.textView.titleField.currentEditor selectAll:nil];
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (c == self.textView.titleField && (sel == @selector(insertNewline:) || sel == @selector(moveDown:) || sel == @selector(insertTab:))) {
        [self.view.window makeFirstResponder:self.textView];
        self.textView.selectedRange = NSMakeRange(0, 0);
        return YES;
    }
    if (c == self.textView.titleField && sel == @selector(cancelOperation:)) {
        self.textView.titleField.stringValue = [self.path.lastPathComponent stringByDeletingPathExtension];
        [self.view.window makeFirstResponder:self.textView];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    if (n.object != self.textView.titleField || !self.path) return;
    NSString *name = SafeName(self.textView.titleField.stringValue);
    NSString *old = [self.path.lastPathComponent stringByDeletingPathExtension];
    if ([name isEqualToString:old]) { self.textView.titleField.stringValue = old; return; }
    [self saveNow];
    NSString *dir = self.path.stringByDeletingLastPathComponent;
    NSString *ext = self.path.pathExtension;
    NSString *dest = [[dir stringByAppendingPathComponent:name] stringByAppendingPathExtension:ext];
    BOOL caseOnly = [dest.lowercaseString isEqualToString:self.path.lowercaseString];
    if (!caseOnly && [NSFileManager.defaultManager fileExistsAtPath:dest]) {
        self.textView.titleField.stringValue = old;
        self.status.stringValue = [NSString stringWithFormat:@"A note called \"%@\" already exists here.", name];
        return;
    }
    NSError *err = nil;
    if (![NSFileManager.defaultManager moveItemAtPath:self.path toPath:dest error:&err]) {
        self.textView.titleField.stringValue = old;
        self.status.stringValue = @"Couldn't rename this note.";
        return;
    }
    NSString *from = self.path;
    [self pathMoved:from to:dest];
    [gApp rescanNow];
}

#pragma mark Links, tags, tasks

- (void)openLink:(NSString *)target {
    QNode *n = [gApp.vault resolve:target];
    NSString *heading = nil;
    NSRange hash = [target rangeOfString:@"#"];
    if (hash.location != NSNotFound) heading = Trim([target substringFromIndex:hash.location + 1]);
    if (n) {
        [self openPath:n.path];
    } else {
        NSString *name = target;
        NSRange cut = [name rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"|#^"]];
        if (cut.location != NSNotFound) name = [name substringToIndex:cut.location];
        if (!Trim(name).length) {   // [[#Heading]] in this note
            if (heading.length) [self jumpToHeading:heading];
            return;
        }
        NSString *path = [gApp createNoteIn:gApp.vault.root name:SafeName(name.lastPathComponent)];
        if (path) [self openPath:path];
        return;
    }
    if (heading.length) [self jumpToHeading:heading];
}

- (void)jumpToHeading:(NSString *)text {
    NSString *want = text.lowercaseString;
    for (QHeading *h in self.headings) {
        NSString *line = [self.textView.string substringWithRange:h.line];
        NSString *t = Trim([line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]]).lowercaseString;
        if ([t isEqualToString:want]) {
            self.textView.selectedRange = NSMakeRange(NSMaxRange(h.line), 0);
            [self.textView scrollRangeToVisible:h.line];
            return;
        }
    }
}

- (void)openURL:(NSString *)url {
    NSURL *u = [NSURL URLWithString:url];
    if (u) [NSWorkspace.sharedWorkspace openURL:u];
}

- (void)searchTag:(NSString *)tag { [gApp.sidebar showSearch:[@"#" stringByAppendingString:tag]]; }

- (void)toggleTaskAt:(NSRange)r {
    NSString *s = self.textView.string;
    if (NSMaxRange(r) > s.length || r.length < 3) return;
    NSRange tick = NSMakeRange(r.location + 1, 1);
    NSString *cur = [s substringWithRange:tick];
    NSString *next = [cur isEqualToString:@" "] ? @"x" : @" ";
    NSRange sel = self.textView.selectedRange;
    if ([self.textView shouldChangeTextInRange:tick replacementString:next]) {
        [self.textView.textStorage replaceCharactersInRange:tick withString:next];
        [self.textView didChangeText];
        self.textView.selectedRange = sel;
    }
}

- (void)selectQuery:(NSString *)query {
    if (!query.length || [self isCanvasPath:self.path]) return;
    NSString *q = [query hasPrefix:@"#"] ? query : [[Trim(query) componentsSeparatedByString:@" "] firstObject];
    NSRange r = [self.textView.string rangeOfString:q options:NSCaseInsensitiveSearch];
    if (r.location == NSNotFound) return;
    if ([self isHiddenChar:r.location]) {
        for (QHeading *h in self.headings) if (NSLocationInRange(r.location, h.hide)) [self.folded removeObject:h.key];
        [self afterFoldChange];
    }
    self.textView.selectedRange = r;
    [self.textView scrollRangeToVisible:r];
    [self.textView showFindIndicatorForRange:r];
}

#pragma mark History

- (void)goBack {
    while (self.back.count) {
        NSString *p = self.back.lastObject;
        [self.back removeLastObject];
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
        if (self.path) [self.forward addObject:self.path];
        [self openPath:p history:NO];
        return;
    }
    NSBeep();
}

- (void)goForward {
    while (self.forward.count) {
        NSString *p = self.forward.lastObject;
        [self.forward removeLastObject];
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
        if (self.path) [self.back addObject:self.path];
        [self openPath:p history:NO];
        return;
    }
    NSBeep();
}

@end

#pragma mark - Sidebar rows

@interface QRowView : NSTableRowView
@property NSInteger level;
@property BOOL current, hover;
@property CGFloat guideBase, indent;
@end

@implementation QRowView
- (void)drawBackgroundInRect:(NSRect)r {
    [qSide setFill];
    NSRectFill(r);
    NSRect box = NSInsetRect(self.bounds, 8, 1);
    if (self.current) RoundRect(box, 6, qSideSel);
    else if (self.hover) RoundRect(box, 6, qSideHover);
    if (self.level > 0 && self.indent > 0) {
        [Hex(0x2a2a2a) setFill];
        for (NSInteger k = 0; k < self.level; k++) {
            CGFloat x = round(self.guideBase + k * self.indent);
            NSRectFill(NSMakeRect(x, 0, 1, NSHeight(self.bounds)));
        }
    }
}
- (void)drawSelectionInRect:(NSRect)r {}
- (BOOL)isEmphasized { return NO; }
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *ta in self.trackingAreas.copy) [self removeTrackingArea:ta];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent *)e { self.hover = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent *)e { self.hover = NO; self.needsDisplay = YES; }
@end

@interface QTreeCell : NSTableCellView
@property (strong) NSTextField *badge;
@end
@implementation QTreeCell
- (void)resizeSubviewsWithOldSize:(NSSize)old { [self place]; }
- (void)layout { [super layout]; [self place]; }
- (void)place {
    NSRect b = self.bounds;
    CGFloat bw = self.badge.hidden ? 0 : 58;
    self.textField.frame = NSMakeRect(2, round((NSHeight(b) - 17) / 2), NSWidth(b) - 4 - bw - 6, 17);
    self.badge.frame = NSMakeRect(NSWidth(b) - bw - 6, round((NSHeight(b) - 13) / 2), bw, 13);
}
@end

@interface QResult : NSObject
@property (strong) QNode *node;
@property (copy) NSString *snippet, *tag;
@property NSInteger count, score;
@end
@implementation QResult
@end

@interface QResultCell : NSTableCellView
@property (strong) NSTextField *title, *detail, *count;
@end
@implementation QResultCell
- (void)resizeSubviewsWithOldSize:(NSSize)old { [self place]; }
- (void)layout { [super layout]; [self place]; }
- (void)place {
    NSRect b = self.bounds;
    if (self.detail.hidden) {
        self.title.frame = NSMakeRect(14, round((NSHeight(b) - 17) / 2), NSWidth(b) - 70, 17);
        self.count.frame = NSMakeRect(NSWidth(b) - 56, round((NSHeight(b) - 15) / 2), 40, 15);
    } else {
        self.title.frame = NSMakeRect(14, NSHeight(b) - 25, NSWidth(b) - 28, 17);
        CGFloat dh = MIN(32, NSHeight(b) - 31);
        self.detail.frame = NSMakeRect(14, NSHeight(b) - 27 - dh, NSWidth(b) - 28, dh);
    }
}
@end

#pragma mark - Sidebar

@interface QSidebar ()
@property (strong) QIconButton *filesTab, *searchTab, *hideButton, *noteButton, *folderButton, *sortButton, *collapseButton;
@property (strong) NSView *filesPane, *searchPane;
@property (strong) NSOutlineView *outline;
@property (strong) NSScrollView *outlineScroll, *resultScroll;
@property (strong) NSSearchField *searchField;
@property (strong) NSTableView *results;
@property (strong) NSArray<QResult *> *items;
@property (strong) NSButton *vaultButton;
@property (strong) QIconButton *gearButton;
@property (strong) NSTextField *searchNote;
@property NSUInteger searchGen;
@property (strong) QNode *menuNode;
@property (copy) NSString *renamingPath;
@property BOOL showingTags;
@end

@implementation QSidebar

- (BOOL)isFlipped { return YES; }

- (instancetype)initWithFrame:(NSRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = qSide.CGColor;

    self.filesTab = [QIconButton symbol:@"folder" size:14 tip:@"Files" target:self action:@selector(showFiles)];
    self.searchTab = [QIconButton symbol:@"magnifyingglass" size:14 tip:@"Search (⇧⌘F)" target:self action:@selector(searchClicked)];
    self.hideButton = [QIconButton symbol:@"sidebar.left" size:14 tip:@"Hide sidebar (⌘\\)" target:nil action:@selector(toggleSidebar:)];
    for (NSView *b in @[self.filesTab, self.searchTab, self.hideButton]) [self addSubview:b];

    // Files pane
    self.filesPane = [[QFlip alloc] initWithFrame:NSZeroRect];
    self.noteButton = [QIconButton symbol:@"square.and.pencil" size:14 tip:@"New note (⌘N)" target:self action:@selector(newNote)];
    self.folderButton = [QIconButton symbol:@"folder.badge.plus" size:14 tip:@"New folder (⇧⌘N)" target:self action:@selector(newFolder)];
    self.sortButton = [QIconButton symbol:@"arrow.up.arrow.down" size:13 tip:@"Sort" target:self action:@selector(sortMenu:)];
    self.collapseButton = [QIconButton symbol:@"arrow.down.right.and.arrow.up.left" size:13 tip:@"Collapse all" target:self action:@selector(collapseAll)];
    for (NSView *b in @[self.noteButton, self.folderButton, self.sortButton, self.collapseButton]) [self.filesPane addSubview:b];

    NSOutlineView *ov = [[NSOutlineView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"name"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [ov addTableColumn:col];
    ov.outlineTableColumn = col;
    ov.headerView = nil;
    ov.style = NSTableViewStylePlain;
    ov.backgroundColor = qSide;
    ov.rowHeight = 27;
    ov.indentationPerLevel = 16;
    ov.intercellSpacing = NSMakeSize(0, 0);
    ov.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    ov.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    ov.focusRingType = NSFocusRingTypeNone;
    ov.autosaveExpandedItems = NO;
    ov.autoresizesOutlineColumn = NO;
    ov.dataSource = self; ov.delegate = self;
    ov.target = self; ov.action = @selector(rowClicked:);
    [ov registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
    [ov setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
    menu.delegate = self;
    ov.menu = menu;
    self.outline = ov;
    NSScrollView *os = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    os.documentView = ov;
    os.hasVerticalScroller = YES; os.autohidesScrollers = YES; os.scrollerStyle = NSScrollerStyleOverlay;
    os.drawsBackground = YES; os.backgroundColor = qSide; os.borderType = NSNoBorder;
    os.contentInsets = NSEdgeInsetsMake(2, 0, 10, 0);
    os.automaticallyAdjustsContentInsets = NO;
    self.outlineScroll = os;
    [self.filesPane addSubview:os];
    [self addSubview:self.filesPane];

    // Search pane
    self.searchPane = [[QFlip alloc] initWithFrame:NSZeroRect];
    NSSearchField *sf = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    sf.placeholderString = @"Search notes, or #tag";
    sf.font = UIFont(13, NSFontWeightRegular);
    sf.delegate = self;
    sf.focusRingType = NSFocusRingTypeNone;
    sf.sendsSearchStringImmediately = NO;
    self.searchField = sf;
    [self.searchPane addSubview:sf];
    self.searchNote = Label(@"", UIFont(11.5, NSFontWeightRegular), qFaint);
    [self.searchPane addSubview:self.searchNote];
    NSTableView *tv = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"r"];
    c2.resizingMask = NSTableColumnAutoresizingMask;
    [tv addTableColumn:c2];
    tv.headerView = nil;
    tv.style = NSTableViewStylePlain;
    tv.backgroundColor = qSide;
    tv.intercellSpacing = NSMakeSize(0, 0);
    tv.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    tv.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    tv.focusRingType = NSFocusRingTypeNone;
    tv.dataSource = self; tv.delegate = self;
    tv.target = self; tv.action = @selector(resultClicked:);
    self.results = tv;
    NSScrollView *rs = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    rs.documentView = tv;
    rs.hasVerticalScroller = YES; rs.autohidesScrollers = YES; rs.scrollerStyle = NSScrollerStyleOverlay;
    rs.drawsBackground = YES; rs.backgroundColor = qSide; rs.borderType = NSNoBorder;
    self.resultScroll = rs;
    [self.searchPane addSubview:rs];
    self.searchPane.hidden = YES;
    [self addSubview:self.searchPane];

    // Footer
    NSButton *vb = [NSButton buttonWithTitle:@"" target:self action:@selector(vaultMenu:)];
    vb.bordered = NO;
    vb.image = Symbol(@"chevron.up.chevron.down", 11, NSFontWeightRegular);
    vb.imagePosition = NSImageLeft;
    vb.imageHugsTitle = YES;
    vb.contentTintColor = qMuted;
    vb.alignment = NSTextAlignmentLeft;
    self.vaultButton = vb;
    [self addSubview:vb];
    self.gearButton = [QIconButton symbol:@"gearshape" size:14 tip:@"Settings (⌘,)" target:nil action:@selector(showSettings:)];
    [self addSubview:self.gearButton];

    self.filesTab.active = YES;
    [self refreshFooter];
    [self place];
    return self;
}

- (void)refreshFooter {
    NSString *name = gApp.vault.name ?: @"No vault";
    self.vaultButton.attributedTitle = [[NSAttributedString alloc] initWithString:[@"  " stringByAppendingString:name]
        attributes:@{NSFontAttributeName: UIFont(13, NSFontWeightMedium), NSForegroundColorAttributeName: qBody2}];
}

- (void)resizeSubviewsWithOldSize:(NSSize)old { [self place]; }
- (void)layout { [super layout]; [self place]; }
- (void)place {
    NSRect b = self.bounds;
    CGFloat W = NSWidth(b), H = NSHeight(b);
    // Header row sits beside the window's traffic lights.
    CGFloat hx = 84;
    self.filesTab.frame = NSMakeRect(hx, 1, 30, 26);
    self.searchTab.frame = NSMakeRect(hx + 34, 1, 30, 26);
    self.hideButton.frame = NSMakeRect(hx + 68, 1, 30, 26);
    CGFloat top = 36, footer = 44;
    NSRect pane = NSMakeRect(0, top, W, H - top - footer);
    self.filesPane.frame = pane;
    self.searchPane.frame = pane;
    // Files toolbar, centred.
    NSArray *tools = @[self.noteButton, self.folderButton, self.sortButton, self.collapseButton];
    CGFloat tw = tools.count * 34 - 4, tx = round((W - tw) / 2);
    for (NSView *t in tools) { t.frame = NSMakeRect(tx, 4, 30, 26); tx += 34; }
    self.outlineScroll.frame = NSMakeRect(0, 38, W, NSHeight(pane) - 38);
    [self.outline sizeLastColumnToFit];
    self.searchField.frame = NSMakeRect(12, 4, W - 24, 26);
    self.searchNote.frame = NSMakeRect(16, 36, W - 32, 15);
    self.resultScroll.frame = NSMakeRect(0, 56, W, NSHeight(pane) - 56);
    [self.results sizeLastColumnToFit];
    self.vaultButton.frame = NSMakeRect(14, H - footer + 9, W - 70, 26);
    self.gearButton.frame = NSMakeRect(W - 44, H - footer + 9, 30, 26);
}

- (void)drawRect:(NSRect)r {
    [qSide setFill];
    NSRectFill(r);
    [Hex(0x1f1f1f) setFill];
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 44, NSWidth(self.bounds), 1));
}

#pragma mark Tabs

- (void)showFiles {
    self.filesPane.hidden = NO; self.searchPane.hidden = YES;
    self.filesTab.active = YES; self.searchTab.active = NO;
}

- (void)searchClicked { [self showSearch:nil]; }

- (void)showSearch:(NSString *)query {
    if (gApp.sidebarHidden) [gApp toggleSidebar:nil];
    self.filesPane.hidden = YES; self.searchPane.hidden = NO;
    self.filesTab.active = NO; self.searchTab.active = YES;
    if (query) self.searchField.stringValue = query;
    [self.window makeFirstResponder:self.searchField];
    [self runSearch];
}

#pragma mark Tree data

- (NSArray<QNode *> *)kids:(QNode *)n { return (n ?: gApp.vault.tree).children ?: @[]; }

- (NSInteger)outlineView:(NSOutlineView *)ov numberOfChildrenOfItem:(id)item { return (NSInteger)[self kids:item].count; }
- (id)outlineView:(NSOutlineView *)ov child:(NSInteger)i ofItem:(id)item { return [self kids:item][(NSUInteger)i]; }
- (BOOL)outlineView:(NSOutlineView *)ov isItemExpandable:(QNode *)item { return item.isDir; }

- (NSView *)outlineView:(NSOutlineView *)ov viewForTableColumn:(NSTableColumn *)col item:(QNode *)n {
    QTreeCell *c = [ov makeViewWithIdentifier:@"cell" owner:self];
    if (!c) {
        c = [[QTreeCell alloc] initWithFrame:NSMakeRect(0, 0, 200, 27)];
        c.identifier = @"cell";
        NSTextField *t = Label(@"", UIFont(13.5, NSFontWeightRegular), qBody2);
        t.delegate = self;
        c.textField = t;
        [c addSubview:t];
        NSTextField *badge = Label(@"CANVAS", UIFont(9.5, NSFontWeightMedium), qFaint);
        badge.alignment = NSTextAlignmentRight;
        NSMutableAttributedString *bt = [[NSMutableAttributedString alloc] initWithString:@"CANVAS"
            attributes:@{NSFontAttributeName: UIFont(9.5, NSFontWeightMedium), NSForegroundColorAttributeName: qFaint, NSKernAttributeName: @1.0}];
        badge.attributedStringValue = bt;
        c.badge = badge;
        [c addSubview:badge];
    }
    BOOL current = !n.isDir && [n.path isEqualToString:gApp.editor.path];
    c.textField.stringValue = n.name ?: @"";
    c.textField.textColor = current ? qHead : (n.isDir ? qFolder : qBody2);
    c.textField.editable = NO;
    c.badge.hidden = ![n.ext isEqualToString:@"canvas"];
    c.needsLayout = YES;
    return c;
}

- (NSTableRowView *)outlineView:(NSOutlineView *)ov rowViewForItem:(QNode *)n {
    QRowView *rv = [QRowView new];
    rv.level = [ov levelForItem:n];
    rv.current = !n.isDir && [n.path isEqualToString:gApp.editor.path];
    rv.indent = ov.indentationPerLevel;
    rv.guideBase = [self guideBase];
    return rv;
}

// x of a top-level folder's disclosure chevron; nested guides line up under each parent's chevron.
- (CGFloat)guideBase {
    for (NSInteger r = 0; r < self.outline.numberOfRows; r++) {
        QNode *n = [self.outline itemAtRow:r];
        if (n.isDir) {
            NSRect oc = [self.outline frameOfOutlineCellAtRow:r];
            if (!NSIsEmptyRect(oc)) return NSMidX(oc) - [self.outline levelForRow:r] * self.outline.indentationPerLevel;
        }
    }
    return 14;
}

- (void)outlineViewItemDidExpand:(NSNotification *)n { [self saveExpanded]; }
- (void)outlineViewItemDidCollapse:(NSNotification *)n { [self saveExpanded]; }

- (void)saveExpanded {
    NSMutableArray *rels = [NSMutableArray array];
    for (NSInteger r = 0; r < self.outline.numberOfRows; r++) {
        QNode *n = [self.outline itemAtRow:r];
        if (n.isDir && [self.outline isItemExpanded:n]) [rels addObject:n.rel];
    }
    [Defaults() setObject:rels forKey:kExpanded];
}

- (void)expandSaved:(QNode *)parent set:(NSSet *)open {
    for (QNode *c in [self kids:parent]) {
        if (c.isDir && [open containsObject:c.rel]) {
            [self.outline expandItem:c];
            [self expandSaved:c set:open];
        }
    }
}

- (void)reload {
    NSPoint scroll = self.outlineScroll.contentView.bounds.origin;
    [self.outline reloadData];
    [self expandSaved:nil set:[NSSet setWithArray:[Defaults() arrayForKey:kExpanded] ?: @[]]];
    [self.outlineScroll.contentView scrollToPoint:scroll];
    [self.outlineScroll reflectScrolledClipView:self.outlineScroll.contentView];
    [self refreshFooter];
    if (!self.searchPane.hidden) [self runSearch];
}

- (void)revealPath:(NSString *)path {
    QNode *n = [gApp.vault nodeForPath:path];
    if (!n) { [self.outline reloadData]; return; }
    NSMutableArray *chain = [NSMutableArray array];
    for (QNode *p = n.parent; p && p.parent; p = p.parent) [chain insertObject:p atIndex:0];
    for (QNode *p in chain) [self.outline expandItem:p];
    [self.outline reloadData];
    [self expandSaved:nil set:[NSSet setWithArray:[Defaults() arrayForKey:kExpanded] ?: @[]]];
    for (QNode *p in chain) [self.outline expandItem:p];
    NSInteger row = [self.outline rowForItem:n];
    if (row >= 0) [self.outline scrollRowToVisible:row];
}

- (void)rowClicked:(id)sender {
    NSInteger row = self.outline.clickedRow;
    if (row < 0) return;
    QNode *n = [self.outline itemAtRow:row];
    NSPoint p = [self.outline convertPoint:NSApp.currentEvent.locationInWindow fromView:nil];
    if (n.isDir && NSPointInRect(p, NSInsetRect([self.outline frameOfOutlineCellAtRow:row], -2, -2))) return;
    if (n.isDir) {
        if ([self.outline isItemExpanded:n]) [self.outline.animator collapseItem:n];
        else [self.outline.animator expandItem:n];
    } else {
        [gApp.editor openPath:n.path];
    }
}

#pragma mark Toolbar actions

- (NSString *)targetDir {
    QNode *n = self.menuNode;
    if (n) return n.isDir ? n.path : n.path.stringByDeletingLastPathComponent;
    return [gApp defaultNoteDir];
}

- (void)newNote {
    if (!gApp.vault) { [gApp chooseVault]; return; }
    NSString *p = [gApp createNoteIn:[self targetDir] name:@"Untitled"];
    self.menuNode = nil;
    if (!p) return;
    [gApp.editor openPath:p];
    [gApp.editor focusTitle];
}

- (void)newFolder {
    if (!gApp.vault) { [gApp chooseVault]; return; }
    NSString *dir = [self targetDir];
    self.menuNode = nil;
    NSString *p = FreePath(dir, @"Untitled folder", @"");
    if (![NSFileManager.defaultManager createDirectoryAtPath:p withIntermediateDirectories:NO attributes:nil error:nil]) { NSBeep(); return; }
    [gApp rescanNow];
    [self showFiles];
    [self revealPath:p];
    [self beginRename:[gApp.vault nodeForPath:p]];
}

- (void)sortMenu:(NSButton *)b {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSArray *names = @[@"File name (A to Z)", @"File name (Z to A)", @"Modified time (new to old)", @"Modified time (old to new)",
                       @"Created time (new to old)", @"Created time (old to new)"];
    NSInteger cur = [Defaults() integerForKey:kSortMode];
    for (NSUInteger i = 0; i < names.count; i++) {
        NSMenuItem *it = [m addItemWithTitle:names[i] action:@selector(pickSort:) keyEquivalent:@""];
        it.target = self; it.tag = (NSInteger)i;
        it.state = (NSInteger)i == cur ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(b.bounds) + 4) inView:b];
}

- (void)pickSort:(NSMenuItem *)it {
    [Defaults() setInteger:it.tag forKey:kSortMode];
    [gApp rescanNow];
}

- (void)collapseAll {
    [self.outline collapseItem:nil collapseChildren:YES];
    [Defaults() setObject:@[] forKey:kExpanded];
}

- (void)vaultMenu:(NSButton *)b {
    NSMenu *m = [[NSMenu alloc] initWithTitle:@""];
    NSMenuItem *a = [m addItemWithTitle:@"Open another vault…" action:@selector(chooseVault) keyEquivalent:@""];
    a.target = gApp;
    if (gApp.vault) {
        NSMenuItem *r = [m addItemWithTitle:@"Show vault in Finder" action:@selector(revealVault) keyEquivalent:@""];
        r.target = self;
    }
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:b];
}

- (void)revealVault {
    if (gApp.vault) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:gApp.vault.root]]];
}

#pragma mark Context menu

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger row = self.outline.clickedRow;
    self.menuNode = row >= 0 ? [self.outline itemAtRow:row] : nil;
    QNode *n = self.menuNode;
    NSMenuItem *(^add)(NSString *, SEL) = ^NSMenuItem *(NSString *t, SEL s) {
        NSMenuItem *it = [menu addItemWithTitle:t action:s keyEquivalent:@""];
        it.target = self;
        return it;
    };
    add(@"New note", @selector(newNote));
    add(@"New folder", @selector(newFolder));
    if (!n) return;
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Rename", @selector(renameClicked));
    add(@"Show in Finder", @selector(revealClicked));
    [menu addItem:NSMenuItem.separatorItem];
    add(@"Move to Trash", @selector(trashClicked));
}

- (void)menuDidClose:(NSMenu *)menu {
    // Actions run after the menu closes; clear the remembered row a moment later.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ self.menuNode = nil; });
}

- (void)revealClicked {
    if (self.menuNode) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.menuNode.path]]];
}

- (void)trashClicked {
    QNode *n = self.menuNode;
    if (!n) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Move \"%@\" to the Trash?", n.name];
    a.informativeText = n.isDir ? @"The folder and everything in it goes to the Trash. You can put it back from there." : @"You can put it back from the Trash.";
    [a addButtonWithTitle:@"Move to Trash"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    NSString *path = n.path;
    BOOL wasOpen = gApp.editor.path && ([gApp.editor.path isEqualToString:path] || [gApp.editor.path hasPrefix:[path stringByAppendingString:@"/"]]);
    if (wasOpen) [gApp.editor closeNote];
    [NSWorkspace.sharedWorkspace recycleURLs:@[[NSURL fileURLWithPath:path]] completionHandler:^(NSDictionary *done, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{ [gApp rescanNow]; });
    }];
}

- (void)renameClicked { [self beginRename:self.menuNode]; }

- (void)beginRename:(QNode *)n {
    if (!n) return;
    NSInteger row = [self.outline rowForItem:n];
    if (row < 0) return;
    QTreeCell *c = [self.outline viewAtColumn:0 row:row makeIfNecessary:YES];
    if (!c) return;
    self.renamingPath = n.path;
    c.textField.editable = YES;
    c.textField.selectable = YES;
    [self.window makeFirstResponder:c.textField];
    [c.textField.currentEditor selectAll:nil];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    NSTextField *tf = note.object;
    if (tf == (id)self.searchField || !self.renamingPath) return;
    tf.editable = NO;
    NSString *path = self.renamingPath;
    self.renamingPath = nil;
    QNode *n = [gApp.vault nodeForPath:path];
    if (!n) return;
    NSString *name = SafeName(tf.stringValue);
    if ([name isEqualToString:n.name]) return;
    NSString *dest = [path.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
    if (!n.isDir) dest = [dest stringByAppendingPathExtension:path.pathExtension];
    if ([NSFileManager.defaultManager fileExistsAtPath:dest] && ![dest.lowercaseString isEqualToString:path.lowercaseString]) {
        NSBeep(); tf.stringValue = n.name; return;
    }
    [gApp.editor saveNow];
    if (![NSFileManager.defaultManager moveItemAtPath:path toPath:dest error:nil]) { NSBeep(); tf.stringValue = n.name; return; }
    [gApp.editor pathMoved:path to:dest];
    [gApp rescanNow];
}

#pragma mark Drag and drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView *)ov pasteboardWriterForItem:(QNode *)n {
    return [NSURL fileURLWithPath:n.path];
}

- (NSDragOperation)outlineView:(NSOutlineView *)ov validateDrop:(id<NSDraggingInfo>)info proposedItem:(QNode *)item proposedChildIndex:(NSInteger)i {
    QNode *target = item;
    if (target && !target.isDir) target = target.parent;
    if (target == gApp.vault.tree) target = nil;
    [ov setDropItem:target dropChildIndex:NSOutlineViewDropOnItemIndex];
    NSString *dir = target ? target.path : gApp.vault.root;
    for (NSURL *u in [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) {
        NSString *src = u.path.stringByStandardizingPath;
        if ([dir isEqualToString:src] || [dir hasPrefix:[src stringByAppendingString:@"/"]]) return NSDragOperationNone;
        if ([src.stringByDeletingLastPathComponent isEqualToString:dir]) return NSDragOperationNone;
        if (![src hasPrefix:[gApp.vault.root stringByAppendingString:@"/"]]) return NSDragOperationNone;
    }
    return NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView *)ov acceptDrop:(id<NSDraggingInfo>)info item:(QNode *)item childIndex:(NSInteger)i {
    NSString *dir = item ? item.path : gApp.vault.root;
    BOOL any = NO;
    [gApp.editor saveNow];
    for (NSURL *u in [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}]) {
        NSString *src = u.path.stringByStandardizingPath;
        NSString *dest = [dir stringByAppendingPathComponent:src.lastPathComponent];
        if ([NSFileManager.defaultManager fileExistsAtPath:dest]) continue;
        if ([NSFileManager.defaultManager moveItemAtPath:src toPath:dest error:nil]) {
            [gApp.editor pathMoved:src to:dest];
            any = YES;
        }
    }
    if (any) {
        if (item) {
            NSMutableArray *open = [[Defaults() arrayForKey:kExpanded] mutableCopy] ?: [NSMutableArray array];
            [open addObject:item.rel];
            [Defaults() setObject:open forKey:kExpanded];
        }
        [gApp rescanNow];
    }
    return any;
}

#pragma mark Search

- (void)controlTextDidChange:(NSNotification *)n {
    if (n.object == self.searchField) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runSearch) object:nil];
        [self performSelector:@selector(runSearch) withObject:nil afterDelay:0.12];
    }
}

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (c == self.searchField) {
        if (sel == @selector(insertNewline:)) { if (self.items.count) [self openResult:0]; return YES; }
        if (sel == @selector(moveDown:)) { [self.window makeFirstResponder:self.results]; [self.results selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; return YES; }
        if (sel == @selector(cancelOperation:)) {
            if (self.searchField.stringValue.length) { self.searchField.stringValue = @""; [self runSearch]; }
            else { [self showFiles]; [self.window makeFirstResponder:gApp.editor.textView]; }
            return YES;
        }
    }
    return NO;
}

- (void)runSearch {
    NSString *q = Trim(self.searchField.stringValue);
    NSArray<QNode *> *notes = gApp.vault.notes ?: @[];
    NSUInteger gen = ++self.searchGen;
    __weak QSidebar *weak = self;
    if (!q.length) {
        self.showingTags = YES;
        self.searchNote.stringValue = @"Tags";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
            NSMutableDictionary<NSString *, NSString *> *display = [NSMutableDictionary dictionary];
            for (QNode *n in notes) {
                if (![n.ext isEqualToString:@"md"]) continue;
                NSMutableSet *seen = [NSMutableSet set];
                for (NSString *t in [QIndex tagsIn:[QIndex textOf:n]]) {
                    NSString *k = t.lowercaseString;
                    if ([seen containsObject:k]) continue;
                    [seen addObject:k];
                    counts[k] = @(counts[k].integerValue + 1);
                    if (!display[k]) display[k] = t;
                }
            }
            NSMutableArray *out = [NSMutableArray array];
            for (NSString *k in counts) {
                QResult *r = [QResult new];
                r.tag = display[k]; r.count = counts[k].integerValue;
                [out addObject:r];
            }
            [out sortUsingComparator:^NSComparisonResult(QResult *a, QResult *b) {
                if (a.count != b.count) return a.count > b.count ? NSOrderedAscending : NSOrderedDescending;
                return [a.tag localizedStandardCompare:b.tag];
            }];
            dispatch_async(dispatch_get_main_queue(), ^{
                QSidebar *s = weak;
                if (!s || gen != s.searchGen) return;
                s.items = out;
                s.searchNote.stringValue = out.count ? @"Tags" : @"No tags yet. Type #something in a note.";
                [s.results reloadData];
            });
        });
        return;
    }
    self.showingTags = NO;
    BOOL tagMode = [q hasPrefix:@"#"] && q.length > 1 && ![q containsString:@" "];
    NSString *tag = tagMode ? [q substringFromIndex:1].lowercaseString : nil;
    NSArray *terms = [[q.lowercaseString componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                      filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<QResult *> *out = [NSMutableArray array];
        for (QNode *n in notes) {
            if (gen != weak.searchGen) return;
            NSString *text = [QIndex textOf:n];
            NSString *name = n.name.lowercaseString;
            NSInteger score = 0;
            NSRange first = NSMakeRange(NSNotFound, 0);
            if (tagMode) {
                BOOL hit = NO;
                for (NSString *t in [QIndex tagsIn:text]) {
                    NSString *lt = t.lowercaseString;
                    if ([lt isEqualToString:tag] || [lt hasPrefix:[tag stringByAppendingString:@"/"]]) { hit = YES; break; }
                }
                if (!hit) continue;
                first = [text rangeOfString:[@"#" stringByAppendingString:tag] options:NSCaseInsensitiveSearch];
                score = 1;
            } else {
                BOOL all = YES;
                for (NSString *t in terms) {
                    BOOL inName = [name containsString:t];
                    NSRange r = [text rangeOfString:t options:NSCaseInsensitiveSearch];
                    if (!inName && r.location == NSNotFound) { all = NO; break; }
                    if (inName) score += 50;
                    if (r.location != NSNotFound) { score += 5; if (first.location == NSNotFound) first = r; }
                }
                if (!all) continue;
            }
            QResult *r = [QResult new];
            r.node = n; r.score = score;
            if (first.location != NSNotFound) {
                NSUInteger from = first.location > 50 ? first.location - 50 : 0;
                NSUInteger to = MIN(text.length, first.location + 110);
                NSString *snip = [text substringWithRange:NSMakeRange(from, to - from)];
                snip = [[snip componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] componentsJoinedByString:@" "];
                r.snippet = [NSString stringWithFormat:@"%@%@", from > 0 ? @"…" : @"", Trim(snip)];
            } else {
                r.snippet = Pretty(n.rel);
            }
            [out addObject:r];
            if (out.count >= 300) break;
        }
        [out sortUsingComparator:^NSComparisonResult(QResult *a, QResult *b) {
            if (a.score != b.score) return a.score > b.score ? NSOrderedAscending : NSOrderedDescending;
            return [b.node.mtime ?: [NSDate distantPast] compare:a.node.mtime ?: [NSDate distantPast]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            QSidebar *s = weak;
            if (!s || gen != s.searchGen) return;
            s.items = out;
            s.searchNote.stringValue = out.count ? [NSString stringWithFormat:@"%lu note%@", (unsigned long)out.count, out.count == 1 ? @"" : @"s"]
                                                 : @"No notes match.";
            [s.results reloadData];
        });
    });
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.items.count; }

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    QResult *r = self.items[(NSUInteger)row];
    return r.tag ? 28 : 64;
}

- (NSTableRowView *)tableView:(NSTableView *)tv rowViewForRow:(NSInteger)row {
    QRowView *rv = [QRowView new];
    rv.current = tv.selectedRow == row;
    return rv;
}

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    QResultCell *c = [tv makeViewWithIdentifier:@"res" owner:self];
    if (!c) {
        c = [[QResultCell alloc] initWithFrame:NSMakeRect(0, 0, 200, 64)];
        c.identifier = @"res";
        c.title = Label(@"", UIFont(13.5, NSFontWeightMedium), qText);
        c.detail = Label(@"", UIFont(12, NSFontWeightRegular), qMuted);
        c.detail.maximumNumberOfLines = 2;
        c.detail.lineBreakMode = NSLineBreakByWordWrapping;
        c.detail.cell.truncatesLastVisibleLine = YES;
        c.count = Label(@"", UIFont(12, NSFontWeightRegular), qFaint);
        c.count.alignment = NSTextAlignmentRight;
        [c addSubview:c.title]; [c addSubview:c.detail]; [c addSubview:c.count];
    }
    QResult *r = self.items[(NSUInteger)row];
    if (r.tag) {
        c.title.stringValue = [@"#" stringByAppendingString:r.tag];
        c.title.textColor = qTag;
        c.title.font = UIFont(13, NSFontWeightRegular);
        c.count.stringValue = [NSString stringWithFormat:@"%ld", (long)r.count];
        c.detail.hidden = YES; c.count.hidden = NO;
    } else {
        c.title.stringValue = r.node.name ?: @"";
        c.title.textColor = qText;
        c.title.font = UIFont(13.5, NSFontWeightMedium);
        c.detail.stringValue = r.snippet ?: @"";
        c.detail.hidden = NO; c.count.hidden = YES;
    }
    c.needsLayout = YES;
    return c;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    [self.results enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rv, NSInteger row) {
        ((QRowView *)rv).current = (row == self.results.selectedRow);
        rv.needsDisplay = YES;
    }];
}

- (void)resultClicked:(id)sender {
    NSInteger row = self.results.clickedRow;
    if (row >= 0) [self openResult:(NSUInteger)row];
}

- (void)keyDown:(NSEvent *)e {
    if (self.window.firstResponder == self.results && (e.keyCode == 36 || e.keyCode == 76) && self.results.selectedRow >= 0) {
        [self openResult:(NSUInteger)self.results.selectedRow];
        return;
    }
    [super keyDown:e];
}

- (void)openResult:(NSUInteger)i {
    if (i >= self.items.count) return;
    QResult *r = self.items[i];
    if (r.tag) { self.searchField.stringValue = [@"#" stringByAppendingString:r.tag]; [self runSearch]; return; }
    [gApp.editor openPath:r.node.path];
    [gApp.editor selectQuery:Trim(self.searchField.stringValue)];
}

@end

#pragma mark - Canvas (Obsidian .canvas files)

static NSColor *CanvasColor(id c) {
    if (![c isKindOfClass:NSString.class] || ![c length]) return nil;
    NSString *s = c;
    if ([s hasPrefix:@"#"] && s.length == 7) {
        unsigned v = 0;
        [[NSScanner scannerWithString:[s substringFromIndex:1]] scanHexInt:&v];
        return Hex(v);
    }
    switch (s.integerValue) {
        case 1: return Hex(0xc4554d);   // red
        case 2: return Hex(0xc98a3e);   // orange
        case 3: return Hex(0xc2a94a);   // yellow
        case 4: return Hex(0x5f9a62);   // green
        case 5: return Hex(0x4d9aa1);   // cyan
        case 6: return Hex(0x8a6db5);   // purple
        default: return nil;
    }
}

static CGFloat Num(id v) { return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0; }

// Light Markdown for card text: headings, bullets, bold; markers removed.
static NSAttributedString *CardText(NSString *md, CGFloat scale, NSColor *color) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    CGFloat size = 15 * scale;
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineSpacing = 3 * scale;
    ps.paragraphSpacing = 4 * scale;
    NSArray *lines = [md componentsSeparatedByString:@"\n"];
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *line = lines[i];
        NSFont *f = UIFont(size, NSFontWeightRegular);
        NSColor *c = color;
        NSTextCheckingResult *h = [rxHeading firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (h) {
            NSInteger lv = (NSInteger)[h rangeAtIndex:1].length;
            line = [line substringFromIndex:h.range.length];
            f = UIFont(size * (lv == 1 ? 1.5 : lv == 2 ? 1.28 : 1.12), NSFontWeightSemibold);
            c = qHead;
        } else {
            NSTextCheckingResult *l = [rxList firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
            if (l) {
                BOOL task = [l rangeAtIndex:4].location != NSNotFound;
                BOOL done = task && ![[line substringWithRange:[l rangeAtIndex:5]] isEqualToString:@" "];
                NSString *indent = [line substringWithRange:[l rangeAtIndex:1]];
                line = [NSString stringWithFormat:@"%@%@ %@", indent, task ? (done ? @"☑" : @"☐") : @"•", [line substringFromIndex:l.range.length]];
            }
        }
        line = [line stringByReplacingOccurrencesOfString:@"**" withString:@""];
        line = [line stringByReplacingOccurrencesOfString:@"[[" withString:@""];
        line = [line stringByReplacingOccurrencesOfString:@"]]" withString:@""];
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:line
            attributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps}]];
        if (i + 1 < lines.count) [out appendAttributedString:[[NSAttributedString alloc] initWithString:@"\n" attributes:@{NSFontAttributeName: f}]];
    }
    return out;
}

@interface QCanvasView ()
@property (strong) NSMutableDictionary *doc;
@property (strong) NSMutableArray<NSMutableDictionary *> *nodes, *edges;
@property CGFloat scale;
@property NSPoint offset;                         // view = canvas * scale + offset
@property (strong) NSMutableDictionary *selected;
@property (strong) NSArray<NSMutableDictionary *> *dragSet;
@property (strong) NSArray<NSValue *> *dragStart;
@property NSPoint dragOrigin;
@property NSInteger mode;                         // 0 none, 1 pan, 2 move, 3 resize
@property NSSize resizeStart;
@property (strong) NSTimer *saveTimer;
@property BOOL dirty;
@property (strong) NSScrollView *editScroll;
@property (strong) NSTextView *editText;
@property (strong) NSMutableDictionary *editing;
@property (strong) NSMutableDictionary *previewCache;
@property (strong) NSDate *loadedMtime;
@property BOOL readOnly;
@end

@implementation QCanvasView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)isOpaque { return YES; }

- (NSUInteger)cardCount { return self.nodes.count; }

- (BOOL)loadPath:(NSString *)path {
    [self endEditing];
    [self saveNow];
    self.path = path;
    self.previewCache = [NSMutableDictionary dictionary];
    NSData *d = [NSData dataWithContentsOfFile:path] ?: [NSData data];
    id j = d.length ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    self.readOnly = d.length && ![j isKindOfClass:NSMutableDictionary.class];   // unreadable: show nothing, save nothing
    if (![j isKindOfClass:NSMutableDictionary.class]) j = [NSMutableDictionary dictionary];
    self.doc = j;
    if (![self.doc[@"nodes"] isKindOfClass:NSMutableArray.class]) self.doc[@"nodes"] = [NSMutableArray array];
    if (![self.doc[@"edges"] isKindOfClass:NSMutableArray.class]) self.doc[@"edges"] = [NSMutableArray array];
    self.nodes = self.doc[@"nodes"];
    self.edges = self.doc[@"edges"];
    self.selected = nil;
    self.dirty = NO;
    self.loadedMtime = ModDate(path);
    [self zoomToFit];
    return YES;
}

- (void)setFrameSize:(NSSize)s {
    BOOL first = NSIsEmptyRect(self.bounds);
    [super setFrameSize:s];
    if (first && self.nodes) [self zoomToFit];
}

- (NSRect)rectOf:(NSDictionary *)n {
    return NSMakeRect(Num(n[@"x"]), Num(n[@"y"]), MAX(20, Num(n[@"width"])), MAX(20, Num(n[@"height"])));
}
- (NSRect)toView:(NSRect)r {
    return NSMakeRect(r.origin.x * self.scale + self.offset.x, r.origin.y * self.scale + self.offset.y, r.size.width * self.scale, r.size.height * self.scale);
}
- (NSPoint)toCanvas:(NSPoint)p { return NSMakePoint((p.x - self.offset.x) / self.scale, (p.y - self.offset.y) / self.scale); }

- (void)zoomToFit {
    if (!self.nodes.count || NSIsEmptyRect(self.bounds)) { self.scale = 1; self.offset = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds)); self.needsDisplay = YES; return; }
    NSRect u = NSZeroRect;
    for (NSDictionary *n in self.nodes) u = NSIsEmptyRect(u) ? [self rectOf:n] : NSUnionRect(u, [self rectOf:n]);
    u = NSInsetRect(u, -60, -60);
    CGFloat s = MIN(1.0, MIN(NSWidth(self.bounds) / NSWidth(u), NSHeight(self.bounds) / NSHeight(u)));
    self.scale = MAX(0.1, s);
    self.offset = NSMakePoint(NSMidX(self.bounds) - NSMidX(u) * self.scale, NSMidY(self.bounds) - NSMidY(u) * self.scale);
    self.needsDisplay = YES;
}

#pragma mark Drawing

- (void)drawRect:(NSRect)dirty {
    [qDesk setFill];
    NSRectFill(dirty);
    // Dot grid in canvas space.
    CGFloat step = 20 * self.scale;
    while (step < 12) step *= 2;
    CGFloat ox = fmod(self.offset.x, step), oy = fmod(self.offset.y, step);
    if (ox < 0) ox += step;
    if (oy < 0) oy += step;
    NSMutableData *buf = [NSMutableData data];
    for (CGFloat y = oy; y < NSMaxY(dirty); y += step) {
        if (y < NSMinY(dirty) - step) continue;
        for (CGFloat x = ox; x < NSMaxX(dirty); x += step) {
            if (x < NSMinX(dirty) - step) continue;
            NSRect r = NSMakeRect(x, y, 1.2, 1.2);
            [buf appendBytes:&r length:sizeof(NSRect)];
        }
    }
    [qDot setFill];
    NSRectFillList((const NSRect *)buf.bytes, (NSInteger)(buf.length / sizeof(NSRect)));

    for (NSMutableDictionary *n in self.nodes) if ([n[@"type"] isEqual:@"group"]) [self drawGroup:n];
    for (NSMutableDictionary *e in self.edges) [self drawEdge:e];
    for (NSMutableDictionary *n in self.nodes) if (![n[@"type"] isEqual:@"group"]) [self drawCard:n];
}

- (void)drawGroup:(NSDictionary *)n {
    NSRect r = [self toView:[self rectOf:n]];
    NSColor *c = CanvasColor(n[@"color"]) ?: Hex(0x3a3a3a);
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:10 * self.scale yRadius:10 * self.scale];
    [[c colorWithAlphaComponent:0.06] setFill];
    [p fill];
    p.lineWidth = (n == self.selected) ? 2 : 1.2;
    [(n == self.selected ? qText : [c colorWithAlphaComponent:0.7]) setStroke];
    [p stroke];
    NSString *label = [n[@"label"] isKindOfClass:NSString.class] ? n[@"label"] : nil;
    if (label.length) {
        NSDictionary *a = @{NSFontAttributeName: UIFont(MAX(9, 15 * self.scale), NSFontWeightSemibold), NSForegroundColorAttributeName: qBody2};
        NSSize sz = [label sizeWithAttributes:a];
        [label drawAtPoint:NSMakePoint(NSMinX(r) + 4, NSMinY(r) - sz.height - 4) withAttributes:a];
    }
}

- (NSString *)previewFor:(NSString *)file {
    NSString *hit = self.previewCache[file];
    if (hit) return hit;
    NSString *full = [gApp.vault.root stringByAppendingPathComponent:file];
    NSString *t = @"";
    NSString *ext = file.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"md"]) {
        t = ReadText(full) ?: @"";
        NSRange fm = FrontMatter(t);
        if (fm.location != NSNotFound) t = [t substringFromIndex:NSMaxRange(fm)];
        if (t.length > 1500) t = [t substringToIndex:1500];
    }
    self.previewCache[file] = Trim(t);
    return self.previewCache[file];
}

- (void)drawCard:(NSDictionary *)n {
    NSRect r = [self toView:[self rectOf:n]];
    if (!NSIntersectsRect(NSInsetRect(r, -40, -40), self.bounds)) return;
    NSColor *accent = CanvasColor(n[@"color"]);
    CGFloat rad = 8 * self.scale;
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
    [Hex(0x1a1a1a) setFill];
    [p fill];
    if (accent) { [[accent colorWithAlphaComponent:0.08] setFill]; [p fill]; }
    p.lineWidth = (n == self.selected) ? 2 : 1;
    [(n == self.selected ? qText : (accent ?: Hex(0x2e2e2e))) setStroke];
    [p stroke];

    NSString *type = [n[@"type"] isKindOfClass:NSString.class] ? n[@"type"] : @"text";
    NSRect inner = NSInsetRect(r, 14 * self.scale, 12 * self.scale);
    if (self.scale < 0.3) {   // too small to read: draw text as bars
        [Hex(0x2c2c2c) setFill];
        for (CGFloat y = NSMinY(inner); y < MIN(NSMaxY(inner), NSMinY(inner) + 40); y += 8) NSRectFill(NSMakeRect(NSMinX(inner), y, NSWidth(inner) * 0.8, 3));
        return;
    }
    [NSGraphicsContext saveGraphicsState];
    [p addClip];
    if ([type isEqualToString:@"text"]) {
        NSString *t = [n[@"text"] isKindOfClass:NSString.class] ? n[@"text"] : @"";
        if (n != self.editing) [CardText(t, self.scale, qText) drawWithRect:inner options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
    } else if ([type isEqualToString:@"file"]) {
        NSString *file = [n[@"file"] isKindOfClass:NSString.class] ? n[@"file"] : @"";
        NSString *ext = file.pathExtension.lowercaseString;
        if ([@[@"png", @"jpg", @"jpeg", @"gif", @"webp", @"heic", @"tiff"] containsObject:ext]) {
            NSImage *im = self.previewCache[[@"img:" stringByAppendingString:file]];
            if (!im) {
                im = [[NSImage alloc] initWithContentsOfFile:[gApp.vault.root stringByAppendingPathComponent:file]];
                if (im) self.previewCache[[@"img:" stringByAppendingString:file]] = im;
            }
            if (im) {
                NSSize s = im.size;
                CGFloat k = MIN(NSWidth(r) / MAX(1, s.width), NSHeight(r) / MAX(1, s.height));
                NSRect ir = NSMakeRect(NSMidX(r) - s.width * k / 2, NSMidY(r) - s.height * k / 2, s.width * k, s.height * k);
                [im drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
            }
        } else {
            [CardText([self previewFor:file], self.scale * 0.9, qBody2) drawWithRect:inner options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine];
        }
    } else if ([type isEqualToString:@"link"]) {
        NSString *u = [n[@"url"] isKindOfClass:NSString.class] ? n[@"url"] : @"";
        NSDictionary *a = @{NSFontAttributeName: UIFont(14 * self.scale, NSFontWeightRegular), NSForegroundColorAttributeName: qLink,
                            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle), NSUnderlineColorAttributeName: qLinkLine};
        [u drawWithRect:inner options:NSStringDrawingUsesLineFragmentOrigin attributes:a];
    }
    [NSGraphicsContext restoreGraphicsState];
    if ([type isEqualToString:@"file"]) {
        NSString *file = [n[@"file"] isKindOfClass:NSString.class] ? n[@"file"] : @"";
        NSString *label = Pretty(file).lastPathComponent;
        NSDictionary *a = @{NSFontAttributeName: UIFont(MAX(9, 12.5 * self.scale), NSFontWeightMedium), NSForegroundColorAttributeName: qMuted};
        NSSize sz = [label sizeWithAttributes:a];
        [label drawAtPoint:NSMakePoint(NSMinX(r) + 2, NSMinY(r) - sz.height - 3) withAttributes:a];
    }
    if (n == self.selected) {   // resize handle
        NSRect h = NSMakeRect(NSMaxX(r) - 10, NSMaxY(r) - 10, 8, 8);
        RoundRect(h, 2, qMuted);
    }
}

- (NSPoint)anchorOf:(NSDictionary *)n side:(NSString *)side toward:(NSRect)other {
    NSRect r = [self toView:[self rectOf:n]];
    if (![side isKindOfClass:NSString.class] || !side.length) {
        CGFloat dx = NSMidX(other) - NSMidX(r), dy = NSMidY(other) - NSMidY(r);
        side = fabs(dx) * NSHeight(r) > fabs(dy) * NSWidth(r) ? (dx > 0 ? @"right" : @"left") : (dy > 0 ? @"bottom" : @"top");
    }
    if ([side isEqualToString:@"top"]) return NSMakePoint(NSMidX(r), NSMinY(r));
    if ([side isEqualToString:@"bottom"]) return NSMakePoint(NSMidX(r), NSMaxY(r));
    if ([side isEqualToString:@"left"]) return NSMakePoint(NSMinX(r), NSMidY(r));
    return NSMakePoint(NSMaxX(r), NSMidY(r));
}

static NSPoint SideNormal(NSString *side, NSPoint a, NSPoint b) {
    if ([side isEqualToString:@"top"]) return NSMakePoint(0, -1);
    if ([side isEqualToString:@"bottom"]) return NSMakePoint(0, 1);
    if ([side isEqualToString:@"left"]) return NSMakePoint(-1, 0);
    if ([side isEqualToString:@"right"]) return NSMakePoint(1, 0);
    CGFloat dx = b.x - a.x, dy = b.y - a.y, l = MAX(1, hypot(dx, dy));
    return NSMakePoint(dx / l, dy / l);
}

- (NSDictionary *)nodeWithID:(id)ident {
    for (NSDictionary *n in self.nodes) if ([n[@"id"] isEqual:ident]) return n;
    return nil;
}

- (void)drawArrowAt:(NSPoint)tip from:(NSPoint)ctrl color:(NSColor *)c {
    CGFloat ang = atan2(tip.y - ctrl.y, tip.x - ctrl.x), L = 10 * MAX(0.6, self.scale);
    NSBezierPath *h = [NSBezierPath bezierPath];
    [h moveToPoint:tip];
    [h lineToPoint:NSMakePoint(tip.x - L * cos(ang - 0.42), tip.y - L * sin(ang - 0.42))];
    [h lineToPoint:NSMakePoint(tip.x - L * cos(ang + 0.42), tip.y - L * sin(ang + 0.42))];
    [h closePath];
    [c setFill];
    [h fill];
}

- (void)drawEdge:(NSDictionary *)e {
    NSDictionary *a = [self nodeWithID:e[@"fromNode"]], *b = [self nodeWithID:e[@"toNode"]];
    if (!a || !b) return;
    NSRect ra = [self toView:[self rectOf:a]], rb = [self toView:[self rectOf:b]];
    NSPoint p0 = [self anchorOf:a side:e[@"fromSide"] toward:rb];
    NSPoint p3 = [self anchorOf:b side:e[@"toSide"] toward:ra];
    CGFloat d = MAX(40 * self.scale, hypot(p3.x - p0.x, p3.y - p0.y) * 0.35);
    NSPoint n0 = SideNormal(e[@"fromSide"], p0, p3), n3 = SideNormal(e[@"toSide"], p3, p0);
    NSPoint c1 = NSMakePoint(p0.x + n0.x * d, p0.y + n0.y * d), c2 = NSMakePoint(p3.x + n3.x * d, p3.y + n3.y * d);
    NSColor *c = CanvasColor(e[@"color"]) ?: Hex(0x6a6862);
    NSBezierPath *p = [NSBezierPath bezierPath];
    [p moveToPoint:p0];
    [p curveToPoint:p3 controlPoint1:c1 controlPoint2:c2];
    p.lineWidth = MAX(1.2, 2 * self.scale);
    [c setStroke];
    [p stroke];
    NSString *toEnd = [e[@"toEnd"] isKindOfClass:NSString.class] ? e[@"toEnd"] : @"arrow";
    NSString *fromEnd = [e[@"fromEnd"] isKindOfClass:NSString.class] ? e[@"fromEnd"] : @"none";
    if ([toEnd isEqualToString:@"arrow"]) [self drawArrowAt:p3 from:c2 color:c];
    if ([fromEnd isEqualToString:@"arrow"]) [self drawArrowAt:p0 from:c1 color:c];
    NSString *label = [e[@"label"] isKindOfClass:NSString.class] ? e[@"label"] : nil;
    if (label.length) {
        // Bezier midpoint.
        NSPoint m = NSMakePoint(0.125 * p0.x + 0.375 * c1.x + 0.375 * c2.x + 0.125 * p3.x, 0.125 * p0.y + 0.375 * c1.y + 0.375 * c2.y + 0.125 * p3.y);
        NSDictionary *at = @{NSFontAttributeName: UIFont(MAX(9, 12.5 * self.scale), NSFontWeightRegular), NSForegroundColorAttributeName: qBody2};
        NSSize sz = [label sizeWithAttributes:at];
        NSRect bg = NSMakeRect(m.x - sz.width / 2 - 6, m.y - sz.height / 2 - 3, sz.width + 12, sz.height + 6);
        RoundRect(bg, 5, qDesk);
        [label drawAtPoint:NSMakePoint(NSMinX(bg) + 6, NSMinY(bg) + 3) withAttributes:at];
    }
}

#pragma mark Interaction

- (NSMutableDictionary *)hit:(NSPoint)p {
    for (NSMutableDictionary *n in self.nodes.reverseObjectEnumerator)
        if (![n[@"type"] isEqual:@"group"] && NSPointInRect(p, [self toView:[self rectOf:n]])) return n;
    NSMutableDictionary *best = nil;
    CGFloat area = CGFLOAT_MAX;
    for (NSMutableDictionary *n in self.nodes) {
        if (![n[@"type"] isEqual:@"group"]) continue;
        NSRect r = [self toView:[self rectOf:n]];
        NSRect labelBand = NSMakeRect(NSMinX(r), NSMinY(r) - 26, NSWidth(r), 26);
        if ((NSPointInRect(p, r) || NSPointInRect(p, labelBand)) && NSWidth(r) * NSHeight(r) < area) { best = n; area = NSWidth(r) * NSHeight(r); }
    }
    return best;
}

- (void)mouseDown:(NSEvent *)e {
    [self.window makeFirstResponder:self];
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (self.editing) [self endEditing];
    NSMutableDictionary *n = [self hit:p];
    if (e.clickCount == 2) {
        if (!n) { [self addCardAt:[self toCanvas:p]]; return; }
        [self activate:n];
        return;
    }
    self.selected = n;
    self.dragOrigin = p;
    if (!n) { self.mode = 1; self.needsDisplay = YES; return; }
    NSRect r = [self toView:[self rectOf:n]];
    if (p.x > NSMaxX(r) - 14 && p.y > NSMaxY(r) - 14) {
        self.mode = 3;
        self.resizeStart = [self rectOf:n].size;
    } else {
        self.mode = 2;
        NSMutableArray *set = [NSMutableArray arrayWithObject:n];
        if ([n[@"type"] isEqual:@"group"]) {
            NSRect g = [self rectOf:n];
            for (NSMutableDictionary *o in self.nodes) if (o != n && NSContainsRect(g, [self rectOf:o])) [set addObject:o];
        }
        self.dragSet = set;
        NSMutableArray *starts = [NSMutableArray array];
        for (NSDictionary *o in set) [starts addObject:[NSValue valueWithPoint:NSMakePoint(Num(o[@"x"]), Num(o[@"y"]))]];
        self.dragStart = starts;
    }
    self.needsDisplay = YES;
}

- (void)mouseDragged:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    if (self.mode == 1) {
        self.offset = NSMakePoint(self.offset.x + e.deltaX, self.offset.y + e.deltaY);
    } else if (self.mode == 2) {
        CGFloat dx = (p.x - self.dragOrigin.x) / self.scale, dy = (p.y - self.dragOrigin.y) / self.scale;
        for (NSUInteger i = 0; i < self.dragSet.count; i++) {
            NSPoint s = self.dragStart[i].pointValue;
            self.dragSet[i][@"x"] = @(lround(s.x + dx));
            self.dragSet[i][@"y"] = @(lround(s.y + dy));
        }
        [self changed];
    } else if (self.mode == 3 && self.selected) {
        CGFloat dx = (p.x - self.dragOrigin.x) / self.scale, dy = (p.y - self.dragOrigin.y) / self.scale;
        self.selected[@"width"] = @(lround(MAX(60, self.resizeStart.width + dx)));
        self.selected[@"height"] = @(lround(MAX(40, self.resizeStart.height + dy)));
        [self changed];
    }
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)e { self.mode = 0; self.dragSet = nil; }

- (void)scrollWheel:(NSEvent *)e {
    if (self.editing) [self endEditing];
    BOOL zoom = (e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) != 0;
    if (zoom) {
        CGFloat dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.08;
        [self zoomBy:1 + dy at:[self convertPoint:e.locationInWindow fromView:nil]];
        return;
    }
    CGFloat k = e.hasPreciseScrollingDeltas ? 1 : 10;
    self.offset = NSMakePoint(self.offset.x + e.scrollingDeltaX * k, self.offset.y + e.scrollingDeltaY * k);
    self.needsDisplay = YES;
}

- (void)magnifyWithEvent:(NSEvent *)e {
    if (self.editing) [self endEditing];
    [self zoomBy:1 + e.magnification at:[self convertPoint:e.locationInWindow fromView:nil]];
}

- (void)zoomBy:(CGFloat)f at:(NSPoint)p {
    CGFloat s = MIN(3, MAX(0.08, self.scale * f));
    NSPoint c = [self toCanvas:p];
    self.scale = s;
    self.offset = NSMakePoint(p.x - c.x * s, p.y - c.y * s);
    self.needsDisplay = YES;
}

- (void)keyDown:(NSEvent *)e {
    NSString *ch = e.charactersIgnoringModifiers;
    if ((e.keyCode == 51 || e.keyCode == 117) && self.selected) {   // delete
        id ident = self.selected[@"id"];
        NSMutableArray *gone = [NSMutableArray array];
        for (NSDictionary *ed in self.edges) if ([ed[@"fromNode"] isEqual:ident] || [ed[@"toNode"] isEqual:ident]) [gone addObject:ed];
        [self.edges removeObjectsInArray:gone];
        [self.nodes removeObject:self.selected];
        self.selected = nil;
        [self changed];
        self.needsDisplay = YES;
        return;
    }
    if ((e.keyCode == 36 || e.keyCode == 76) && self.selected) { [self activate:self.selected]; return; }
    if (e.keyCode == 53) { self.selected = nil; self.needsDisplay = YES; return; }
    if ((e.modifierFlags & NSEventModifierFlagCommand) && [ch isEqualToString:@"0"]) { [self zoomToFit]; return; }
    [super keyDown:e];
}

- (void)activate:(NSMutableDictionary *)n {
    NSString *type = [n[@"type"] isKindOfClass:NSString.class] ? n[@"type"] : @"text";
    if ([type isEqualToString:@"text"]) [self beginEditing:n];
    else if ([type isEqualToString:@"file"]) {
        NSString *f = n[@"file"];
        if ([f isKindOfClass:NSString.class]) {
            NSString *full = [gApp.vault.root stringByAppendingPathComponent:f];
            NSString *ext = f.pathExtension.lowercaseString;
            if ([ext isEqualToString:@"md"] || [ext isEqualToString:@"canvas"]) [gApp.editor openPath:full];
            else [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:full]];
        }
    } else if ([type isEqualToString:@"link"]) [gApp.editor openURL:n[@"url"]];
    else if ([type isEqualToString:@"group"]) [self beginEditing:n];
}

- (void)addCardAt:(NSPoint)c {
    NSMutableString *ident = [NSMutableString string];
    for (int i = 0; i < 16; i++) [ident appendFormat:@"%x", arc4random_uniform(16)];
    NSMutableDictionary *n = [@{@"id": ident, @"type": @"text", @"text": @"", @"x": @(lround(c.x - 125)), @"y": @(lround(c.y - 30)),
                                @"width": @250, @"height": @60} mutableCopy];
    [self.nodes addObject:n];
    self.selected = n;
    [self changed];
    [self beginEditing:n];
}

#pragma mark Editing a card

- (void)beginEditing:(NSMutableDictionary *)n {
    [self endEditing];
    BOOL group = [n[@"type"] isEqual:@"group"];
    self.editing = n;
    self.selected = n;
    NSRect r = [self toView:[self rectOf:n]];
    if (group) r = NSMakeRect(NSMinX(r), NSMinY(r) - 30, MAX(160, NSWidth(r) * 0.6), 26);
    else r = NSInsetRect(r, 6 * self.scale, 4 * self.scale);
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:r];
    sv.drawsBackground = NO;
    sv.hasVerticalScroller = !group;
    sv.autohidesScrollers = YES;
    sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.borderType = NSNoBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(r), NSHeight(r))];
    tv.minSize = NSMakeSize(0, NSHeight(r));
    tv.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    tv.verticallyResizable = YES;
    tv.autoresizingMask = NSViewWidthSizable;
    tv.textContainer.widthTracksTextView = YES;
    tv.richText = NO;
    tv.drawsBackground = NO;
    tv.font = UIFont(MAX(11, (group ? 15 : 15) * self.scale), NSFontWeightRegular);
    tv.textColor = qText;
    tv.insertionPointColor = qHead;
    tv.automaticQuoteSubstitutionEnabled = NO;
    tv.allowsUndo = YES;
    tv.textContainerInset = NSMakeSize(4, 6);
    tv.string = [n[group ? @"label" : @"text"] isKindOfClass:NSString.class] ? n[group ? @"label" : @"text"] : @"";
    tv.delegate = self;
    sv.documentView = tv;
    [self addSubview:sv];
    self.editScroll = sv;
    self.editText = tv;
    [self.window makeFirstResponder:tv];
    self.needsDisplay = YES;
}

- (BOOL)textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    if (sel == @selector(cancelOperation:)) { [self endEditing]; [self.window makeFirstResponder:self]; return YES; }
    if (sel == @selector(insertNewline:) && (NSApp.currentEvent.modifierFlags & NSEventModifierFlagCommand)) {
        [self endEditing]; [self.window makeFirstResponder:self]; return YES;
    }
    if (sel == @selector(insertNewline:) && [self.editing[@"type"] isEqual:@"group"]) {
        [self endEditing]; [self.window makeFirstResponder:self]; return YES;
    }
    return NO;
}

- (void)endEditing {
    if (!self.editing) return;
    NSMutableDictionary *n = self.editing;
    BOOL group = [n[@"type"] isEqual:@"group"];
    NSString *key = group ? @"label" : @"text";
    NSString *old = [n[key] isKindOfClass:NSString.class] ? n[key] : @"";
    NSString *now = self.editText.string ?: @"";
    self.editing = nil;
    [self.editScroll removeFromSuperview];
    self.editScroll = nil;
    self.editText = nil;
    if (![old isEqualToString:now]) { n[key] = now; [self changed]; }
    self.needsDisplay = YES;
}

#pragma mark Saving

- (void)reloadIfChanged {
    if (!self.path || self.dirty || self.editing || self.mode) return;
    NSDate *m = ModDate(self.path);
    if (!m || (self.loadedMtime && [m isEqualToDate:self.loadedMtime])) return;
    CGFloat s = self.scale;
    NSPoint o = self.offset;
    NSData *d = [NSData dataWithContentsOfFile:self.path];
    id j = d.length ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingMutableContainers error:nil] : nil;
    if (![j isKindOfClass:NSMutableDictionary.class]) return;
    self.doc = j;
    if (![self.doc[@"nodes"] isKindOfClass:NSMutableArray.class]) self.doc[@"nodes"] = [NSMutableArray array];
    if (![self.doc[@"edges"] isKindOfClass:NSMutableArray.class]) self.doc[@"edges"] = [NSMutableArray array];
    self.nodes = self.doc[@"nodes"];
    self.edges = self.doc[@"edges"];
    self.selected = nil;
    self.readOnly = NO;
    self.loadedMtime = m;
    self.scale = s; self.offset = o;
    self.needsDisplay = YES;
}

- (void)changed {
    self.dirty = YES;
    [self.saveTimer invalidate];
    self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(saveNow) userInfo:nil repeats:NO];
}

- (void)saveNow {
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    if (self.editing) {
        NSMutableDictionary *n = self.editing;
        NSString *key = [n[@"type"] isEqual:@"group"] ? @"label" : @"text";
        if (self.editText && ![self.editText.string isEqualToString:n[key] ?: @""]) { n[key] = self.editText.string; self.dirty = YES; }
    }
    if (!self.dirty || !self.path || !self.doc || self.readOnly) return;
    NSData *d = [NSJSONSerialization dataWithJSONObject:self.doc options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes error:nil];
    if (d && [d writeToFile:self.path atomically:YES]) {
        self.dirty = NO;
        self.loadedMtime = ModDate(self.path);
        [QIndex forget:self.path];
    }
}

@end

#pragma mark - Quick switcher (⌘O)

static NSInteger Fuzzy(NSString *q, NSString *s) {
    if (!q.length) return 0;
    NSUInteger qi = 0, last = NSNotFound;
    NSInteger score = 0;
    for (NSUInteger i = 0; i < s.length && qi < q.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c != [q characterAtIndex:qi]) continue;
        score += (last != NSNotFound && i == last + 1) ? 8 : 1;
        if (i == 0) score += 10;
        else {
            unichar p = [s characterAtIndex:i - 1];
            if (p == ' ' || p == '/' || p == '-' || p == '_') score += 6;
        }
        last = i;
        qi++;
    }
    if (qi < q.length) return -1;
    if ([s hasPrefix:q]) score += 25;
    if ([s isEqualToString:q]) score += 40;
    return score - (NSInteger)(s.length / 12);
}

@interface QSwitcher ()
@property (strong) NSTextField *field, *hint;
@property (strong) NSTableView *table;
@property (strong) NSArray<QNode *> *matches;
@end

static QSwitcher *gSwitcher;

@implementation QSwitcher

+ (void)show {
    if (!gApp.vault) { [gApp chooseVault]; return; }
    if (!gSwitcher) gSwitcher = [[QSwitcher alloc] initWithContentRect:NSMakeRect(0, 0, 580, 392)
                                    styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    [gSwitcher present];
}

- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSWindowStyleMask)m backing:(NSBackingStoreType)b defer:(BOOL)d {
    if (!(self = [super initWithContentRect:r styleMask:m backing:b defer:d])) return nil;
    self.opaque = NO;
    self.backgroundColor = NSColor.clearColor;
    self.hasShadow = YES;
    self.releasedWhenClosed = NO;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    NSView *bg = [[NSView alloc] initWithFrame:r];
    bg.wantsLayer = YES;
    bg.layer.backgroundColor = Hex(0x1a1a1a).CGColor;
    bg.layer.cornerRadius = 12;
    bg.layer.borderWidth = 1;
    bg.layer.borderColor = Hex(0x2e2e2e).CGColor;
    bg.layer.masksToBounds = YES;
    self.contentView = bg;

    NSTextField *f = [[NSTextField alloc] initWithFrame:NSMakeRect(20, NSHeight(r) - 52, NSWidth(r) - 40, 30)];
    f.bezeled = NO; f.bordered = NO; f.drawsBackground = NO; f.focusRingType = NSFocusRingTypeNone;
    f.font = UIFont(18, NSFontWeightRegular);
    f.textColor = qHead;
    f.placeholderAttributedString = [[NSAttributedString alloc] initWithString:@"Find or create a note"
        attributes:@{NSFontAttributeName: UIFont(18, NSFontWeightRegular), NSForegroundColorAttributeName: qFaint}];
    f.delegate = self;
    f.cell.usesSingleLineMode = YES;
    f.cell.scrollable = YES;
    self.field = f;
    [bg addSubview:f];
    NSBox *line = [[NSBox alloc] initWithFrame:NSMakeRect(0, NSHeight(r) - 66, NSWidth(r), 1)];
    line.boxType = NSBoxCustom; line.borderWidth = 0; line.fillColor = Hex(0x2a2a2a);
    [bg addSubview:line];

    NSTableView *t = [[NSTableView alloc] initWithFrame:NSZeroRect];
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:@"n"];
    c.resizingMask = NSTableColumnAutoresizingMask;
    [t addTableColumn:c];
    t.headerView = nil;
    t.style = NSTableViewStylePlain;
    t.backgroundColor = Hex(0x1a1a1a);
    t.rowHeight = 46;
    t.intercellSpacing = NSMakeSize(0, 0);
    t.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    t.focusRingType = NSFocusRingTypeNone;
    t.dataSource = self; t.delegate = self;
    t.target = self; t.action = @selector(clicked:);
    self.table = t;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 34, NSWidth(r), NSHeight(r) - 104)];
    sv.documentView = t;
    sv.drawsBackground = NO; sv.hasVerticalScroller = YES; sv.autohidesScrollers = YES; sv.scrollerStyle = NSScrollerStyleOverlay;
    sv.borderType = NSNoBorder;
    [bg addSubview:sv];
    [t sizeLastColumnToFit];

    self.hint = Label(@"↑↓ to move   ↩ to open   ⇧↩ to create   esc to close", UIFont(11.5, NSFontWeightRegular), qFaint);
    self.hint.frame = NSMakeRect(20, 10, NSWidth(r) - 40, 16);
    [bg addSubview:self.hint];
    return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }

- (void)present {
    NSRect wf = gApp.window.frame;
    NSRect f = self.frame;
    f.origin.x = NSMidX(wf) - NSWidth(f) / 2;
    f.origin.y = NSMaxY(wf) - NSHeight(f) - 90;
    [self setFrame:f display:NO];
    self.field.stringValue = @"";
    [self update];
    [gApp.window addChildWindow:self ordered:NSWindowAbove];
    [self makeKeyAndOrderFront:nil];
    [self makeFirstResponder:self.field];
}

- (void)resignKeyWindow {
    [super resignKeyWindow];
    [self dismiss];
}

- (void)dismiss {
    if (!self.isVisible) return;
    [gApp.window removeChildWindow:self];
    [self orderOut:nil];
}

- (void)update {
    NSString *q = Trim(self.field.stringValue).lowercaseString;
    NSArray<QNode *> *all = gApp.vault.notes ?: @[];
    if (!q.length) {
        self.matches = [all sortedArrayUsingComparator:^NSComparisonResult(QNode *a, QNode *b) {
            return [b.mtime ?: [NSDate distantPast] compare:a.mtime ?: [NSDate distantPast]];
        }];
        if (self.matches.count > 60) self.matches = [self.matches subarrayWithRange:NSMakeRange(0, 60)];
    } else {
        NSMutableArray *scored = [NSMutableArray array];
        for (QNode *n in all) {
            NSInteger a = Fuzzy(q, n.name.lowercaseString);
            NSInteger b = Fuzzy(q, Pretty(n.rel).lowercaseString);
            NSInteger s = MAX(a >= 0 ? a + 15 : -1, b);
            if (s >= 0) [scored addObject:@[@(s), n]];
        }
        [scored sortUsingComparator:^NSComparisonResult(NSArray *x, NSArray *y) { return [y[0] compare:x[0]]; }];
        NSMutableArray *out = [NSMutableArray array];
        for (NSArray *pair in scored) { [out addObject:pair[1]]; if (out.count >= 60) break; }
        self.matches = out;
    }
    [self.table reloadData];
    if (self.matches.count) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self.table scrollRowToVisible:0];
}

- (void)controlTextDidChange:(NSNotification *)n { [self update]; }

- (BOOL)control:(NSControl *)c textView:(NSTextView *)tv doCommandBySelector:(SEL)sel {
    NSInteger row = self.table.selectedRow, count = (NSInteger)self.matches.count;
    if (sel == @selector(moveDown:) && count) { row = MIN(count - 1, row + 1); }
    else if (sel == @selector(moveUp:) && count) { row = MAX(0, row - 1); }
    else if (sel == @selector(insertNewline:)) {
        BOOL create = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) || !count;
        if (create) [self createFromQuery];
        else [self openRow:row];
        return YES;
    } else if (sel == @selector(cancelOperation:)) { [self dismiss]; return YES; }
    else return NO;
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [self.table scrollRowToVisible:row];
    return YES;
}

- (void)createFromQuery {
    NSString *name = Trim(self.field.stringValue);
    if (!name.length) return;
    NSString *dir = gApp.vault.root;
    if ([name containsString:@"/"]) {   // "Folder/Note" creates inside that folder
        dir = [dir stringByAppendingPathComponent:name.stringByDeletingLastPathComponent];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        name = name.lastPathComponent;
    } else dir = [gApp defaultNoteDir];
    NSString *p = [gApp createNoteIn:dir name:SafeName(name)];
    [self dismiss];
    if (p) [gApp.editor openPath:p];
}

- (void)openRow:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.matches.count) return;
    QNode *n = self.matches[(NSUInteger)row];
    [self dismiss];
    [gApp.editor openPath:n.path];
}

- (void)clicked:(id)s { [self openRow:self.table.clickedRow]; }

- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return (NSInteger)self.matches.count; }

- (NSTableRowView *)tableView:(NSTableView *)t rowViewForRow:(NSInteger)row {
    QRowView *rv = [QRowView new];
    rv.current = t.selectedRow == row;
    return rv;
}

- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    QResultCell *c = [t makeViewWithIdentifier:@"sw" owner:self];
    if (!c) {
        c = [[QResultCell alloc] initWithFrame:NSMakeRect(0, 0, 560, 46)];
        c.identifier = @"sw";
        c.title = Label(@"", UIFont(14, NSFontWeightMedium), qText);
        c.detail = Label(@"", UIFont(11.5, NSFontWeightRegular), qMuted);
        c.count = Label(@"", UIFont(10, NSFontWeightMedium), qFaint);
        c.count.alignment = NSTextAlignmentRight;
        [c addSubview:c.title]; [c addSubview:c.detail]; [c addSubview:c.count];
    }
    QNode *n = self.matches[(NSUInteger)row];
    c.title.stringValue = n.name ?: @"";
    NSString *folder = n.rel.stringByDeletingLastPathComponent;
    c.detail.stringValue = folder.length ? folder : @"Top of vault";
    c.detail.hidden = NO;
    c.count.hidden = YES;
    c.needsLayout = YES;
    return c;
}

- (CGFloat)tableView:(NSTableView *)t heightOfRow:(NSInteger)row { return 46; }

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    [self.table enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rv, NSInteger row) {
        ((QRowView *)rv).current = (row == self.table.selectedRow);
        rv.needsDisplay = YES;
    }];
}

@end

#pragma mark - Settings window

static QSettings *gSettings;

static NSString *PeriodicPath(NSString *fmt, NSDate *date) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_AU"];
    NSCalendar *iso = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierISO8601];
    iso.locale = f.locale;
    f.calendar = iso;
    f.dateFormat = fmt.length ? fmt : @"yyyy-MM-dd";
    NSString *rel = [f stringFromDate:date];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *p in [rel componentsSeparatedByString:@"/"]) if (Trim(p).length) [parts addObject:SafeName(p)];
    if (!parts.count) [parts addObject:@"Untitled"];
    return [[parts componentsJoinedByString:@"/"] stringByAppendingPathExtension:@"md"];
}

@interface QSettings ()
@property (strong) NSTextField *vaultLabel, *dailyField, *weeklyField, *dailyPreview, *weeklyPreview;
@property (strong) NSPopUpButton *sizePop, *widthPop, *placePop;
@end

@implementation QSettings

+ (void)show {
    if (!gSettings) gSettings = [QSettings new];
    [gSettings refresh];
    [gSettings showWindow:nil];
    [gSettings.window makeKeyAndOrderFront:nil];
}

- (instancetype)init {
    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 580, 430)
                                              styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                backing:NSBackingStoreBuffered defer:NO];
    w.title = @"Settings";
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    w.backgroundColor = qSide;
    w.releasedWhenClosed = NO;
    [w center];
    if (!(self = [super initWithWindow:w])) return nil;
    QFlip *v = [[QFlip alloc] initWithFrame:NSMakeRect(0, 0, 580, 430)];
    w.contentView = v;

    CGFloat lx = 28, cx = 168, cw = 380, y = 26;
    NSTextField *(^row)(NSString *, CGFloat) = ^NSTextField *(NSString *t, CGFloat yy) {
        NSTextField *l = Label(t, UIFont(13, NSFontWeightRegular), qBody2);
        l.frame = NSMakeRect(lx, yy + 3, cx - lx - 10, 18);
        [v addSubview:l];
        return l;
    };

    row(@"Vault", y);
    self.vaultLabel = Label(@"", UIFont(12.5, NSFontWeightRegular), qText);
    self.vaultLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    self.vaultLabel.frame = NSMakeRect(cx, y + 3, cw - 100, 18);
    [v addSubview:self.vaultLabel];
    NSButton *change = [NSButton buttonWithTitle:@"Change…" target:gApp action:@selector(chooseVault)];
    change.frame = NSMakeRect(cx + cw - 92, y - 2, 92, 28);
    [v addSubview:change];
    y += 46;

    row(@"Text size", y);
    self.sizePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx, y - 1, 120, 26) pullsDown:NO];
    for (int s = 14; s <= 22; s++) [self.sizePop addItemWithTitle:[NSString stringWithFormat:@"%d pt", s]];
    self.sizePop.target = self; self.sizePop.action = @selector(changed:);
    [v addSubview:self.sizePop];
    y += 40;

    row(@"Page width", y);
    self.widthPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx, y - 1, 160, 26) pullsDown:NO];
    [self.widthPop addItemsWithTitles:@[@"Narrow", @"Normal", @"Wide", @"Extra wide"]];
    self.widthPop.target = self; self.widthPop.action = @selector(changed:);
    [v addSubview:self.widthPop];
    y += 40;

    row(@"New notes go", y);
    self.placePop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(cx, y - 1, 240, 26) pullsDown:NO];
    [self.placePop addItemsWithTitles:@[@"Next to the open note", @"At the top of the vault"]];
    self.placePop.target = self; self.placePop.action = @selector(changed:);
    [v addSubview:self.placePop];
    y += 52;

    row(@"Daily note", y);
    self.dailyField = [[NSTextField alloc] initWithFrame:NSMakeRect(cx, y, cw, 24)];
    self.dailyField.font = Mono(12);
    self.dailyField.delegate = self;
    [v addSubview:self.dailyField];
    self.dailyPreview = Label(@"", UIFont(11.5, NSFontWeightRegular), qMuted);
    self.dailyPreview.frame = NSMakeRect(cx, y + 28, cw, 16);
    [v addSubview:self.dailyPreview];
    y += 62;

    row(@"Weekly note", y);
    self.weeklyField = [[NSTextField alloc] initWithFrame:NSMakeRect(cx, y, cw, 24)];
    self.weeklyField.font = Mono(12);
    self.weeklyField.delegate = self;
    [v addSubview:self.weeklyField];
    self.weeklyPreview = Label(@"", UIFont(11.5, NSFontWeightRegular), qMuted);
    self.weeklyPreview.frame = NSMakeRect(cx, y + 28, cw, 16);
    [v addSubview:self.weeklyPreview];
    y += 60;

    NSTextField *help = Label(@"Date letters: yyyy year, MM month number, MMMM month name, dd day, EEEE weekday, YYYY and ww for the week. "
                              @"A slash starts a folder. Words in 'single quotes' stay as written. ⌘D opens today's note, ⇧⌘D this week's.",
                              UIFont(11.5, NSFontWeightRegular), qFaint);
    help.lineBreakMode = NSLineBreakByWordWrapping;
    help.maximumNumberOfLines = 4;
    help.frame = NSMakeRect(cx, y, cw, 64);
    [v addSubview:help];
    return self;
}

- (void)refresh {
    self.vaultLabel.stringValue = gApp.vault.root ?: @"None chosen";
    NSInteger size = (NSInteger)[Defaults() doubleForKey:kFontSize];
    [self.sizePop selectItemAtIndex:MAX(0, MIN(8, size - 14))];
    double w = [Defaults() doubleForKey:kPageWidth];
    [self.widthPop selectItemAtIndex:w <= 610 ? 0 : w <= 690 ? 1 : w <= 790 ? 2 : 3];
    [self.placePop selectItemAtIndex:[Defaults() integerForKey:kNewNoteLoc] ? 1 : 0];
    self.dailyField.stringValue = [Defaults() stringForKey:kDailyFmt] ?: @"";
    self.weeklyField.stringValue = [Defaults() stringForKey:kWeeklyFmt] ?: @"";
    [self previews];
}

- (void)previews {
    self.dailyPreview.stringValue = [@"Today: " stringByAppendingString:PeriodicPath(self.dailyField.stringValue, [NSDate date])];
    self.weeklyPreview.stringValue = [@"This week: " stringByAppendingString:PeriodicPath(self.weeklyField.stringValue, [NSDate date])];
}

- (void)changed:(id)sender {
    [Defaults() setDouble:14 + self.sizePop.indexOfSelectedItem forKey:kFontSize];
    NSArray *widths = @[@600, @680, @780, @920];
    [Defaults() setObject:widths[(NSUInteger)MAX(0, self.widthPop.indexOfSelectedItem)] forKey:kPageWidth];
    [Defaults() setInteger:self.placePop.indexOfSelectedItem forKey:kNewNoteLoc];
    [gApp.editor applySettings];
}

- (void)controlTextDidChange:(NSNotification *)n {
    [Defaults() setObject:self.dailyField.stringValue forKey:kDailyFmt];
    [Defaults() setObject:self.weeklyField.stringValue forKey:kWeeklyFmt];
    [self previews];
}

@end

#pragma mark - App

@implementation QApp

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    NSApp.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [self buildMenu];

    NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 820)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
          backing:NSBackingStoreBuffered defer:NO];
    w.titlebarAppearsTransparent = YES;
    w.titleVisibility = NSWindowTitleHidden;
    w.title = @"Quire";
    w.backgroundColor = qDesk;
    w.minSize = NSMakeSize(640, 420);
    w.releasedWhenClosed = NO;
    w.delegate = self;
    w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    [w center];
    [w setFrameAutosaveName:@"QuireMain"];
    self.window = w;

    self.editor = [QEditor new];
    self.sidebar = [[QSidebar alloc] initWithFrame:NSMakeRect(0, 0, 260, 820)];
    QSplit *split = [[QSplit alloc] initWithFrame:NSMakeRect(0, 0, 1280, 820)];
    split.vertical = YES;
    split.dividerStyle = NSSplitViewDividerStyleThin;
    split.delegate = self;
    [split addSubview:self.sidebar];
    [split addSubview:self.editor.view];
    self.split = split;
    w.contentView = split;
    CGFloat sw = [Defaults() doubleForKey:kSidebarW] ?: 260;
    [split setPosition:sw ofDividerAtIndex:0];
    if ([Defaults() boolForKey:kSidebarHide]) [self toggleSidebar:nil];
    [w makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    NSString *vp = [Defaults() stringForKey:kVaultPath];
    BOOL isDir = NO;
    if (vp.length && [NSFileManager.defaultManager fileExistsAtPath:vp isDirectory:&isDir] && isDir) [self openVault:vp];
    else dispatch_async(dispatch_get_main_queue(), ^{ [self chooseVault]; });
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)app hasVisibleWindows:(BOOL)flag {
    if (!flag) [self.window makeKeyAndOrderFront:nil];
    return YES;
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self.editor saveNow];
    [self.editor rememberCaret];
}

- (void)applicationDidResignActive:(NSNotification *)n { [self.editor saveNow]; }

- (void)windowDidResignKey:(NSNotification *)n { [self.editor saveNow]; }

#pragma mark Vault

- (void)chooseVault {
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.canChooseDirectories = YES;
    p.canChooseFiles = NO;
    p.canCreateDirectories = YES;
    p.allowsMultipleSelection = NO;
    p.prompt = @"Open vault";
    p.message = @"Choose the folder that holds your notes. An Obsidian vault works as it is; nothing is converted.";
    if (self.vault) p.directoryURL = [NSURL fileURLWithPath:self.vault.root];
    if ([p runModal] == NSModalResponseOK && p.URL) {
        [self openVault:p.URL.path];
        if (gSettings) [gSettings refresh];
    }
}

- (void)openVault:(NSString *)path {
    BOOL same = self.vault && [self.vault.root isEqualToString:path.stringByStandardizingPath];
    [self.editor closeNote];
    [self.watcher stop];
    self.vault = [[QVault alloc] initWithRoot:path];
    if (!same) {
        [Defaults() setObject:self.vault.root forKey:kVaultPath];
        if (![[Defaults() stringForKey:@"lastVault"] isEqualToString:self.vault.root]) {
            [Defaults() removeObjectForKey:kLastNote];
            [Defaults() setObject:@[] forKey:kExpanded];
        }
        [Defaults() setObject:self.vault.root forKey:@"lastVault"];
    }
    __weak QApp *weak = self;
    self.watcher = [[QWatcher alloc] initWithPath:self.vault.root handler:^(NSArray<NSString *> *paths, NSArray<NSNumber *> *flags) {
        [weak fsEvent:paths flags:flags];
    }];
    self.window.title = self.vault.name;
    [self.sidebar reload];
    NSString *last = [Defaults() stringForKey:kLastNote];
    NSString *p = last.length ? [self.vault.root stringByAppendingPathComponent:last] : nil;
    if (p && [NSFileManager.defaultManager fileExistsAtPath:p]) [self.editor openPath:p history:NO];
}

- (void)fsEvent:(NSArray<NSString *> *)paths flags:(NSArray<NSNumber *> *)flags {
    BOOL rescan = NO;
    BOOL timeSort = [Defaults() integerForKey:kSortMode] >= QSortModNew;
    for (NSUInteger i = 0; i < paths.count; i++) {
        NSString *p = paths[i].stringByStandardizingPath;
        FSEventStreamEventFlags f = (FSEventStreamEventFlags)flags[i].unsignedIntValue;
        NSString *rel = [self.vault rel:p];
        if ([rel hasPrefix:@"."] || [rel containsString:@"/."]) continue;   // .obsidian, .trash, temp files
        if (self.editor.path && [p isEqualToString:self.editor.path]) { [self.editor fileChanged:p]; continue; }
        [QIndex forget:p];
        if (f & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed |
                 kFSEventStreamEventFlagMustScanSubDirs)) rescan = YES;
        else if (timeSort) rescan = YES;
    }
    if (rescan) [self rescanSoon];
}

- (void)rescanSoon {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rescanNow) object:nil];
    [self performSelector:@selector(rescanNow) withObject:nil afterDelay:0.3];
}

- (void)rescanNow {
    if (!self.vault) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(rescanNow) object:nil];
    [self.vault rescan];
    if (self.editor.path && ![NSFileManager.defaultManager fileExistsAtPath:self.editor.path]) [self.editor closeNote];
    [self.sidebar reload];
    if (self.editor.path) [self.sidebar revealPath:self.editor.path];
}

- (NSString *)defaultNoteDir {
    if (!self.vault) return nil;
    if ([Defaults() integerForKey:kNewNoteLoc] == 1 || !self.editor.path) return self.vault.root;
    return self.editor.path.stringByDeletingLastPathComponent;
}

- (NSString *)createNoteIn:(NSString *)dir name:(NSString *)name {
    if (!self.vault || !dir) return nil;
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *p = FreePath(dir, SafeName(name), @"md");
    if (![@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil]) { NSBeep(); return nil; }
    [self rescanNow];
    return p;
}

- (void)openPeriodic:(NSString *)key {
    if (!self.vault) { [self chooseVault]; return; }
    NSString *rel = PeriodicPath([Defaults() stringForKey:key], [NSDate date]);
    NSString *p = [self.vault.root stringByAppendingPathComponent:rel];
    if (![NSFileManager.defaultManager fileExistsAtPath:p]) {
        [NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [@"" writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [self rescanNow];
    }
    [self.editor openPath:p];
}

#pragma mark Sidebar

- (void)toggleSidebar:(id)sender {
    self.sidebarHidden = !self.sidebarHidden;
    if (self.sidebarHidden) {
        if (NSWidth(self.sidebar.frame) > 120) [Defaults() setDouble:NSWidth(self.sidebar.frame) forKey:kSidebarW];
        self.sidebar.hidden = YES;
        [self.split adjustSubviews];
    } else {
        self.sidebar.hidden = NO;
        [self.split adjustSubviews];
        [self.split setPosition:([Defaults() doubleForKey:kSidebarW] ?: 260) ofDividerAtIndex:0];
    }
    [Defaults() setBool:self.sidebarHidden forKey:kSidebarHide];
    [self.editor layoutForSidebarHidden:self.sidebarHidden];
}

- (CGFloat)splitView:(NSSplitView *)s constrainMinCoordinate:(CGFloat)v ofSubviewAt:(NSInteger)i { return 200; }
- (CGFloat)splitView:(NSSplitView *)s constrainMaxCoordinate:(CGFloat)v ofSubviewAt:(NSInteger)i { return 440; }
- (BOOL)splitView:(NSSplitView *)s canCollapseSubview:(NSView *)v { return v == self.sidebar; }
- (BOOL)splitView:(NSSplitView *)s shouldAdjustSizeOfSubview:(NSView *)v { return v != self.sidebar; }
- (void)splitViewDidResizeSubviews:(NSNotification *)n {
    if (!self.sidebar.hidden && NSWidth(self.sidebar.frame) > 120) [Defaults() setDouble:NSWidth(self.sidebar.frame) forKey:kSidebarW];
}

#pragma mark Menu actions

- (void)newNote:(id)s { [self.sidebar newNote]; }
- (void)newFolder:(id)s { [self.sidebar newFolder]; }
- (void)quickOpen:(id)s { [QSwitcher show]; }
- (void)todayNote:(id)s { [self openPeriodic:kDailyFmt]; }
- (void)weekNote:(id)s { [self openPeriodic:kWeeklyFmt]; }
- (void)showSearch:(id)s { [self.sidebar showSearch:nil]; }
- (void)showFilesTab:(id)s { if (self.sidebarHidden) [self toggleSidebar:nil]; [self.sidebar showFiles]; }
- (void)goBack:(id)s { [self.editor goBack]; }
- (void)goForward:(id)s { [self.editor goForward]; }
- (void)openVaultAction:(id)s { [self chooseVault]; }
- (void)showSettings:(id)s { [QSettings show]; }
- (void)renameCurrent:(id)s { if (self.editor.path) [self.editor focusTitle]; }

- (void)revealCurrent:(id)s {
    if (self.editor.path) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:self.editor.path]]];
}

- (void)trashCurrent:(id)s {
    NSString *p = self.editor.path;
    if (!p) return;
    NSAlert *a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"Move \"%@\" to the Trash?", [p.lastPathComponent stringByDeletingPathExtension]];
    a.informativeText = @"You can put it back from the Trash.";
    [a addButtonWithTitle:@"Move to Trash"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
    [self.editor closeNote];
    [NSWorkspace.sharedWorkspace recycleURLs:@[[NSURL fileURLWithPath:p]] completionHandler:^(NSDictionary *d, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self rescanNow]; });
    }];
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
    SEL a = item.action;
    if (a == @selector(renameCurrent:)) return self.editor.path != nil && ![self.editor.path.pathExtension.lowercaseString isEqualToString:@"canvas"];
    if (a == @selector(revealCurrent:) || a == @selector(trashCurrent:)) return self.editor.path != nil;
    if (a == @selector(toggleSidebar:)) item.title = self.sidebarHidden ? @"Show Sidebar" : @"Hide Sidebar";
    return YES;
}

#pragma mark Menu

- (NSMenuItem *)item:(NSString *)t action:(SEL)a key:(NSString *)k mods:(NSEventModifierFlags)m in:(NSMenu *)menu {
    NSMenuItem *it = [menu addItemWithTitle:t action:a keyEquivalent:k ?: @""];
    if (k.length) it.keyEquivalentModifierMask = m;
    return it;
}

- (void)buildMenu {
    NSEventModifierFlags C = NSEventModifierFlagCommand, S = NSEventModifierFlagShift, O = NSEventModifierFlagOption, K = NSEventModifierFlagControl;
    NSMenu *bar = [NSMenu new];

    NSMenu *app = [[NSMenu alloc] initWithTitle:@"Quire"];
    [self item:@"About Quire" action:@selector(orderFrontStandardAboutPanel:) key:nil mods:0 in:app];
    [app addItem:NSMenuItem.separatorItem];
    [self item:@"Settings…" action:@selector(showSettings:) key:@"," mods:C in:app];
    [app addItem:NSMenuItem.separatorItem];
    [self item:@"Hide Quire" action:@selector(hide:) key:@"h" mods:C in:app];
    [self item:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" mods:C | O in:app];
    [self item:@"Show All" action:@selector(unhideAllApplications:) key:nil mods:0 in:app];
    [app addItem:NSMenuItem.separatorItem];
    [self item:@"Quit Quire" action:@selector(terminate:) key:@"q" mods:C in:app];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = app;

    NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
    [self item:@"New Note" action:@selector(newNote:) key:@"n" mods:C in:file];
    [self item:@"New Folder" action:@selector(newFolder:) key:@"n" mods:C | S in:file];
    [self item:@"Quick Switcher…" action:@selector(quickOpen:) key:@"o" mods:C in:file];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Today's Note" action:@selector(todayNote:) key:@"d" mods:C in:file];
    [self item:@"This Week's Note" action:@selector(weekNote:) key:@"d" mods:C | S in:file];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Rename Note" action:@selector(renameCurrent:) key:@"r" mods:C in:file];
    [self item:@"Show in Finder" action:@selector(revealCurrent:) key:@"r" mods:C | S in:file];
    [self item:@"Move to Trash" action:@selector(trashCurrent:) key:@"\b" mods:C | O in:file];
    [file addItem:NSMenuItem.separatorItem];
    [self item:@"Open Vault…" action:@selector(openVaultAction:) key:@"o" mods:C | S in:file];
    [self item:@"Close Window" action:@selector(performClose:) key:@"w" mods:C in:file];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = file;

    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [self item:@"Undo" action:@selector(undo:) key:@"z" mods:C in:edit];
    [self item:@"Redo" action:@selector(redo:) key:@"z" mods:C | S in:edit];
    [edit addItem:NSMenuItem.separatorItem];
    [self item:@"Cut" action:@selector(cut:) key:@"x" mods:C in:edit];
    [self item:@"Copy" action:@selector(copy:) key:@"c" mods:C in:edit];
    [self item:@"Paste" action:@selector(paste:) key:@"v" mods:C in:edit];
    [self item:@"Select All" action:@selector(selectAll:) key:@"a" mods:C in:edit];
    [edit addItem:NSMenuItem.separatorItem];
    NSMenu *find = [[NSMenu alloc] initWithTitle:@"Find"];
    [self item:@"Find…" action:@selector(performTextFinderAction:) key:@"f" mods:C in:find].tag = NSTextFinderActionShowFindInterface;
    [self item:@"Find and Replace…" action:@selector(performTextFinderAction:) key:@"f" mods:C | O in:find].tag = NSTextFinderActionShowReplaceInterface;
    [self item:@"Find Next" action:@selector(performTextFinderAction:) key:@"g" mods:C in:find].tag = NSTextFinderActionNextMatch;
    [self item:@"Find Previous" action:@selector(performTextFinderAction:) key:@"g" mods:C | S in:find].tag = NSTextFinderActionPreviousMatch;
    [self item:@"Use Selection for Find" action:@selector(performTextFinderAction:) key:@"e" mods:C in:find].tag = NSTextFinderActionSetSearchString;
    [edit addItemWithTitle:@"Find" action:nil keyEquivalent:@""].submenu = find;
    [self item:@"Search All Notes" action:@selector(showSearch:) key:@"f" mods:C | S in:edit];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = edit;

    NSMenu *fmt = [[NSMenu alloc] initWithTitle:@"Format"];
    [self item:@"Bold" action:@selector(mdBold:) key:@"b" mods:C in:fmt];
    [self item:@"Italic" action:@selector(mdItalic:) key:@"i" mods:C in:fmt];
    [self item:@"Strikethrough" action:@selector(mdStrike:) key:@"x" mods:C | S in:fmt];
    [self item:@"Highlight" action:@selector(mdHighlight:) key:@"h" mods:C | S in:fmt];
    [self item:@"Inline Code" action:@selector(mdCode:) key:@"c" mods:C | O in:fmt];
    [self item:@"Link to Note" action:@selector(mdLink:) key:@"k" mods:C in:fmt];
    [self item:@"Toggle Checkbox" action:@selector(mdTask:) key:@"l" mods:C in:fmt];
    [fmt addItem:NSMenuItem.separatorItem];
    [self item:@"Heading 1" action:@selector(mdHeading:) key:@"1" mods:C in:fmt].tag = 1;
    [self item:@"Heading 2" action:@selector(mdHeading:) key:@"2" mods:C in:fmt].tag = 2;
    [self item:@"Heading 3" action:@selector(mdHeading:) key:@"3" mods:C in:fmt].tag = 3;
    [self item:@"Body Text" action:@selector(mdHeading:) key:@"0" mods:C | O in:fmt].tag = 0;
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = fmt;

    NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
    [self item:@"Hide Sidebar" action:@selector(toggleSidebar:) key:@"\\" mods:C in:view];
    [self item:@"Files" action:@selector(showFilesTab:) key:@"e" mods:C | S in:view];
    [self item:@"Search" action:@selector(showSearch:) key:@"f" mods:C | S in:view];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"Fold Heading" action:@selector(foldHeading:) key:@"[" mods:C | O in:view];
    [self item:@"Unfold Heading" action:@selector(unfoldHeading:) key:@"]" mods:C | O in:view];
    [self item:@"Fold All Headings" action:@selector(foldAllHeadings:) key:@"[" mods:C | O | S in:view];
    [self item:@"Unfold All Headings" action:@selector(unfoldAllHeadings:) key:@"]" mods:C | O | S in:view];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"Back" action:@selector(goBack:) key:@"[" mods:C in:view];
    [self item:@"Forward" action:@selector(goForward:) key:@"]" mods:C in:view];
    [view addItem:NSMenuItem.separatorItem];
    [self item:@"Enter Full Screen" action:@selector(toggleFullScreen:) key:@"f" mods:C | K in:view];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = view;

    NSMenu *win = [[NSMenu alloc] initWithTitle:@"Window"];
    [self item:@"Minimize" action:@selector(performMiniaturize:) key:@"m" mods:C in:win];
    [self item:@"Zoom" action:@selector(performZoom:) key:nil mods:0 in:win];
    [bar addItemWithTitle:@"" action:nil keyEquivalent:@""].submenu = win;
    NSApp.windowsMenu = win;

    NSApp.mainMenu = bar;
}

@end

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        gFontCache = [NSMutableDictionary dictionary];
        gParaCache = [NSMutableDictionary dictionary];
        gTextCache = [NSMutableDictionary dictionary];
        [Defaults() registerDefaults:@{
            kFontSize: @17, kPageWidth: @680, kSortMode: @0, kNewNoteLoc: @0, kSidebarW: @260,
            kDailyFmt: @"'Daily'/yyyy/MMMM/yyyy-MM-dd",
            kWeeklyFmt: @"'Weekly'/YYYY/YYYY-'W'ww",
        }];
        gBase = [Defaults() doubleForKey:kFontSize];
        InitPalette();
        InitRegexes();
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        QApp *d = [QApp new];
        gApp = d;
        app.delegate = d;
        [app run];
    }
    return 0;
}
