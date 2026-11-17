// cursor_diag.m — diagnostic library for cursor problems in the hybrid-edition app (not part of the shipped app).
//
// Logs every low-level NSCursor change request with its caller and samples what the window server actually shows
// (CGSCurrentCursorSeed + +[NSCursor currentSystemCursor], every 0.5 ms), including where the pointer is relative to
// the key window. -[NSCursor set] is left alone because libPvzHybridMac.dylib identifies engine calls by the return
// address of that hook.
//
// Build:  clang -dynamiclib -fobjc-arc -O1 -arch arm64 -framework AppKit -o libcursordiag.dylib cursor_diag.m
//         codesign -s - -f libcursordiag.dylib
// Run (isolated home, never the real saves):
//   open -n --env HOME=<scratch> --env DYLD_INSERT_LIBRARIES=<abs>/libcursordiag.dylib \
//        --env PVZH_CURSOR_DIAG_FILE=<abs>/diag.log [--env PVZH_CURSOR_DIAG_DIR=<abs>/img] --env PVZH_LOG=1 \
//        --stderr <abs>/e.log -a 植物大战僵尸杂交版.app --args --windowed
// Quit with Cmd-Q (killing the engine with SIGTERM aborts in a mutex during exit).
// Lines "SCREEN ... IN-GAME" that show 28x40 (the system arrow) while the game cursor is wanted are the problem cases.
#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <objc/runtime.h>
#include <pthread.h>

typedef int (*SeedFn)(void);
static SeedFn gSeed;
static double gT0;
static FILE *gOut;
static NSString *gImageDir;
static NSMutableSet *gDumped;

static void L(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void L(const char *fmt, ...)
{
	char b[700];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(b, sizeof b, fmt, ap);
	va_end(ap);
	fprintf(gOut, "%9.4f %s\n", CFAbsoluteTimeGetCurrent() - gT0, b);
}

static const char *Caller(void *ra, char *buf, size_t n)
{
	Dl_info i;
	if (dladdr(ra, &i))
	{
		const char *f = i.dli_fname ? strrchr(i.dli_fname, '/') : NULL;
		snprintf(buf, n, "%s:%s+%ld", f ? f + 1 : "?", i.dli_sname ? i.dli_sname : "?",
			i.dli_saddr ? (long)((char *)ra - (char *)i.dli_saddr) : 0L);
	}
	else
		snprintf(buf, n, "%p", ra);
	return buf;
}

// Writes each distinct cursor picture once (keyed by cursor and image object, so reused addresses are not mixed up).
static void DumpImage(NSCursor *c)
{
	if (gImageDir == nil)
		return;
	NSImage *im = [c image];
	NSString *name = [NSString stringWithFormat:@"%p-%p.png", c, im];
	@synchronized(gDumped)
	{
		if ([gDumped containsObject:name])
			return;
		[gDumped addObject:name];
	}
	CGImageRef cg = [im CGImageForProposedRect:NULL context:nil hints:nil];
	if (cg == NULL)
		return;
	NSBitmapImageRep *r = [[NSBitmapImageRep alloc] initWithCGImage:cg];
	[[r representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
		writeToFile:[gImageDir stringByAppendingPathComponent:name] atomically:NO];
}

static NSString *Describe(id c)
{
	if (![c isKindOfClass:[NSCursor class]])
		return c == nil ? @"nil" : NSStringFromClass([c class]);
	DumpImage(c);
	const NSSize s = [[c image] size];
	const NSPoint h = [c hotSpot];
	return [NSString stringWithFormat:@"%.0fx%.0f hot %.0f,%.0f %p", s.width, s.height, h.x, h.y, c];
}

static void HookVoid(Class cls, NSString *selName, const char *tag)
{
	SEL sel = NSSelectorFromString(selName);
	Method m = class_getInstanceMethod(cls, sel);
	if (m == NULL)
	{
		L("no %s", tag);
		return;
	}
	IMP orig = method_getImplementation(m);
	method_setImplementation(m, imp_implementationWithBlock(^(id self) {
		char w[300];
		L("%s %s from %s", tag, [Describe(self) UTF8String], Caller(__builtin_return_address(0), w, sizeof w));
		((void (*)(id, SEL))orig)(self, sel);
	}));
}

static void *Sampler(void *unused)
{
	(void)unused;
	int last = -1;
	for (;;)
	{
		@autoreleasepool
		{
			const int seed = gSeed ? gSeed() : 0;
			if (seed != last)
			{
				last = seed;
				const NSPoint p = [NSEvent mouseLocation];
				NSWindow *kw = [NSApp keyWindow];
				const NSRect content = kw ? [kw contentRectForFrameRect:[kw frame]] : NSZeroRect;
				const char *where = kw == nil ? "no-key-window"
					: NSPointInRect(p, NSInsetRect(content, 6, 6)) ? "IN-GAME"
					: NSPointInRect(p, [kw frame]) ? "window-edge/title" : "outside";
				L("SCREEN seed=%d shows %s at %.0f,%.0f %s active=%d fullscreen=%d", seed,
					[Describe([NSCursor currentSystemCursor]) UTF8String], p.x, p.y, where, [NSApp isActive],
					kw ? (int)(([kw styleMask] & NSWindowStyleMaskFullScreen) != 0) : -1);
			}
		}
		usleep(500);
	}
	return NULL;
}

__attribute__((constructor)) static void CursorDiagInit(void)
{
	const char *path = getenv("PVZH_CURSOR_DIAG_FILE");
	gOut = path ? fopen(path, "w") : stderr;
	if (gOut == NULL)
		gOut = stderr;
	setvbuf(gOut, NULL, _IOLBF, 0);
	gT0 = CFAbsoluteTimeGetCurrent();
	gDumped = [NSMutableSet set];
	const char *dir = getenv("PVZH_CURSOR_DIAG_DIR");
	if (dir != NULL)
		gImageDir = @(dir);
	gSeed = (SeedFn)dlsym(RTLD_DEFAULT, "CGSCurrentCursorSeed");

	Class c = [NSCursor class], meta = object_getClass(c);
	HookVoid(c, @"_reallySet", "-_reallySet");
	HookVoid(c, @"forceSet", "-forceSet");
	HookVoid(c, @"push", "-push");
	HookVoid(c, @"pop", "-pop");
	HookVoid(meta, @"hide", "+hide");
	HookVoid(meta, @"unhide", "+unhide");
	HookVoid(meta, @"pop", "+pop");
	HookVoid(meta, @"_clearOverrideCursorAndSetArrow", "+_clearOverrideCursorAndSetArrow");

	SEL ovSel = NSSelectorFromString(@"_setOverrideCursor:type:");
	Method ov = class_getInstanceMethod(meta, ovSel);
	if (ov != NULL)
	{
		IMP orig = method_getImplementation(ov);
		method_setImplementation(ov, imp_implementationWithBlock(^(id self, id cursor, long type) {
			char w[300];
			L("+_setOverrideCursor %s type %ld from %s", [Describe(cursor) UTF8String], type,
				Caller(__builtin_return_address(0), w, sizeof w));
			((void (*)(id, SEL, id, long))orig)(self, ovSel, cursor, type);
		}));
	}
	SEL hideSel = @selector(setHiddenUntilMouseMoves:);
	Method hm = class_getInstanceMethod(meta, hideSel);
	if (hm != NULL)
	{
		IMP orig = method_getImplementation(hm);
		method_setImplementation(hm, imp_implementationWithBlock(^(id self, BOOL flag) {
			char w[300];
			L("+setHiddenUntilMouseMoves %d from %s", flag, Caller(__builtin_return_address(0), w, sizeof w));
			((void (*)(id, SEL, BOOL))orig)(self, hideSel, flag);
		}));
	}
	pthread_t t;
	pthread_create(&t, NULL, Sampler, NULL);
	L("cursor diagnostics loaded (seed %s)", gSeed ? "available" : "missing");
}
