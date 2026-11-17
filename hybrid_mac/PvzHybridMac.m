/*
 * libPvzHybridMac: in-process macOS helper for the Godot 4.7 (.NET) build of 植物大战僵尸杂交重制版.
 *
 * The bundle launcher (launcher.c) loads it into the game process with DYLD_INSERT_LIBRARIES. It never touches the
 * game's code, data or rendering; it only works on the AppKit side of Godot's main window. It does nothing in any
 * other process (it checks that the main executable lives in the same bundle as the library), and it never creates
 * NSApplication itself: everything waits until Godot has created its GodotApplication.
 *
 * 1. Windowed aspect lock (PVZH_NO_ASPECT_LOCK=1 turns it off).
 *    Once Godot's main window (GodotWindow with window_id 0) is visible, its content is kept at (uw*k) x (uh*k)
 *    points for an integer k, where uw:uh is the content ratio the window opened with (1620x900 -> 9:5; PVZH_ASPECT=W:H
 *    overrides). Such a size has exactly the ratio of the 1080x600 base viewport, so stretch mode canvas_items with
 *    aspect keep_height fills it with no bar and no extra width. Same method as src/.../MacWindowAspect.mm (4:3, SDL):
 *    - live resizing: NSWindow.contentAspectRatio, plus Godot's window delegate (GodotWindowDelegate) wrapped at run
 *      time so that every size AppKit proposes is rounded to the nearest k and clamped to the visible screen area;
 *    - zoom (double-click on the title bar, Option-click on the green button, Godot's maximize): the standard frame is
 *      the largest k inside AppKit's default zoomed frame, and unzooming returns to the last windowed frame;
 *    - other size changes (window tiling, programmatic sizes, display changes): once the size has been stable for
 *      0.15 s with no mouse button down and no live resize, a size of another ratio is snapped to the nearest k,
 *      keeping the dimension that changed (a tile: fitted inside it). A size that keeps coming back is left alone
 *      after two snaps and retried after 1, 2, 4 ... 32 s, so the lock never fights another program;
 *    - fullscreen: the constraint is cleared before -toggleFullScreen: and during the transition, and restored after
 *      the window is windowed again. Godot's own fullscreen handling is unchanged.
 *
 * 2. Test driver, completely inactive unless PVZH_TEST_SCRIPT is set (a script file, or inline commands separated
 *    by ';' or newlines). A background thread runs the script and posts real NSEvents to the game window on the main
 *    thread ([NSApp postEvent:atStart:], the same path as hardware events; no Accessibility permission needed).
 *    In test mode only, +[NSEvent mouseLocation] and +[NSEvent pressedMouseButtons] report the scripted pointer (Godot
 *    reads them for Viewport.get_mouse_position(), button masks and popup handling), and -[CAMetalLayer nextDrawable]
 *    calls are counted as a frame counter (the f= value in the log).
 *
 *    Script syntax, one command per line ('#' starts a comment line):
 *      ms N                    wait N milliseconds
 *      waitwin [SEC]           wait until the game window is visible (default 180 s), then log its geometry
 *      logwin                  log window frame, content size (points and pixels), backing scale, aspect state
 *      move X Y                pointer move (a drag while a button is down)
 *      click X Y               move, 50 ms, left down, 80 ms (PVZH_TEST_CLICK_MS), left up
 *      dclick X Y / rclick X Y double click / right click
 *      down X Y / up X Y       left button down / up
 *      drag X1 Y1 X2 Y2 MS     move, down, ~60 Hz drag steps for MS milliseconds, up
 *      wmove wclick wdclick wrclick wdown wup wdrag
 *                              the same with X/Y in window content points from the content's top-left corner
 *                              (values outside the content reach the window border, e.g. a resize corner)
 *      key KEYCODE             key down + up, macOS virtual key code (decimal or 0x..), e.g. 53 Escape, 36 Return
 *      char C                  key down + up typing character C (US key code)
 *      winsize W H             set the window content size in points (top-left corner kept)
 *      log TEXT                only log
 *      quit                    -[NSApp terminate:], which Godot turns into the game's normal close request
 *    X/Y without the w prefix are logical coordinates of the 1080x600 base viewport (PVZH_TEST_BASE=WxH): for stretch
 *    mode canvas_items + keep_height, scale = content height / 600 and x counts from the left edge of the content
 *    (a window narrower than 9:5 is letterboxed: scale = width / 1080, centred vertically).
 *    Every command is logged to stderr as 'PVZH_TEST t=<seconds since load> f=<frames presented> <command>'.
 *    An inline script (the variable's value is not a readable file) separates commands with ';' as well.
 *    PVZH_TEST_TRACE=1 also logs every mouse/key event that reaches Godot's content view ('view mouseDown: ...').
 *    Pointer events of the real mouse are dropped while a script runs (PVZH_TEST_ISOLATE=0 keeps them), so a user
 *    moving the mouse over the background test window cannot disturb the run.
 */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <objc/runtime.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#pragma mark - Common

static double gT0;					// CFAbsoluteTime when the library was loaded
static bool gLog;					// PVZH_LOG or PVZH_TEST_SCRIPT
static bool gTest;					// PVZH_TEST_SCRIPT
static atomic_long gFrames;			// -[CAMetalLayer nextDrawable] calls (test mode only)

static double Now(void)
{
	return CFAbsoluteTimeGetCurrent();
}

static void Log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void Log(const char *fmt, ...)
{
	if (!gLog)
		return;
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	fprintf(stderr, "PVZH t=%.3f %s\n", Now() - gT0, buf);
	fflush(stderr);
}

static void TLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void TLog(const char *fmt, ...)
{
	char buf[1024];
	va_list ap;
	va_start(ap, fmt);
	vsnprintf(buf, sizeof buf, fmt, ap);
	va_end(ap);
	fprintf(stderr, "PVZH_TEST t=%.3f f=%ld %s\n", Now() - gT0, atomic_load(&gFrames), buf);
	fflush(stderr);
}

static long Gcd(long a, long b)
{
	while (b != 0)
	{
		long t = a % b;
		a = b;
		b = t;
	}
	return a < 0 ? -a : a;
}

// Godot's main window. Not retained (Godot owns it); cleared on NSWindowWillCloseNotification.
static __unsafe_unretained NSWindow *gWindow;
static bool gWindowGone;

static NSSize ContentSize(NSWindow *w)
{
	return [w contentRectForFrameRect:[w frame]].size;
}

#pragma mark - Aspect lock

typedef NSSize (*WillResizeFn)(id, SEL, NSWindow *, NSSize);
typedef NSRect (*StandardFrameFn)(id, SEL, NSWindow *, NSRect);
typedef BOOL (*ShouldZoomFn)(id, SEL, NSWindow *, NSRect);
typedef void (*ToggleFullScreenFn)(id, SEL, id);

static const double kSettleSeconds = 0.15;		// a programmatic / system size must be stable this long before a snap
static const int kMaxAttemptsPerSize = 2;		// snaps from one size within kAttemptWindowSeconds
static const double kAttemptWindowSeconds = 3.0;
static const double kFirstRetrySeconds = 1.0;	// a size left alone by the guard is tried again after this, doubling
static const int kMaxRetries = 6;				// 1 + 2 + ... + 32 s; then left alone until the size changes
static const double kTransitionTimeoutSeconds = 4.0;	// fullscreen animations take about one second
static const double kMinContentHeight = 300;	// smallest locked content height in points (half the 600 base)

static bool gLockDisabled;			// PVZH_NO_ASPECT_LOCK=1
static bool gLockInstalled;
static id gObserver;
static NSTimer *gTimer;
static int gUW = 9, gUH = 5;		// content = (gUW * k) x (gUH * k) points
static int gMinK = 1;
static bool gFullscreenTransition;
static double gTransitionStart;
static bool gConstraintOn;
static bool gPending;
static double gPendingSince;
static NSSize gSettled;				// the last exact-ratio content size seen
static NSSize gAttemptFrom;			// the size the last snap started from
static int gAttempts;
static double gLastAttemptTime;
static double gRetryAt;
static double gRetryDelay = 1.0;
static int gRetries;
static NSRect gUserFrame;			// the last settled windowed exact frame that was not zoomed (unzoom target)
static WillResizeFn gOrigWillResize;
static StandardFrameFn gOrigStandardFrame;
static ShouldZoomFn gOrigShouldZoom;
static ToggleFullScreenFn gOrigToggleFullScreen;

static bool InFullscreenTransition(void)
{
	// A transition that failed posts no notification: give up waiting after a while.
	return gFullscreenTransition && Now() - gTransitionStart < kTransitionTimeoutSeconds;
}

static bool LockActive(NSWindow *w)
{
	if (w == nil || w != gWindow || !gLockInstalled || InFullscreenTransition())
		return false;
	const NSWindowStyleMask style = [w styleMask];
	return (style & NSWindowStyleMaskFullScreen) == 0 && (style & NSWindowStyleMaskResizable) != 0 &&
		(style & NSWindowStyleMaskTitled) != 0;
}

static bool IsExact(NSSize s)
{
	const double k = round(s.width / gUW);
	return k >= 1 && fabs(s.width - k * gUW) < 1e-3 && fabs(s.height - k * gUH) < 1e-3;
}

static NSSize ContentSizeForK(int k)
{
	return NSMakeSize((double)k * gUW, (double)k * gUH);
}

// The largest k whose window (content plus title bar) fits the visible area of the screen.
static int MaxK(NSWindow *w, NSScreen *screen)
{
	if (screen == nil)
		screen = [NSScreen mainScreen];
	if (screen == nil)
		return INT_MAX / 4 / (gUW > gUH ? gUW : gUH);
	const NSRect visible = [screen visibleFrame];
	const NSRect frame = [w frame];
	const NSRect content = [w contentRectForFrameRect:frame];
	const double extraW = frame.size.width - content.size.width;
	const double extraH = frame.size.height - content.size.height;
	const int k = (int)floor(fmin((visible.size.width - extraW) / gUW, (visible.size.height - extraH) / gUH));
	return k > gMinK ? k : gMinK;
}

static int ClampK(int k, int maxK)
{
	if (k > maxK)
		k = maxK;
	if (k < gMinK)
		k = gMinK;
	return k;
}

static void MarkPending(void)
{
	gPending = true;
	gPendingSince = Now();
}

static NSRect ClampToVisible(NSRect f, NSRect visible)
{
	if (NSMaxX(f) > NSMaxX(visible))
		f.origin.x = NSMaxX(visible) - f.size.width;
	if (f.origin.x < NSMinX(visible))
		f.origin.x = NSMinX(visible);
	if (NSMaxY(f) > NSMaxY(visible))
		f.origin.y = NSMaxY(visible) - f.size.height;
	if (f.origin.y < NSMinY(visible))
		f.origin.y = NSMinY(visible);
	return f;
}

static void RememberUserFrame(NSWindow *w)
{
	if (!LockActive(w) || [w inLiveResize] || [w isZoomed])
		return;
	const NSRect frame = [w frame];
	if (IsExact([w contentRectForFrameRect:frame].size))
		gUserFrame = frame;
}

// The AppKit live-resize constraint is on while the lock is active and off otherwise. With it, AppKit proposes sizes
// of the right ratio for edge drags and fits corner drags inside the pointer (a corner dragged along one axis only
// does not resize), as in the original edition's port; without it, a one-axis corner drag would alternate between
// following the width and the height.
static void ApplyConstraint(void)
{
	NSWindow *w = gWindow;
	if (w == nil || !gLockInstalled)
		return;
	gConstraintOn = LockActive(w);
	if (gConstraintOn)
	{
		if (!NSEqualSizes([w contentAspectRatio], NSMakeSize(gUW, gUH)))
		{
			[w setContentAspectRatio:NSMakeSize(gUW, gUH)];
			Log("aspect constraint on (%d:%d)", gUW, gUH);
		}
	}
	else if (!NSEqualSizes([w contentAspectRatio], NSZeroSize))
	{
		// contentResizeIncrements and contentAspectRatio are mutually exclusive: 1x1 increments clear the ratio.
		[w setContentResizeIncrements:NSMakeSize(1, 1)];
		if (!NSEqualSizes([w contentAspectRatio], NSZeroSize))
			[w setContentAspectRatio:NSZeroSize];
		Log("aspect constraint off");
	}
}

// Live resize: round every size AppKit proposes to the nearest k.
static NSSize PvzhWindowWillResize(id self, SEL _cmd, NSWindow *sender, NSSize frameSize)
{
	NSSize size = gOrigWillResize != NULL ? gOrigWillResize(self, _cmd, sender, frameSize) : frameSize;
	if (!LockActive(sender))
		return size;
	const NSRect current = [sender contentRectForFrameRect:[sender frame]];
	const NSRect proposed = [sender contentRectForFrameRect:NSMakeRect(0, 0, size.width, size.height)];
	const double kw = proposed.size.width / gUW, kh = proposed.size.height / gUH;
	// Follow the dimension being dragged (the one that changed more, in ratio units); a corner drag, or AppKit's
	// aspect ratio, moves both, and then their mean is used.
	const double dw = fabs(proposed.size.width - current.size.width) / gUW;
	const double dh = fabs(proposed.size.height - current.size.height) / gUH;
	const double k = dw > dh + 0.5 ? kw : (dh > dw + 0.5 ? kh : (kw + kh) / 2);
	const int ki = ClampK((int)lround(k), MaxK(sender, [sender screen]));
	const NSSize c = ContentSizeForK(ki);
	return [sender frameRectForContentRect:NSMakeRect(0, 0, c.width, c.height)].size;
}

// Zoom: the largest exact window inside the default zoomed frame, top-aligned and centred horizontally.
static NSRect PvzhWindowWillUseStandardFrame(id self, SEL _cmd, NSWindow *sender, NSRect defaultFrame)
{
	NSRect frame = gOrigStandardFrame != NULL ? gOrigStandardFrame(self, _cmd, sender, defaultFrame) : defaultFrame;
	if (!LockActive(sender))
		return frame;
	const NSRect content = [sender contentRectForFrameRect:frame];
	int k = (int)floor(fmin(content.size.width / gUW, content.size.height / gUH));
	if (k < gMinK)
		k = gMinK;
	const NSSize c = ContentSizeForK(k);
	NSRect result = [sender frameRectForContentRect:NSMakeRect(0, 0, c.width, c.height)];
	NSRect bounds = frame;
	NSScreen *screen = [sender screen];
	if (screen != nil && NSContainsRect([screen visibleFrame], frame))
		bounds = [screen visibleFrame];
	result.origin.x = round(NSMidX(bounds) - result.size.width / 2);
	result.origin.y = NSMaxY(frame) - result.size.height;
	return result;
}

// Zoom in: remember where to come back to. Unzoom: return to the last windowed exact frame that was not zoomed.
static BOOL PvzhWindowShouldZoom(id self, SEL _cmd, NSWindow *sender, NSRect newFrame)
{
	const BOOL zoom = gOrigShouldZoom != NULL ? gOrigShouldZoom(self, _cmd, sender, newFrame) : YES;
	if (!zoom || !LockActive(sender))
		return zoom;
	if (![sender isZoomed])
	{
		RememberUserFrame(sender);
		return YES;
	}
	if (NSIsEmptyRect(gUserFrame))
		return YES;
	NSRect target = gUserFrame;
	NSScreen *screen = [sender screen];
	if (screen != nil)
	{
		const NSRect content = [sender contentRectForFrameRect:target];
		const int k = ClampK((int)lround(content.size.width / gUW), MaxK(sender, screen));
		const NSSize c = ContentSizeForK(k);
		const NSRect sized = [sender frameRectForContentRect:NSMakeRect(0, 0, c.width, c.height)];
		target.origin.y = NSMaxY(target) - sized.size.height;
		target.size = sized.size;
		target = ClampToVisible(target, [screen visibleFrame]);
	}
	if (NSEqualRects(target, [sender frame]))
		return YES;
	[sender setFrame:target display:YES];
	Log("aspect unzoom to %gx%g", [sender contentRectForFrameRect:target].size.width,
		[sender contentRectForFrameRect:target].size.height);
	return NO;
}

// Fullscreen request (Godot's window_set_mode, the green button, the Window menu): clear the constraint first.
static void PvzhToggleFullScreen(id self, SEL _cmd, id sender)
{
	if (self == gWindow && gLockInstalled && ([(NSWindow *)self styleMask] & NSWindowStyleMaskFullScreen) == 0)
	{
		gFullscreenTransition = true;
		gTransitionStart = Now();
		ApplyConstraint();
	}
	if (gOrigToggleFullScreen != NULL)
		gOrigToggleFullScreen(self, _cmd, sender);
}

static const char *DelegateMethodTypes(SEL sel, Method existing)
{
	if (existing != NULL)
		return method_getTypeEncoding(existing);
	struct objc_method_description d = protocol_getMethodDescription(@protocol(NSWindowDelegate), sel, NO, YES);
	return d.types;
}

static void InstallDelegateHooks(NSWindow *w)
{
	id delegate = [w delegate];
	if (delegate == nil)
	{
		Log("aspect: the window has no delegate; live resizing relies on contentAspectRatio alone");
		return;
	}
	Class cls = [delegate class];
	const SEL resizeSel = @selector(windowWillResize:toSize:);
	const SEL standardSel = @selector(windowWillUseStandardFrame:defaultFrame:);
	const SEL zoomSel = @selector(windowShouldZoom:toFrame:);
	// Only methods the class itself defines are wrapped; an inherited one (none for GodotWindowDelegate) is called
	// through the wrapper's original pointer as well.
	Method resize = class_getInstanceMethod(cls, resizeSel);
	Method standard = class_getInstanceMethod(cls, standardSel);
	Method zoom = class_getInstanceMethod(cls, zoomSel);
	const char *resizeTypes = DelegateMethodTypes(resizeSel, resize);
	const char *standardTypes = DelegateMethodTypes(standardSel, standard);
	const char *zoomTypes = DelegateMethodTypes(zoomSel, zoom);
	if (resizeTypes == NULL || standardTypes == NULL || zoomTypes == NULL)
	{
		Log("aspect: no NSWindowDelegate method types; live resizing relies on contentAspectRatio alone");
		return;
	}
	gOrigWillResize = resize != NULL ? (WillResizeFn)method_getImplementation(resize) : NULL;
	gOrigStandardFrame = standard != NULL ? (StandardFrameFn)method_getImplementation(standard) : NULL;
	gOrigShouldZoom = zoom != NULL ? (ShouldZoomFn)method_getImplementation(zoom) : NULL;
	class_replaceMethod(cls, resizeSel, (IMP)PvzhWindowWillResize, resizeTypes);
	class_replaceMethod(cls, standardSel, (IMP)PvzhWindowWillUseStandardFrame, standardTypes);
	class_replaceMethod(cls, zoomSel, (IMP)PvzhWindowShouldZoom, zoomTypes);
	// AppKit caches which optional delegate methods exist when the delegate is set.
	if (resize == NULL || standard == NULL || zoom == NULL)
	{
		[w setDelegate:nil];
		[w setDelegate:delegate];
	}
	Log("aspect: hooks on %s (windowWillResize:toSize: %s, windowWillUseStandardFrame:defaultFrame: %s, "
		"windowShouldZoom:toFrame: %s)", class_getName(cls), resize ? "wrapped" : "added",
		standard ? "wrapped" : "added", zoom ? "wrapped" : "added");
}

static void InstallToggleHook(NSWindow *w)
{
	Class cls = object_getClass(w);
	const SEL sel = @selector(toggleFullScreen:);
	Method m = class_getInstanceMethod(cls, sel);
	if (m == NULL)
		return;
	IMP inherited = method_getImplementation(m);
	const bool added = class_addMethod(cls, sel, (IMP)PvzhToggleFullScreen, method_getTypeEncoding(m));
	if (added)
		gOrigToggleFullScreen = (ToggleFullScreenFn)inherited;		// the class inherited it: call NSWindow's
	else
		gOrigToggleFullScreen = (ToggleFullScreenFn)method_setImplementation(m, (IMP)PvzhToggleFullScreen);
	Log("aspect: toggleFullScreen: %s on %s", added ? "added" : "wrapped", class_getName(cls));
}

// Resize a window whose size settled at another ratio to the nearest exact size.
static bool Snap(void)
{
	NSWindow *w = gWindow;
	const NSRect frame = [w frame];
	const NSRect content = [w contentRectForFrameRect:frame];
	const double cw = content.size.width, ch = content.size.height;
	NSScreen *screen = [w screen];
	if (screen == nil)
		screen = [NSScreen mainScreen];

	if (IsExact(content.size))
	{
		// An exact size is left as it is (also when it is larger than the screen, e.g. Godot's initial window).
		gSettled = content.size;
		RememberUserFrame(w);
		return false;
	}
	const int maxK = MaxK(w, screen);

	// A frame flush with two or more edges of the visible area was placed there by window tiling.
	const NSRect visible = screen != nil ? [screen visibleFrame] : NSZeroRect;
	const bool atLeft = screen != nil && fabs(NSMinX(frame) - NSMinX(visible)) <= 1;
	const bool atRight = screen != nil && fabs(NSMaxX(frame) - NSMaxX(visible)) <= 1;
	const bool atBottom = screen != nil && fabs(NSMinY(frame) - NSMinY(visible)) <= 1;
	const bool atTop = screen != nil && fabs(NSMaxY(frame) - NSMaxY(visible)) <= 1;
	bool fitTile = false;

	// Keep the dimension that was changed; when both were, the larger one (relative to the ratio), except in a tile,
	// which the window then fits inside.
	int k;
	const bool widthChanged = fabs(cw - gSettled.width) >= 0.5;
	const bool heightChanged = fabs(ch - gSettled.height) >= 0.5;
	if (widthChanged && !heightChanged)
		k = (int)lround(cw / gUW);
	else if (heightChanged && !widthChanged)
		k = (int)lround(ch / gUH);
	else if ((int)atLeft + (int)atRight + (int)atBottom + (int)atTop >= 2)
	{
		fitTile = true;
		k = (int)floor(fmin(cw / gUW, ch / gUH));
	}
	else
		k = (int)lround(fmax(cw / gUW, ch / gUH));
	k = ClampK(k, maxK);

	// Oscillation guard: something that puts the same size back after each snap wins after kMaxAttemptsPerSize snaps;
	// the size is tried again after a pause that doubles each time.
	const double t = Now();
	if (NSEqualSizes(content.size, gAttemptFrom) && t - gLastAttemptTime < kAttemptWindowSeconds)
	{
		if (gAttempts >= kMaxAttemptsPerSize)
		{
			if (gRetries < kMaxRetries)
			{
				gRetryAt = t + gRetryDelay;
				Log("aspect: %gx%g keeps coming back: left as it is, trying again in %gs", cw, ch, gRetryDelay);
				gRetryDelay *= 2;
				gRetries++;
			}
			else
				Log("aspect: %gx%g keeps coming back: left as it is until the size changes", cw, ch);
			return false;
		}
		gAttempts++;
	}
	else
	{
		if (t - gLastAttemptTime >= kAttemptWindowSeconds)
		{
			gRetries = 0;
			gRetryDelay = kFirstRetrySeconds;
		}
		gAttemptFrom = content.size;
		gAttempts = 1;
	}
	gLastAttemptTime = t;
	gRetryAt = 0;

	// Keep the top edge and the horizontal centre (in a tile: the tile edges), inside the visible area.
	const NSSize c = ContentSizeForK(k);
	NSRect target = [w frameRectForContentRect:NSMakeRect(0, 0, c.width, c.height)];
	target.origin.x = round(NSMidX(frame) - target.size.width / 2);
	target.origin.y = NSMaxY(frame) - target.size.height;
	if (fitTile)
	{
		if (atLeft && !atRight)
			target.origin.x = NSMinX(frame);
		else if (atRight && !atLeft)
			target.origin.x = NSMaxX(frame) - target.size.width;
		if (atBottom && !atTop)
			target.origin.y = NSMinY(frame);
	}
	if (screen != nil)
		target = ClampToVisible(target, visible);
	[w setFrame:target display:YES];

	const NSSize now = ContentSize(w);
	if (IsExact(now))
		gSettled = now;
	Log("aspect: snap %gx%g -> %gx%g (k=%d, max %d, %sattempt %d), now %gx%g", cw, ch, c.width, c.height, k, maxK,
		fitTile ? "tile, " : "", gAttempts, now.width, now.height);
	return true;
}

static void AspectUpdate(void)
{
	NSWindow *w = gWindow;
	if (w == nil || !gLockInstalled)
		return;
	const bool active = LockActive(w);
	if (active != gConstraintOn && ![w inLiveResize])
		ApplyConstraint();		// changed without a notification (e.g. a fullscreen transition that failed)
	if (gRetryAt > 0 && !gPending && Now() >= gRetryAt)
	{
		gRetryAt = 0;
		gAttempts = kMaxAttemptsPerSize - 1;
		gLastAttemptTime = Now();
		gPending = true;
		gPendingSince = gLastAttemptTime - kSettleSeconds;
	}
	if (!gPending)
		return;
	if (!active || [w inLiveResize] || [w isMiniaturized] || ![w isVisible])
		return;
	if ([NSEvent pressedMouseButtons] != 0)		// the user may still be moving the window (to a tile, a display)
		return;
	if (Now() - gPendingSince < kSettleSeconds)
		return;
	gPending = false;
	Snap();
}

@interface PvzhAspectObserver : NSObject
@end

@implementation PvzhAspectObserver
- (void)sizeChanged:(NSNotification *)n
{
	(void)n;
	MarkPending();
}
- (void)willEnterOrExitFullScreen:(NSNotification *)n
{
	(void)n;
	gFullscreenTransition = true;
	gTransitionStart = Now();
	ApplyConstraint();
}
- (void)didEnterFullScreen:(NSNotification *)n
{
	(void)n;
	gFullscreenTransition = false;
	ApplyConstraint();
	Log("aspect: fullscreen entered (content %gx%g)", ContentSize(gWindow).width, ContentSize(gWindow).height);
}
- (void)didExitFullScreen:(NSNotification *)n
{
	(void)n;
	gFullscreenTransition = false;
	ApplyConstraint();
	MarkPending();
	Log("aspect: fullscreen exited (content %gx%g)", ContentSize(gWindow).width, ContentSize(gWindow).height);
}
- (void)windowWillClose:(NSNotification *)n
{
	(void)n;
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[gTimer invalidate];
	gTimer = nil;
	gWindow = nil;
	gWindowGone = true;
	gPending = false;
}
@end

// The smallest-denominator ratio (denominator <= 32) closest to x.
static void BestRatio(double x, int *num, int *den)
{
	double best = 1e9;
	for (int d = 1; d <= 32; d++)
	{
		const int n = (int)lround(x * d);
		const double err = fabs((double)n / d - x);
		if (n >= 1 && err < best - 1e-9)
		{
			best = err;
			*num = n;
			*den = d;
		}
	}
}

static void InstallLock(NSWindow *w)
{
	const NSSize c = ContentSize(w);
	int a = 0, b = 0;
	const char *env = getenv("PVZH_ASPECT");
	if (env == NULL || sscanf(env, "%d:%d", &a, &b) != 2 || a <= 0 || b <= 0)
	{
		const long W = lround(c.width), H = lround(c.height);
		const long g = Gcd(W, H);
		a = g > 0 ? (int)(W / g) : 9;
		b = g > 0 ? (int)(H / g) : 5;
		if (a > 64 || b > 64)
			BestRatio(c.width / c.height, &a, &b);
	}
	const long g = Gcd(a, b);
	gUW = (int)(a / g);
	gUH = (int)(b / g);

	const NSSize minSize = [w contentMinSize];
	int minK = (int)ceil(kMinContentHeight / gUH);
	minK = (int)fmax(minK, ceil(minSize.width / gUW));
	minK = (int)fmax(minK, ceil(minSize.height / gUH));
	const int curK = (int)floor(fmin(c.width / gUW, c.height / gUH));
	gMinK = minK < curK ? minK : (curK > 1 ? curK : 1);

	if (gObserver == nil)
		gObserver = [[PvzhAspectObserver alloc] init];
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:gObserver selector:@selector(sizeChanged:) name:NSWindowDidResizeNotification object:w];
	[nc addObserver:gObserver selector:@selector(sizeChanged:) name:NSWindowDidEndLiveResizeNotification object:w];
	[nc addObserver:gObserver selector:@selector(sizeChanged:) name:NSWindowDidMoveNotification object:w];
	[nc addObserver:gObserver selector:@selector(sizeChanged:) name:NSWindowDidChangeScreenNotification object:w];
	[nc addObserver:gObserver selector:@selector(sizeChanged:) name:NSApplicationDidChangeScreenParametersNotification
		object:nil];
	[nc addObserver:gObserver selector:@selector(willEnterOrExitFullScreen:) name:NSWindowWillEnterFullScreenNotification
		object:w];
	[nc addObserver:gObserver selector:@selector(willEnterOrExitFullScreen:) name:NSWindowWillExitFullScreenNotification
		object:w];
	[nc addObserver:gObserver selector:@selector(didEnterFullScreen:) name:NSWindowDidEnterFullScreenNotification
		object:w];
	[nc addObserver:gObserver selector:@selector(didExitFullScreen:) name:NSWindowDidExitFullScreenNotification
		object:w];

	InstallDelegateHooks(w);
	InstallToggleHook(w);
	gLockInstalled = true;
	gFullscreenTransition = false;
	gSettled = IsExact(c) ? c : NSZeroSize;
	ApplyConstraint();
	if (!IsExact(c))
		MarkPending();
	Log("aspect: installed, content %gx%g, unit %d:%d, min %dx%d, max k %d", c.width, c.height, gUW, gUH, gMinK * gUW,
		gMinK * gUH, MaxK(w, [w screen]));
}

#pragma mark - Main window discovery

static bool ReadWindowId(NSWindow *w, long *out)
{
	Ivar iv = class_getInstanceVariable(object_getClass(w), "window_id");
	if (iv == NULL)
		return false;
	const char *type = ivar_getTypeEncoding(iv);
	const char *base = (const char *)(__bridge void *)w + ivar_getOffset(iv);
	if (type == NULL)
		return false;
	switch (type[0])
	{
		case 'i': *out = *(const int *)base; return true;
		case 'I': *out = *(const unsigned int *)base; return true;
		case 'q': *out = (long)*(const long long *)base; return true;
		case 'l': *out = *(const long *)base; return true;
		default: return false;
	}
}

static NSWindow *FindMainWindow(void)
{
	Class godotWindow = objc_getClass("GodotWindow");
	NSWindow *fallback = nil;
	for (NSWindow *w in [NSApp windows])
	{
		if (godotWindow != Nil && ![w isKindOfClass:godotWindow])
			continue;
		if (![w isVisible])
			continue;
		long wid = -1;
		if (ReadWindowId(w, &wid))
		{
			if (wid == 0)
				return w;
			continue;
		}
		if (fallback == nil && ([w styleMask] & NSWindowStyleMaskTitled) != 0)
			fallback = w;
	}
	return fallback;
}

static void InstallViewTrace(NSView *view);
static bool gTraceOn;
static void InstallCursorKeeperSwizzle(void);
static void InstallCursorKeeperView(NSWindow *w);
static void KeepCursor(void);

static void Tick(void)
{
	if (gWindow == nil)
	{
		if (gWindowGone)
			return;
		NSWindow *w = FindMainWindow();
		if (w == nil)
			return;
		gWindow = w;
		const NSRect f = [w frame];
		const NSSize c = ContentSize(w);
		Log("main window %s: frame %g,%g %gx%g, content %gx%g pt, backing scale %g, delegate %s", class_getName([w class]),
			f.origin.x, f.origin.y, f.size.width, f.size.height, c.width, c.height, [w backingScaleFactor],
			[w delegate] ? class_getName([[w delegate] class]) : "none");
		if (!gLockDisabled)
			InstallLock(w);
		else
		{
			// Still watch for the window closing so gWindow never dangles.
			if (gObserver == nil)
				gObserver = [[PvzhAspectObserver alloc] init];
			[[NSNotificationCenter defaultCenter] addObserver:gObserver selector:@selector(windowWillClose:)
				name:NSWindowWillCloseNotification object:w];
			Log("aspect lock disabled (PVZH_NO_ASPECT_LOCK)");
		}
		if (!gLockDisabled)
			[[NSNotificationCenter defaultCenter] addObserver:gObserver selector:@selector(windowWillClose:)
				name:NSWindowWillCloseNotification object:w];
		InstallCursorKeeperView(w);
		if (gTraceOn)
			InstallViewTrace([w contentView]);
		return;
	}
	AspectUpdate();
	KeepCursor();
}

static int gBootTries;
static void InstallIsolation(void);
static bool gIsolate;

static void Bootstrap(void)
{
	// Never create NSApplication here: Godot creates its own subclass (GodotApplication) during startup.
	if (NSApp == nil)
	{
		if (++gBootTries < 3000)
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
				Bootstrap();
			});
		return;
	}
	if (gTest && gIsolate)
		InstallIsolation();
	gTimer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) {
		(void)t;
		Tick();
	}];
	[[NSRunLoop mainRunLoop] addTimer:gTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - Cursor keeper

// The game uses custom cursors (the white enlarged arrow from addons/awesome_custom_cursor, set through Godot's
// Input.set_custom_mouse_cursor -> -[NSCursor set] in DisplayServerMacOS). On macOS, AppKit's tracking-area and window
// cursor handling switches the displayed cursor back to the system arrow afterwards, while Godot only calls -set again
// when the shape changes, so the white arrow showed only as a brief flicker on shape changes (seed packets, almanac).
// The keeper remembers the cursor Godot itself last set (a -set called directly from the engine binary) and, while the
// pointer is inside the game window's content, substitutes it synchronously for any other cursor AppKit tries to set
// (inset, so AppKit's window-edge resize cursors are left alone; not while the window is inactive or being resized).
// PVZH_NO_CURSOR_KEEP=1 turns it off.
// Two more things defeat a plain -set (both seen in a diagnostic run with a sampler of the displayed cursor):
//  1. The window server shows the system arrow again on its own, without any NSCursor call in the app, for example
//     when the app finishes activating. AppKit still believes the game's cursor is current, so -set returns early and
//     the arrow stays until the cursor shape changes. The keeper therefore watches the window server's cursor seed
//     (CGSCurrentCursorSeed, bumped on every displayed-cursor change) and, when it moved without the keeper's own
//     cursor reaching the screen, re-sends the game's cursor with -forceSet.
//  2. Godot keeps one NSCursor per cursor shape, and the addon gives several shapes the same picture. Moving across
//     controls with different shapes switched the displayed cursor between identical-looking objects many times a
//     second. Engine cursors are folded onto one object per picture and hotspot, so those switches no longer reach the
//     window server.
// While AppKit shows a window-edge resize override cursor (+_setOverrideCursor:type: with a cursor) the keeper stays
// out of the way, so the resize cursors at the window border keep working.
typedef void (*CursorSetFn)(id, SEL);
typedef void (*OverrideFn)(id, SEL, id, long);
typedef int (*CursorSeedFn)(void);
static CursorSetFn gOrigCursorSet, gOrigReallySet, gOrigForceSet;
static OverrideFn gOrigSetOverride;
static CursorSeedFn gCursorSeed;
static NSCursor *gWantedCursor;
static bool gCursorKeepOff;
static bool gOverrideActive;		// AppKit override cursor (edge resize, split-view divider) on screen
static long gOverrideType;
static int gShownSeed = -1;			// window-server cursor seed right after the game's cursor last reached the screen
static long gRestores;
static const void *gMainBase;
static NSMutableArray<NSCursor *> *gCanonical;	// one engine cursor per distinct picture + hotspot
static char gFingerprintKey;

static bool CalledFromEngine(void *returnAddress)
{
	Dl_info info;
	return gMainBase != NULL && dladdr(returnAddress, &info) && info.dli_fbase == gMainBase;
}

static bool PointerInGameContent(void)
{
	NSWindow *w = gWindow;
	if (w == nil || ![NSApp isActive] || ![w isKeyWindow] || [w inLiveResize])
		return false;
	if ([w isMiniaturized])
		return false;
	NSView *content = [w contentView];
	if (content == nil)
		return false;
	const NSPoint inWindow = [w mouseLocationOutsideOfEventStream];
	const NSPoint p = [content convertPoint:inWindow fromView:nil];
	// Windowed: leave a 6 pt border to AppKit's window-edge resize cursors. Fullscreen has no resize border, and an inset
	// would only leave a strip along the screen edges where the system arrow could stay.
	const CGFloat inset = ([w styleMask] & NSWindowStyleMaskFullScreen) != 0 ? 0.0 : 6.0;
	const NSRect inner = NSInsetRect([content bounds], inset, inset);
	if (!NSPointInRect(p, inner))
		return false;
	// Not when another window (a panel, notification or another app's window) is over the game at that point.
	return [NSWindow windowNumberAtPoint:[NSEvent mouseLocation] belowWindowWithWindowNumber:0] == [w windowNumber];
}

static NSData *CursorFingerprint(NSCursor *c)
{
	NSData *fp = objc_getAssociatedObject(c, &gFingerprintKey);
	if (fp != nil)
		return fp;
	NSMutableData *d = [NSMutableData data];
	const NSPoint hot = [c hotSpot];
	const NSSize size = [[c image] size];
	const double head[4] = {hot.x, hot.y, size.width, size.height};
	[d appendBytes:head length:sizeof head];
	NSData *tiff = [[c image] TIFFRepresentation];
	if (tiff != nil)
		[d appendData:tiff];
	objc_setAssociatedObject(c, &gFingerprintKey, d, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
	return d;
}

// The first engine cursor seen with this picture and hotspot (a custom cursor from Godot is only replaced by another
// object when its image changes, so the list stays a handful long).
static NSCursor *CanonicalCursor(NSCursor *c)
{
	if (gCanonical == nil)
		gCanonical = [NSMutableArray array];
	NSData *fp = CursorFingerprint(c);
	for (NSCursor *k in gCanonical)
		if (k == c || [CursorFingerprint(k) isEqualToData:fp])
			return k;
	if ([gCanonical count] >= 64)
		[gCanonical removeObjectAtIndex:0];
	[gCanonical addObject:c];
	return c;
}

static void NoteShown(id cursor)
{
	if (cursor == gWantedCursor && gCursorSeed != NULL)
		gShownSeed = gCursorSeed();
}

// Re-send the game's cursor when the window server is showing something else (seed moved since the game's cursor last
// reached the screen) while the pointer is over the game.
// -forceSet is only [self set] on current AppKit, so the restore re-enters PvzhCursorSet (which calls KeepCursor), and
// while an AppKit override cursor is active -set only records the cursor without reaching the window server. Hence the
// re-entrancy guard and recording the seed before the restore: a restore AppKit suppresses is not repeated.
static void KeepCursor(void)
{
	static bool busy;
	if (busy || gCursorKeepOff || gWantedCursor == nil || gOrigForceSet == NULL || gCursorSeed == NULL || gOverrideActive)
		return;
	if (gCursorSeed() == gShownSeed || !PointerInGameContent())
		return;
	busy = true;
	gShownSeed = gCursorSeed();
	gOrigForceSet(gWantedCursor, NSSelectorFromString(@"forceSet"));
	gShownSeed = gCursorSeed();
	busy = false;
	if (gLog && (++gRestores <= 20 || gRestores % 100 == 0))
		Log("cursor: window server showed another cursor over the game, restored (%ld)", gRestores);
}

static bool SubstituteCursor(id self)
{
	return !gCursorKeepOff && !gOverrideActive && gWantedCursor != nil && self != gWantedCursor &&
		PointerInGameContent();
}

// AppKit also changes the cursor below -set: cursor-rect and tracking-area code and +_clearOverrideCursorAndSetArrow call
// the private -_reallySet (and -forceSet) directly. Guard those too. The engine's own -set passes through here with
// self == gWantedCursor.
static void PvzhCursorReallySet(id self, SEL _cmd)
{
	if (SubstituteCursor(self))
		self = gWantedCursor;
	gOrigReallySet(self, _cmd);
	NoteShown(self);
}

static void PvzhCursorForceSet(id self, SEL _cmd)
{
	if (SubstituteCursor(self))
		self = gWantedCursor;
	gOrigForceSet(self, _cmd);
	NoteShown(self);
}

// Mirrors AppKit's rule (+[NSCursor _setOverrideCursor:type:]): a cursor always installs the override; nil clears it only
// for type 0 or the type that installed it (edge resizing uses 1 on every mouse move, the split-view divider 2).
static void PvzhSetOverrideCursor(id self, SEL _cmd, id cursor, long type)
{
	if (cursor != nil)
	{
		gOverrideActive = true;
		gOverrideType = type;
	}
	else if (type == 0 || type == gOverrideType)
	{
		gOverrideActive = false;
		gOverrideType = 0;
	}
	gOrigSetOverride(self, _cmd, cursor, type);
	if (!gOverrideActive)
		KeepCursor();
}

static void PvzhCursorSet(id self, SEL _cmd)
{
	const bool fromEngine = CalledFromEngine(__builtin_return_address(0));
	if (fromEngine)
	{
		NSCursor *c = CanonicalCursor((NSCursor *)self);
		if (gWantedCursor != c)
		{
			gWantedCursor = c;
			if (gLog)
				Log("cursor: engine set %.0fx%.0f cursor", [[c image] size].width, [[c image] size].height);
		}
		self = c;
	}
	else if (gLog)
		Log("cursor: AppKit set %.0fx%.0f cursor", [[(NSCursor *)self image] size].width,
			[[(NSCursor *)self image] size].height);
	if (!fromEngine && SubstituteCursor(self))
	{
		// AppKit tries to reset the cursor (tracking areas / cursor rects on mouse moves, key-window changes) while the
		// pointer is over the game: show the game's cursor instead of letting the system arrow through for a frame.
		// Correcting it afterwards (the first version) made both cursors flicker while the mouse moved.
		self = gWantedCursor;
	}
	gOrigCursorSet(self, _cmd);
	KeepCursor();
}

typedef void (*ViewEventFn)(id, SEL, NSEvent *);
static ViewEventFn gOrigMoved, gOrigDragged, gOrigCursorUpdate, gOrigEntered;
static void PvzhViewMoved(id self, SEL _cmd, NSEvent *e) { if (gOrigMoved) gOrigMoved(self, _cmd, e); KeepCursor(); }
static void PvzhViewDragged(id self, SEL _cmd, NSEvent *e) { if (gOrigDragged) gOrigDragged(self, _cmd, e); KeepCursor(); }
static void PvzhViewCursorUpdate(id self, SEL _cmd, NSEvent *e) { if (gOrigCursorUpdate) gOrigCursorUpdate(self, _cmd, e); KeepCursor(); }
static void PvzhViewEntered(id self, SEL _cmd, NSEvent *e) { if (gOrigEntered) gOrigEntered(self, _cmd, e); KeepCursor(); }

static void HookViewSelector(Class cls, SEL sel, IMP replacement, ViewEventFn *orig)
{
	Method m = class_getInstanceMethod(cls, sel);
	if (m == NULL)
		return;
	*orig = (ViewEventFn)method_getImplementation(m);
	// Add on the concrete class (the method may be inherited); replace if the class defines it itself.
	if (!class_addMethod(cls, sel, replacement, method_getTypeEncoding(m)))
		*orig = (ViewEventFn)class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(m));
}

static void InstallCursorKeeperSwizzle(void)
{
	const char *off = getenv("PVZH_NO_CURSOR_KEEP");
	gCursorKeepOff = off != NULL && atoi(off) != 0;
	if (gCursorKeepOff)
		return;
	// The engine image is the one MH_EXECUTE image (image index 0 is not reliable with DYLD_INSERT_LIBRARIES).
	for (uint32_t i = 0; i < _dyld_image_count(); i++)
	{
		const struct mach_header *h = _dyld_get_image_header(i);
		if (h != NULL && h->filetype == MH_EXECUTE)
		{
			gMainBase = h;
			break;
		}
	}
	Method m = class_getInstanceMethod([NSCursor class], @selector(set));
	if (m != NULL)
		gOrigCursorSet = (CursorSetFn)method_setImplementation(m, (IMP)PvzhCursorSet);
	m = class_getInstanceMethod([NSCursor class], NSSelectorFromString(@"_reallySet"));
	if (m != NULL)
		gOrigReallySet = (CursorSetFn)method_setImplementation(m, (IMP)PvzhCursorReallySet);
	m = class_getInstanceMethod([NSCursor class], NSSelectorFromString(@"forceSet"));
	if (m != NULL)
		gOrigForceSet = (CursorSetFn)method_setImplementation(m, (IMP)PvzhCursorForceSet);
	m = class_getClassMethod([NSCursor class], NSSelectorFromString(@"_setOverrideCursor:type:"));
	if (m != NULL)
		gOrigSetOverride = (OverrideFn)method_setImplementation(m, (IMP)PvzhSetOverrideCursor);
	gCursorSeed = (CursorSeedFn)dlsym(RTLD_DEFAULT, "CGSCurrentCursorSeed");
	if (gCursorSeed == NULL)
		Log("cursor: CGSCurrentCursorSeed not found, window-server resets are not repaired");
}

static void InstallCursorKeeperView(NSWindow *w)
{
	static bool installed;
	if (installed || gCursorKeepOff || w == nil || [w contentView] == nil)
		return;
	installed = true;
	Class cls = [[w contentView] class];
	HookViewSelector(cls, @selector(mouseMoved:), (IMP)PvzhViewMoved, &gOrigMoved);
	HookViewSelector(cls, @selector(mouseDragged:), (IMP)PvzhViewDragged, &gOrigDragged);
	HookViewSelector(cls, @selector(cursorUpdate:), (IMP)PvzhViewCursorUpdate, &gOrigCursorUpdate);
	HookViewSelector(cls, @selector(mouseEntered:), (IMP)PvzhViewEntered, &gOrigEntered);
	// The 50 ms Tick is too slow to hide a window-server reset while the pointer rests; check the seed every 8 ms
	// (one shared-memory read when nothing changed).
	NSTimer *t = [NSTimer timerWithTimeInterval:0.008 repeats:YES block:^(NSTimer *timer) {
		(void)timer;
		KeepCursor();
	}];
	[[NSRunLoop mainRunLoop] addTimer:t forMode:NSRunLoopCommonModes];
	Log("cursor keeper on (%s)", class_getName(cls));
}

#pragma mark - Test driver (PVZH_TEST_SCRIPT only)

typedef NSPoint (*MouseLocationFn)(id, SEL);
typedef NSUInteger (*PressedButtonsFn)(id, SEL);
typedef id (*NextDrawableFn)(id, SEL);

static MouseLocationFn gOrigMouseLocation;
static PressedButtonsFn gOrigPressedButtons;
static NextDrawableFn gOrigNextDrawable;
static volatile bool gVMouseValid;
static volatile double gVMouseX, gVMouseY;		// scripted pointer, screen coordinates (points, bottom-left origin)
static volatile NSUInteger gVButtons;			// scripted buttons (bit 0 left, bit 1 right)
static __unsafe_unretained NSWindow *gVOver;	// game window whose content holds the scripted pointer
// Scripted pointer events carry two device-dependent modifier bits that no device sets (0x0800 and 0x4000; AppKit
// re-creates posted events and keeps only 16 bits of the event number, but keeps the flags). Godot reads only the
// device-independent shift/control/option/command bits of mouse events.
static const NSEventModifierFlags kSyntheticFlags = 0x4800;
static NSInteger gEventNumber;
static char *gScript;
static bool gScriptFromFile;
static double gBaseW = 1080, gBaseH = 600;		// base viewport (PVZH_TEST_BASE=WxH)
static int gHoldMs = 80;						// click hold time (PVZH_TEST_CLICK_MS)

static NSPoint PvzhMouseLocation(id self, SEL _cmd)
{
	if (gVMouseValid)
		return NSMakePoint(gVMouseX, gVMouseY);
	return gOrigMouseLocation(self, _cmd);
}

static NSUInteger PvzhPressedMouseButtons(id self, SEL _cmd)
{
	return gOrigPressedButtons(self, _cmd) | gVButtons;
}

static id PvzhNextDrawable(id self, SEL _cmd)
{
	atomic_fetch_add(&gFrames, 1);
	return gOrigNextDrawable(self, _cmd);
}

static void InstallTestSwizzles(void)
{
	Class eventMeta = objc_getMetaClass("NSEvent");
	Method m = class_getInstanceMethod(eventMeta, @selector(mouseLocation));
	if (m != NULL)
		gOrigMouseLocation = (MouseLocationFn)method_setImplementation(m, (IMP)PvzhMouseLocation);
	m = class_getInstanceMethod(eventMeta, @selector(pressedMouseButtons));
	if (m != NULL)
		gOrigPressedButtons = (PressedButtonsFn)method_setImplementation(m, (IMP)PvzhPressedMouseButtons);
	Class metalLayer = objc_getClass("CAMetalLayer");
	m = metalLayer != Nil ? class_getInstanceMethod(metalLayer, @selector(nextDrawable)) : NULL;
	if (m != NULL)
		gOrigNextDrawable = (NextDrawableFn)method_setImplementation(m, (IMP)PvzhNextDrawable);
}

// PVZH_TEST_TRACE=1 (test mode only): log every mouse and key event Godot's content view receives.
typedef void (*ViewEventFn)(id, SEL, NSEvent *);
static struct
{
	SEL sel;
	ViewEventFn orig;
} gTrace[16];
static int gTraceCount;

static void PvzhTraceViewEvent(id self, SEL _cmd, NSEvent *e)
{
	ViewEventFn orig = NULL;
	for (int i = 0; i < gTraceCount; i++)
		if (gTrace[i].sel == _cmd)
			orig = gTrace[i].orig;
	const NSPoint p = [e locationInWindow];
	TLog("  view %s at window point %.1f,%.1f (buttons %lu)", sel_getName(_cmd), p.x, p.y,
		(unsigned long)[NSEvent pressedMouseButtons]);
	if (orig != NULL)
		orig(self, _cmd, e);
}

static void InstallViewTrace(NSView *view)
{
	static bool done;
	if (done || view == nil)
		return;
	done = true;
	Class cls = object_getClass(view);
	const char *names[] = { "mouseDown:", "mouseUp:", "mouseMoved:", "mouseDragged:", "rightMouseDown:",
		"rightMouseUp:", "mouseEntered:", "mouseExited:", "keyDown:", "keyUp:" };
	for (size_t i = 0; i < sizeof names / sizeof names[0] && gTraceCount < 16; i++)
	{
		const SEL sel = sel_registerName(names[i]);
		Method m = class_getInstanceMethod(cls, sel);
		if (m == NULL)
			continue;
		IMP inherited = method_getImplementation(m);
		ViewEventFn orig;
		if (class_addMethod(cls, sel, (IMP)PvzhTraceViewEvent, method_getTypeEncoding(m)))
			orig = (ViewEventFn)inherited;		// inherited from NSView: wrap it on this class only
		else
			orig = (ViewEventFn)method_setImplementation(m, (IMP)PvzhTraceViewEvent);
		gTrace[gTraceCount].sel = sel;
		gTrace[gTraceCount].orig = orig;
		gTraceCount++;
	}
	TLog("  tracing %d event methods of %s", gTraceCount, class_getName(cls));
}

// Test isolation (on by default in test mode, PVZH_TEST_ISOLATE=0 turns it off): pointer events from the real mouse
// never reach the game while a script runs. The game window runs in the background, and a user moving the real
// pointer across its visible part would otherwise send real enter/move/exit events between the scripted ones (Godot
// then believes the pointer left the window and stops hovering and clicking controls).
typedef void (*SendEventFn)(id, SEL, NSEvent *);
static SendEventFn gOrigSendEvent;
static long gDropped;

static void PvzhSendEvent(id self, SEL _cmd, NSEvent *e)
{
	if (gIsolate)
	{
		switch ([e type])
		{
			case NSEventTypeLeftMouseDown: case NSEventTypeLeftMouseUp: case NSEventTypeRightMouseDown:
			case NSEventTypeRightMouseUp: case NSEventTypeOtherMouseDown: case NSEventTypeOtherMouseUp:
			case NSEventTypeMouseMoved: case NSEventTypeLeftMouseDragged: case NSEventTypeRightMouseDragged:
			case NSEventTypeOtherMouseDragged:
				if (([e modifierFlags] & kSyntheticFlags) == kSyntheticFlags)
					break;
				// fall through: a real pointer event
			case NSEventTypeMouseEntered: case NSEventTypeMouseExited: case NSEventTypeScrollWheel:
			case NSEventTypeCursorUpdate:
				if (++gDropped <= 3 || gTraceOn)
					TLog("  dropped a real pointer event (type %ld)%s", (long)[e type],
						gDropped == 3 && !gTraceOn ? "; further drops are not logged" : "");
				return;
			default:
				break;
		}
	}
	gOrigSendEvent(self, _cmd, e);
}

static void InstallIsolation(void)
{
	Method m = class_getInstanceMethod(object_getClass(NSApp), @selector(sendEvent:));
	if (m == NULL)
		return;
	IMP inherited = method_getImplementation(m);
	if (class_addMethod(object_getClass(NSApp), @selector(sendEvent:), (IMP)PvzhSendEvent, method_getTypeEncoding(m)))
		gOrigSendEvent = (SendEventFn)inherited;
	else
		gOrigSendEvent = (SendEventFn)method_setImplementation(m, (IMP)PvzhSendEvent);
}

static void RunOnMain(void (^block)(void))
{
	dispatch_sync(dispatch_get_main_queue(), block);
}

static void SleepMs(double ms)
{
	if (ms > 0)
		usleep((useconds_t)(ms * 1000));
}

// Logical (base viewport) coordinates -> content points from the top-left of the window content, for stretch mode
// canvas_items with aspect keep_height: a wider window shows more width (scale from the height, x from the left
// edge), a narrower one is letterboxed (scale from the width, centred vertically).
static NSPoint LogicalToContent(NSWindow *w, double x, double y)
{
	const NSSize c = ContentSize(w);
	if (c.width / c.height >= gBaseW / gBaseH)
	{
		const double s = c.height / gBaseH;
		return NSMakePoint(x * s, y * s);
	}
	const double s = c.width / gBaseW;
	return NSMakePoint(x * s, (c.height - gBaseH * s) / 2 + y * s);
}

static NSWindow *OurWindowAt(NSPoint screen)
{
	for (NSWindow *w in [NSApp orderedWindows])
		if ([w isVisible] && ![w ignoresMouseEvents] && NSPointInRect(screen, [w frame]))
			return w;
	return nil;
}

static void SendEnterExit(NSWindow *w, NSPoint screen, bool entered)
{
	NSView *view = [w contentView];
	NSEvent *e = [NSEvent enterExitEventWithType:entered ? NSEventTypeMouseEntered : NSEventTypeMouseExited
		location:NSMakePoint(screen.x - NSMinX([w frame]), screen.y - NSMinY([w frame])) modifierFlags:0
		timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:[w windowNumber] context:nil
		eventNumber:++gEventNumber trackingNumber:0 userData:NULL];
	if (entered && [view respondsToSelector:@selector(mouseEntered:)])
		[view mouseEntered:e];
	else if (!entered && [view respondsToSelector:@selector(mouseExited:)])
		[view mouseExited:e];
}

// The real pointer is somewhere else, so AppKit's tracking areas never report the scripted pointer entering or
// leaving a window, and Godot only hovers controls of a window it believes the pointer is in: send the content view
// of the game window (main window or a non-embedded popup) under the scripted pointer its enter/exit messages.
static void UpdateEnterExit(NSWindow *target, NSPoint screen)
{
	NSWindow *over = nil;
	if (target != nil && NSPointInRect(screen, [target contentRectForFrameRect:[target frame]]))
		over = target;
	if (over == gVOver)
		return;
	if (gVOver != nil && [[NSApp windows] containsObject:gVOver])
		SendEnterExit(gVOver, screen, false);
	gVOver = over;
	if (over != nil)
		SendEnterExit(over, screen, true);
}

enum { OpMove, OpLDown, OpLUp, OpRDown, OpRUp };

// Must run on the main thread. (cx, cy): content points from the top-left of the main window's content.
static void PostMouse(int op, double cx, double cy, NSInteger clicks)
{
	NSWindow *mainWindow = gWindow;
	if (mainWindow == nil)
	{
		TLog("  error: no game window");
		return;
	}
	const NSRect content = [mainWindow contentRectForFrameRect:[mainWindow frame]];
	const NSPoint screen = NSMakePoint(NSMinX(content) + cx, NSMaxY(content) - cy);
	NSWindow *target = OurWindowAt(screen);
	gVMouseX = screen.x;
	gVMouseY = screen.y;
	gVMouseValid = true;
	UpdateEnterExit(target, screen);
	if (target == nil)
		target = mainWindow;		// outside every game window (e.g. a resize border): address the main window

	NSEventType type;
	float pressure = 0;
	switch (op)
	{
		case OpLDown: gVButtons |= 1; type = NSEventTypeLeftMouseDown; pressure = 1; break;
		case OpLUp: gVButtons &= ~(NSUInteger)1; type = NSEventTypeLeftMouseUp; break;
		case OpRDown: gVButtons |= 2; type = NSEventTypeRightMouseDown; pressure = 1; break;
		case OpRUp: gVButtons &= ~(NSUInteger)2; type = NSEventTypeRightMouseUp; break;
		default:
			if (gVButtons & 1) { type = NSEventTypeLeftMouseDragged; pressure = 1; }
			else if (gVButtons & 2) { type = NSEventTypeRightMouseDragged; pressure = 1; }
			else type = NSEventTypeMouseMoved;
			break;
	}
	const NSPoint loc = NSMakePoint(screen.x - NSMinX([target frame]), screen.y - NSMinY([target frame]));
	NSEvent *e = [NSEvent mouseEventWithType:type location:loc modifierFlags:kSyntheticFlags
		timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:[target windowNumber] context:nil
		eventNumber:++gEventNumber clickCount:op == OpMove ? 0 : clicks pressure:pressure];
	[NSApp postEvent:e atStart:NO];
}

static void MouseAt(bool logical, int op, double x, double y, NSInteger clicks)
{
	RunOnMain(^{
		NSWindow *w = gWindow;
		NSPoint p = NSMakePoint(x, y);
		if (logical && w != nil)
			p = LogicalToContent(w, x, y);
		PostMouse(op, p.x, p.y, clicks);
	});
}

static void Click(bool logical, bool right, double x, double y, int count)
{
	MouseAt(logical, OpMove, x, y, 0);
	SleepMs(50);
	for (int i = 1; i <= count; i++)
	{
		MouseAt(logical, right ? OpRDown : OpLDown, x, y, i);
		SleepMs(gHoldMs);
		MouseAt(logical, right ? OpRUp : OpLUp, x, y, i);
		if (i < count)
			SleepMs(60);
	}
}

static void Drag(bool logical, double x1, double y1, double x2, double y2, double ms)
{
	MouseAt(logical, OpMove, x1, y1, 0);
	SleepMs(50);
	MouseAt(logical, OpLDown, x1, y1, 1);
	SleepMs(50);
	const int steps = ms > 16 ? (int)(ms / 16) : 1;
	for (int i = 1; i <= steps; i++)
	{
		const double t = (double)i / steps;
		MouseAt(logical, OpMove, x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, 0);
		SleepMs(ms / steps);
	}
	SleepMs(50);
	MouseAt(logical, OpLUp, x2, y2, 1);
}

// US ANSI virtual key codes for printable characters.
static const struct { char c; unsigned short code; } kKeyTable[] = {
	{ 'a', 0 }, { 's', 1 }, { 'd', 2 }, { 'f', 3 }, { 'h', 4 }, { 'g', 5 }, { 'z', 6 }, { 'x', 7 }, { 'c', 8 },
	{ 'v', 9 }, { 'b', 11 }, { 'q', 12 }, { 'w', 13 }, { 'e', 14 }, { 'r', 15 }, { 'y', 16 }, { 't', 17 },
	{ '1', 18 }, { '2', 19 }, { '3', 20 }, { '4', 21 }, { '6', 22 }, { '5', 23 }, { '=', 24 }, { '9', 25 },
	{ '7', 26 }, { '-', 27 }, { '8', 28 }, { '0', 29 }, { ']', 30 }, { 'o', 31 }, { 'u', 32 }, { '[', 33 },
	{ 'i', 34 }, { 'p', 35 }, { 'l', 37 }, { 'j', 38 }, { '\'', 39 }, { 'k', 40 }, { ';', 41 }, { '\\', 42 },
	{ ',', 43 }, { '/', 44 }, { 'n', 45 }, { 'm', 46 }, { '.', 47 }, { ' ', 49 }, { '`', 50 },
};

static NSString *CharactersForKeyCode(unsigned short code)
{
	unichar u = 0;
	switch (code)
	{
		case 36: u = '\r'; break;
		case 48: u = '\t'; break;
		case 51: u = 0x7f; break;
		case 53: u = 0x1b; break;
		case 76: u = 0x03; break;
		case 117: u = NSDeleteFunctionKey; break;
		case 123: u = NSLeftArrowFunctionKey; break;
		case 124: u = NSRightArrowFunctionKey; break;
		case 125: u = NSDownArrowFunctionKey; break;
		case 126: u = NSUpArrowFunctionKey; break;
		case 122: u = NSF1FunctionKey; break;
		case 120: u = NSF2FunctionKey; break;
		case 99: u = NSF3FunctionKey; break;
		case 118: u = NSF4FunctionKey; break;
		case 96: u = NSF5FunctionKey; break;
		case 97: u = NSF6FunctionKey; break;
		case 98: u = NSF7FunctionKey; break;
		case 100: u = NSF8FunctionKey; break;
		case 101: u = NSF9FunctionKey; break;
		case 109: u = NSF10FunctionKey; break;
		case 103: u = NSF11FunctionKey; break;
		case 111: u = NSF12FunctionKey; break;
		default:
			for (size_t i = 0; i < sizeof kKeyTable / sizeof kKeyTable[0]; i++)
				if (kKeyTable[i].code == code)
					u = (unichar)kKeyTable[i].c;
			break;
	}
	return u != 0 ? [NSString stringWithCharacters:&u length:1] : @"";
}

static void Key(unsigned short code, NSString *chars)
{
	for (int down = 1; down >= 0; down--)
	{
		RunOnMain(^{
			NSWindow *w = gWindow;
			if (w == nil)
			{
				TLog("  error: no game window");
				return;
			}
			NSEvent *e = [NSEvent keyEventWithType:down ? NSEventTypeKeyDown : NSEventTypeKeyUp location:NSZeroPoint
				modifierFlags:0 timestamp:[[NSProcessInfo processInfo] systemUptime] windowNumber:[w windowNumber]
				context:nil characters:chars charactersIgnoringModifiers:chars isARepeat:NO keyCode:code];
			// Key events go to the key window; a background test window gets them directly.
			if ([w isKeyWindow])
				[NSApp postEvent:e atStart:NO];
			else
				[w sendEvent:e];
		});
		if (down)
			SleepMs(60);
	}
}

static void LogWindow(const char *what)
{
	char line[512] = "no game window";
	char *out = line;
	RunOnMain(^{
		NSWindow *w = gWindow;
		if (w == nil)
			return;
		const NSRect f = [w frame];
		const NSSize c = ContentSize(w);
		snprintf(out, 512,
			"%s: frame %g,%g %gx%g pt, content %gx%g pt (%gx%g px), backing scale %g, ratio %.5f, unit %d:%d, "
			"constraint %s, key %d, fullscreen %d, zoomed %d",
			what, f.origin.x, f.origin.y, f.size.width, f.size.height, c.width, c.height,
			c.width * [w backingScaleFactor], c.height * [w backingScaleFactor], [w backingScaleFactor],
			c.width / c.height, gUW, gUH, gConstraintOn ? "on" : "off", [w isKeyWindow] ? 1 : 0,
			([w styleMask] & NSWindowStyleMaskFullScreen) ? 1 : 0, [w isZoomed] ? 1 : 0);
	});
	TLog("  %s", line);
}

static void SetWindowSize(double width, double height)
{
	RunOnMain(^{
		NSWindow *w = gWindow;
		if (w == nil)
			return;
		const NSRect f = [w frame];
		NSRect target = [w frameRectForContentRect:NSMakeRect(0, 0, width, height)];
		target.origin.x = f.origin.x;
		target.origin.y = NSMaxY(f) - target.size.height;		// keep the top-left corner
		[w setFrame:target display:YES];
	});
}

static char *Trim(char *s)
{
	while (*s == ' ' || *s == '\t' || *s == '\r')
		s++;
	size_t n = strlen(s);
	while (n > 0 && (s[n - 1] == ' ' || s[n - 1] == '\t' || s[n - 1] == '\r'))
		s[--n] = '\0';
	return s;
}

static bool RunCommand(char *line)
{
	char cmd[32] = "";
	double a = 0, b = 0, c = 0, d = 0, e = 0;
	if (sscanf(line, "%31s", cmd) != 1)
		return true;
	const char *rest = line + strlen(cmd);
	while (*rest == ' ' || *rest == '\t')
		rest++;
	TLog("%s", line);

	bool logical = true;
	const char *op = cmd;
	if (cmd[0] == 'w' && (strcmp(cmd, "waitwin") != 0 && strcmp(cmd, "winsize") != 0))
	{
		logical = false;		// wmove, wclick, wrclick, wdclick, wdown, wup, wdrag: window content points
		op = cmd + 1;
	}

	if (strcmp(cmd, "ms") == 0)
		SleepMs(atof(rest));
	else if (strcmp(cmd, "log") == 0)
		;
	else if (strcmp(cmd, "waitwin") == 0)
	{
		const double timeout = *rest ? atof(rest) : 180;
		const double start = Now();
		__block bool found = false;
		while (!found && Now() - start < timeout)
		{
			RunOnMain(^{
				found = gWindow != nil && [gWindow isVisible];
			});
			if (!found)
				SleepMs(50);
		}
		if (found)
			LogWindow("window");
		else
			TLog("  error: no game window after %gs", timeout);
	}
	else if (strcmp(cmd, "logwin") == 0)
		LogWindow("window");
	else if (strcmp(cmd, "winsize") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
	{
		SetWindowSize(a, b);
		LogWindow("after winsize");
	}
	else if (strcmp(op, "move") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
		MouseAt(logical, OpMove, a, b, 0);
	else if (strcmp(op, "click") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
		Click(logical, false, a, b, 1);
	else if (strcmp(op, "dclick") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
		Click(logical, false, a, b, 2);
	else if (strcmp(op, "rclick") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
		Click(logical, true, a, b, 1);
	else if (strcmp(op, "down") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
		MouseAt(logical, OpLDown, a, b, 1);
	else if (strcmp(op, "up") == 0 && sscanf(rest, "%lf %lf", &a, &b) == 2)
		MouseAt(logical, OpLUp, a, b, 1);
	else if (strcmp(op, "drag") == 0 && sscanf(rest, "%lf %lf %lf %lf %lf", &a, &b, &c, &d, &e) == 5)
		Drag(logical, a, b, c, d, e);
	else if (strcmp(cmd, "key") == 0 && *rest)
	{
		const unsigned short code = (unsigned short)strtoul(rest, NULL, 0);
		Key(code, CharactersForKeyCode(code));
	}
	else if (strcmp(cmd, "char") == 0 && *rest)
	{
		NSString *s = [NSString stringWithUTF8String:rest];
		if (s.length == 0)
			s = @" ";
		s = [s substringToIndex:1];
		unsigned short code = 0x7f;
		const unichar u = [[s lowercaseString] characterAtIndex:0];
		for (size_t i = 0; i < sizeof kKeyTable / sizeof kKeyTable[0]; i++)
			if ((unichar)kKeyTable[i].c == u)
				code = kKeyTable[i].code;
		Key(code, s);
	}
	else if (strcmp(cmd, "quit") == 0)
	{
		// Godot answers -terminate: with a close request to its main window (the game's normal quit path).
		dispatch_async(dispatch_get_main_queue(), ^{
			[NSApp terminate:nil];
		});
		return false;
	}
	else
		TLog("  error: unknown or malformed command");
	return true;
}

static void *TestRunner(void *arg)
{
	(void)arg;
	@autoreleasepool
	{
		pthread_setname_np("PvzhTestDriver");
		char *script = gScript;
		// Inline scripts may separate commands with ';'; a script file is line based.
		const char *separators = gScriptFromFile ? "\n" : ";\n";
		char *save = NULL;
		for (char *tok = strtok_r(script, separators, &save); tok != NULL; tok = strtok_r(NULL, separators, &save))
		{
			char *line = Trim(tok);
			if (*line == '\0' || *line == '#')
				continue;
			if (!RunCommand(line))
				break;
		}
		TLog("end of script");
	}
	return NULL;
}

static void StartTestDriver(const char *value)
{
	FILE *f = fopen(value, "r");
	if (f != NULL)
	{
		fseek(f, 0, SEEK_END);
		const long n = ftell(f);
		fseek(f, 0, SEEK_SET);
		gScript = calloc((size_t)(n > 0 ? n : 0) + 1, 1);
		if (gScript != NULL && n > 0)
			gScript[fread(gScript, 1, (size_t)n, f)] = '\0';
		fclose(f);
		gScriptFromFile = true;
	}
	else
		gScript = strdup(value);
	if (gScript == NULL)
		return;
	const char *base = getenv("PVZH_TEST_BASE");
	double bw = 0, bh = 0;
	if (base != NULL && sscanf(base, "%lfx%lf", &bw, &bh) == 2 && bw > 0 && bh > 0)
	{
		gBaseW = bw;
		gBaseH = bh;
	}
	const char *hold = getenv("PVZH_TEST_CLICK_MS");
	if (hold != NULL && atoi(hold) > 0)
		gHoldMs = atoi(hold);
	InstallTestSwizzles();
	const char *isolate = getenv("PVZH_TEST_ISOLATE");
	gIsolate = isolate == NULL || atoi(isolate) != 0;
	const char *trace = getenv("PVZH_TEST_TRACE");
	gTraceOn = trace != NULL && atoi(trace) != 0;
	pthread_t thread;
	pthread_attr_t attr;
	pthread_attr_init(&attr);
	pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
	pthread_create(&thread, &attr, TestRunner, NULL);
	pthread_attr_destroy(&attr);
}

#pragma mark - Entry

// True when the main executable lives in Contents/MacOS of the bundle that contains this library.
static bool IsGameProcess(void)
{
	Dl_info info;
	if (!dladdr((const void *)&IsGameProcess, &info) || info.dli_fname == NULL)
		return false;
	char lib[PATH_MAX], exe[PATH_MAX], exeReal[PATH_MAX];
	if (realpath(info.dli_fname, lib) == NULL)
		return false;
	uint32_t size = sizeof exe;
	if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, exeReal) == NULL)
		return false;
	char *p = strrchr(lib, '/');
	if (p == NULL)
		return false;
	*p = '\0';
	p = strrchr(lib, '/');
	if (p == NULL || strcmp(p, "/Frameworks") != 0)
		return false;
	*p = '\0';				// lib = <bundle>/Contents
	const size_t n = strlen(lib);
	return strncmp(exeReal, lib, n) == 0 && strncmp(exeReal + n, "/MacOS/", 7) == 0;
}

__attribute__((constructor)) static void PvzhInit(void)
{
	gT0 = Now();
	if (!IsGameProcess())
		return;
	const char *script = getenv("PVZH_TEST_SCRIPT");
	gTest = script != NULL && script[0] != '\0';
	gLog = gTest || getenv("PVZH_LOG") != NULL;
	const char *noLock = getenv("PVZH_NO_ASPECT_LOCK");
	gLockDisabled = noLock != NULL && atoi(noLock) != 0;
	Log("libPvzHybridMac loaded (pid %d, test driver %s, aspect lock %s)", getpid(), gTest ? "on" : "off",
		gLockDisabled ? "off" : "on");
	InstallCursorKeeperSwizzle();
	dispatch_async(dispatch_get_main_queue(), ^{
		Bootstrap();
	});
	if (gTest)
		StartTestDriver(script);
}
