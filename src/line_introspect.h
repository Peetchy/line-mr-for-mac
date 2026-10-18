// Introspection helpers for LINE's custom Lc* widgets (arm64 slice of LINE 26.5.0.3975).
//
// Everything that touches reverse-engineered offsets is gated by offsetsAvailable(), which
// verifies the LINE build number and the instruction words at the helper addresses before
// any foreign code is called. All raw memory reads go through vm_read_overwrite(), so a
// bad pointer yields an empty string instead of a crash.

#pragma once

#include <QtCore/QList>
#include <QtCore/QPoint>
#include <QtCore/QSize>
#include <QtCore/QString>
#include <QtCore/QStringList>

#include <stddef.h>
#include <stdint.h>

#include <initializer_list>

QT_BEGIN_NAMESPACE
class QMetaObject;
class QObject;
class QWidget;
QT_END_NAMESPACE

namespace line_a11y {

// --- ASLR / offsets -------------------------------------------------------------------------

// ASLR slide of the executable the LcText offsets are known for (LINE, or LineCall in the call
// helper). Returns false if neither is loaded.
bool lineImageSlide(intptr_t *slide);

// True when the running LINE binary matches the reverse-engineered layout.
bool offsetsAvailable();

// Human-readable reason recorded by offsetsAvailable() (for diagnostics).
QString offsetsStatus();

// Copies `size` bytes from `address` without faulting. Returns false on unmapped memory.
bool safeRead(const void *address, void *out, size_t size);

// Reads a Qt 6 QString {QArrayData *d; char16_t *ptr; qsizetype size} located at `address`
// by value, without touching its reference count.
QString safeReadQString(const void *address);

// --- Class helpers --------------------------------------------------------------------------

bool inheritsClass(const QMetaObject *mo, const char *className);
bool inheritsClass(const QObject *object, const char *className);
bool inheritsAnyClass(const QObject *object, std::initializer_list<const char *> classNames);
// Nearest ancestor (excluding `w`) whose class or superclass is `className`.
QWidget *ancestorInheriting(const QWidget *w, const char *className);

// --- Text extraction ------------------------------------------------------------------------

// Collapses whitespace, converts rich text to plain text and drops object-replacement chars.
QString cleanText(const QString &text);

// Text of an LcText (via the LcTextPainter chain at this+0x3f0).
QString extractLcTextString(QWidget *w);

// Raw pointer value of the row data object (LcModelDataObject *) an LcListDelegateWidget was last
// filled with, read from this + 0x400; 0 when unavailable. Only compare it against known objects.
quintptr lcListDelegateDataPointer(const QWidget *delegate);
bool lcListDelegateDataPointerAvailable();

// Fields of a ChatMessageData row object (chat message list), read from fixed offsets; empty
// when unavailable or implausible.
struct ChatMessageFields {
    QString id;           // +0x1d8 server message id ("l..." for local rows such as date separators)
    QString mediaPath;    // +0x1f0 cached photo / video thumbnail
    QString senderMid;    // +0x280 LINE user id of the sender
    QString senderImage;  // +0x298 sender's profile image (set on received messages only)
    QString text;         // +0x2e0 message text (may contain HTML for links)
    QString fileName;     // +0x310
    QString fileSize;     // +0x388 "Size: 768KB"
    QString fileStatus;   // +0x3a0 "Valid till: Oct 24 7:22 PM" / "Expired"
    QString timeLabel;    // +0x3e8 time as shown ("7:22 PM"); the date on date separators
    QString senderName;   // +0x418 sender name as shown
    QString receipt;      // +0x528 "Read" / "Read 3" on sent messages
};
ChatMessageFields readChatMessageData(const QObject *data);

// Icon resource an LcImage shows ("image://chat/chatroom-call.png"), read from this + 0x420; empty
// for images loaded from files (photos, ads) or when unavailable.
QString lcImageSource(const QWidget *image);

// Diagnostics: both LcTextPainter strings (full text at +0x68, display text at +0x50).
QStringList lcTextPainterStrings(QWidget *w);

// w->toolTip(), falling back to the LcWidget-private tooltip QString at this+0xc0.
QString extractLcWidgetToolTip(QWidget *w);

// Converts icon resource names (":/res/img/gnb_friend_add_selected@2x.png", "eye-show",
// "refresh", ...) to human-readable accessibility names. Returns "" if nothing useful remains.
QString humanizeIconName(const QString &iconName);

// Converts identifiers like "accessUrlTextField" / "btn_close" to "Access url" / "Close".
QString humanizeIdentifier(const QString &identifier);

// Best-effort visible text of a single widget (QLabel, QAbstractButton, "text" property,
// LcText, accessibleName). Password fields never contribute.
QString widgetText(QWidget *w);

struct PositionedText {
    QPoint pos;     // top-left in the coordinate system of the collection root
    QSize size;
    QString text;
};

// Visible descendant texts of `root` in reading order: grouped into visual lines (items whose
// vertical centre falls within the line's extent), lines top-to-bottom, each line left-to-right.
QList<PositionedText> collectPositionedChildTexts(QWidget *root);

// Same, joined into one string (consecutive duplicates removed).
QString collectVisibleChildTexts(QWidget *root, const QString &separator = QStringLiteral(", "));

// "33", "999+", "(27)": unread / member count badges rather than labels.
bool isBadgeText(const QString &text);

// Text of the closest visible sibling label on the same row (to the right first, then left),
// or directly above. Used for checkboxes / inputs whose caption is a separate LcText.
QString nearbyLabelText(QWidget *w);

} // namespace line_a11y
