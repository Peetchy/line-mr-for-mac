#include "focus_highlight.h"

#include "a11y_log.h"

#include <QtCore/QCoreApplication>
#include <QtCore/QDateTime>
#include <QtCore/QFileInfo>
#include <QtCore/QPointer>
#include <QtCore/QSettings>
#include <QtCore/QTimer>
#include <QtGui/QAccessible>
#include <QtGui/QColor>
#include <QtGui/QGuiApplication>
#include <QtGui/QScreen>
#include <QtGui/QWindow>

#import <AppKit/AppKit.h>

// Black outline, coloured band, black outline: visible on light and dark backgrounds alike.
@interface LineMRFocusFrameView : NSView
@property(nonatomic, strong) NSColor *bandColor;
@property(nonatomic) CGFloat band;
@end

@implementation LineMRFocusFrameView
- (BOOL)isOpaque
{
    return NO;
}

- (NSView *)hitTest:(NSPoint)point
{
    (void)point;
    return nil;
}

- (void)drawRect:(NSRect)dirtyRect
{
    (void)dirtyRect;
    const NSRect r = self.bounds;
    [[NSColor clearColor] setFill];
    NSRectFill(r);
    const CGFloat band = self.band;
    NSBezierPath *outer = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)];
    outer.lineWidth = 1;
    [[NSColor blackColor] setStroke];
    [outer stroke];
    NSBezierPath *colour = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1 + band / 2, 1 + band / 2)];
    colour.lineWidth = band;
    [(self.bandColor ?: [NSColor yellowColor]) setStroke];
    [colour stroke];
    NSBezierPath *inner = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 1.5 + band, 1.5 + band)];
    inner.lineWidth = 1;
    [[NSColor blackColor] setStroke];
    [inner stroke];
}
@end

namespace line_a11y {
namespace {

struct Settings {
    bool enabled = true;
    QColor color = QColor(255, 214, 0);
    int width = 4; // of the coloured band, in points
};

Settings g_settings;

QWindow *windowOf(QAccessibleInterface *iface)
{
    for (int depth = 0; iface && depth < 64; ++depth, iface = iface->parent()) {
        if (QWindow *w = iface->window())
            return w;
    }
    return nullptr;
}

class FocusHighlight : public QObject
{
public:
    explicit FocusHighlight(QObject *parent)
        : QObject(parent)
    {
        loadSettings();
        connect(&m_timer, &QTimer::timeout, this, [this] {
            if (++m_ticks % 10 == 0)
                loadSettings();
            update();
        });
        m_timer.start(100);
        connect(qGuiApp, &QGuiApplication::applicationStateChanged, this, [this] { update(); });
    }

    ~FocusHighlight() override
    {
        if (m_frame) {
            [m_frame.parentWindow removeChildWindow:m_frame];
            [m_frame orderOut:nil];
            m_frame = nil;
        }
    }

    void setTarget(QAccessibleInterface *iface)
    {
        m_target = iface ? QAccessible::uniqueId(iface) : 0;
        update();
        // Lists scroll the focused row into view, windows finish their layout.
        QTimer::singleShot(50, this, [this] { update(); });
    }

private:
    void loadSettings()
    {
        const QString path = bridgeDirectory() + QStringLiteral("focus-highlight.ini");
        const QDateTime modified = QFileInfo(path).lastModified();
        if (m_settingsLoaded && modified == m_settingsModified)
            return;
        m_settingsLoaded = true;
        m_settingsModified = modified;
        Settings s;
        if (modified.isValid()) {
            QSettings ini(path, QSettings::IniFormat);
            s.enabled = ini.value(QStringLiteral("highlight/enabled"), true).toBool();
            // RGB in hex, without '#' (QSettings could take it for a comment).
            const QColor c(QLatin1Char('#') + ini.value(QStringLiteral("highlight/color")).toString());
            if (c.isValid())
                s.color = c;
            s.width = qBound(1, ini.value(QStringLiteral("highlight/width"), s.width).toInt(), 12);
        }
        g_settings = s;
        a11yLog("[highlight] %s, colour %s, width %d", s.enabled ? "on" : "off", qPrintable(s.color.name()), s.width);
        if (m_view) {
            m_view.bandColor = bandColor();
            m_view.band = s.width;
            m_view.needsDisplay = YES;
        }
    }

    NSColor *bandColor() const
    {
        const QColor &c = g_settings.color;
        return [NSColor colorWithSRGBRed:c.redF() green:c.greenF() blue:c.blueF() alpha:1];
    }

    NSWindow *frameWindow()
    {
        if (!m_frame) {
            m_frame = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 10, 10)
                                                  styleMask:NSWindowStyleMaskBorderless
                                                    backing:NSBackingStoreBuffered
                                                      defer:YES];
            m_frame.releasedWhenClosed = NO;
            m_frame.opaque = NO;
            m_frame.backgroundColor = [NSColor clearColor];
            m_frame.hasShadow = NO;
            m_frame.ignoresMouseEvents = YES;
            m_frame.collectionBehavior = NSWindowCollectionBehaviorTransient | NSWindowCollectionBehaviorIgnoresCycle;
            // Not an element for VoiceOver: it only marks what VoiceOver already reads.
            m_frame.accessibilityElement = NO;
            m_view = [[LineMRFocusFrameView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
            m_view.bandColor = bandColor();
            m_view.band = g_settings.width;
            m_view.accessibilityElement = NO;
            m_frame.contentView = m_view;
        }
        return m_frame;
    }

    void hide()
    {
        if (m_frame && m_frame.visible) {
            [m_frame.parentWindow removeChildWindow:m_frame];
            [m_frame orderOut:nil];
        }
    }

    void update()
    {
        if (!g_settings.enabled || QGuiApplication::applicationState() != Qt::ApplicationActive)
            return hide();
        QAccessibleInterface *iface = m_target ? QAccessible::accessibleInterface(m_target) : nullptr;
        if (!iface || !iface->isValid() || iface->state().invisible || iface->state().offscreen)
            return hide();
        const QRect r = iface->rect();
        QWindow *w = windowOf(iface);
        if (r.isEmpty() || !w || !w->isVisible() || !w->handle())
            return hide();
        NSView *ownerView = (__bridge NSView *)reinterpret_cast<void *>(w->winId());
        NSWindow *owner = ownerView.window;
        if (!owner || !owner.visible)
            return hide();
        // Qt's global coordinates run down from the top of the primary screen, Cocoa's up from its
        // bottom. Rows scrolled partly out of view: only the part inside the window.
        const CGFloat primaryHeight = NSMaxY(NSScreen.screens.firstObject.frame);
        const CGFloat band = g_settings.width;
        NSRect frame = NSMakeRect(r.x(), primaryHeight - r.y() - r.height(), r.width(), r.height());
        frame = NSInsetRect(frame, -(band + 2), -(band + 2));
        frame = NSIntersectionRect(frame, owner.frame);
        if (NSIsEmptyRect(frame))
            return hide();
        NSWindow *window = frameWindow();
        if (window.parentWindow != owner) {
            [window.parentWindow removeChildWindow:window];
            [owner addChildWindow:window ordered:NSWindowAbove];
        }
        if (!NSEqualRects(window.frame, frame))
            [window setFrame:frame display:YES];
        if (m_view.band != band) {
            m_view.band = band;
            m_view.needsDisplay = YES;
        }
        if (!window.visible)
            [window orderFront:nil];
    }

    QTimer m_timer;
    quint64 m_ticks = 0;
    bool m_settingsLoaded = false;
    QDateTime m_settingsModified;
    QAccessible::Id m_target = 0;
    NSWindow *m_frame = nil;
    LineMRFocusFrameView *m_view = nil;
};

QPointer<FocusHighlight> g_highlight;

} // namespace

void startFocusHighlight(QCoreApplication *app)
{
    if (!g_highlight && qGuiApp)
        g_highlight = new FocusHighlight(app);
}

void noteAccessibleEvent(QAccessibleEvent *event)
{
    if (!g_highlight || event->type() != QAccessible::Focus)
        return;
    QAccessibleInterface *iface = event->accessibleInterface();
    // A list's focused row, not the list.
    if (iface && (iface->tableInterface() || iface->role() == QAccessible::List || iface->role() == QAccessible::Tree)) {
        if (QAccessibleInterface *child = iface->focusChild())
            iface = child;
    }
    g_highlight->setTarget(iface);
}

} // namespace line_a11y
