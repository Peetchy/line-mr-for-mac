#include "line_introspect.h"

#include "a11y_log.h"

#include <QtCore/QHash>
#include <QtCore/QMetaObject>
#include <QtCore/QMetaProperty>
#include <QtCore/QRegularExpression>
#include <QtCore/QVariant>
#include <QtGui/QTextDocumentFragment>
#include <QtWidgets/QAbstractButton>
#include <QtWidgets/QLabel>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QPlainTextEdit>
#include <QtWidgets/QTextEdit>
#include <QtWidgets/QWidget>

#import <Foundation/Foundation.h>

#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>

#include <algorithm>
#include <mutex>

namespace line_a11y {
namespace {

// ---- Reverse-engineered layout of LINE 26.5.0.3975 (arm64) ----------------------------------

constexpr const char *kExpectedShortVersion = "26.5.0";
constexpr const char *kExpectedBuild = "3975";

// The LcText* widgets are compiled into each executable that uses them: LINE itself and the call
// helper LineCall.app (same LINE build; identical code, found by comparing the helpers'
// surroundings instruction by instruction).
struct LcTextHelpers {
    const char *imageSuffix;
    uintptr_t helper1; // void *fn1(const void *this_plus_3f0)
    uintptr_t helper2; // void *fn2(void *p1, bool flag)
};
constexpr LcTextHelpers kLcTextHelpers[] = {
    { "/Contents/MacOS/LINE", 0x1018e31b8, 0x1018e332c },
    { "/LineCall.app/Contents/MacOS/LineCall", 0x1007707c4, 0x100770938 },
};

constexpr ptrdiff_t kLcTextPainterOffset = 0x3f0;
constexpr ptrdiff_t kLcTextDataOffset = 0x698;
constexpr ptrdiff_t kLcTextFullTextOffset = 0x68;
constexpr ptrdiff_t kLcTextDisplayTextOffset = 0x50;
constexpr ptrdiff_t kLcWidgetToolTipOffset = 0xc0;
constexpr ptrdiff_t kLcListDelegateDataOffset = 0x400; // LcModelDataObject * of the row being shown
constexpr ptrdiff_t kLcImageSourceOffset = 0x420;      // LcImage: QString source
// ChatMessageData QString members (see ChatMessageFields).
constexpr ptrdiff_t kChatMessageIdOffset = 0x1d8;
constexpr ptrdiff_t kChatMessageMediaOffset = 0x1f0;
constexpr ptrdiff_t kChatMessageSenderOffset = 0x280;
constexpr ptrdiff_t kChatMessageSenderImageOffset = 0x298;
constexpr ptrdiff_t kChatMessageTextOffset = 0x2e0;
constexpr ptrdiff_t kChatMessageFileNameOffset = 0x310;
constexpr ptrdiff_t kChatMessageFileSizeOffset = 0x388;
constexpr ptrdiff_t kChatMessageFileStatusOffset = 0x3a0;
constexpr ptrdiff_t kChatMessageTimeOffset = 0x3e8;
constexpr ptrdiff_t kChatMessageSenderNameOffset = 0x418;
constexpr ptrdiff_t kChatMessageReceiptOffset = 0x528;

// First five instruction words of each helper, taken from the shipped binary:
//   sub sp,sp,#0x20; stp x29,x30,[sp,#0x10]; add x29,sp,#0x10; str x0,[sp,#0x8]; ...
constexpr uint32_t kHelper1Signature[] = { 0xd10083ff, 0xa9017bfd, 0x910043fd, 0xf90007e0, 0xf94007e0 };
constexpr uint32_t kHelper2Signature[] = { 0xd10083ff, 0xa9017bfd, 0x910043fd, 0xf90007e0, 0x39001fe1 };

using LcTextHelper1 = void *(*)(const void *);
using LcTextHelper2 = void *(*)(void *, bool);

constexpr qsizetype kMaxQStringLength = 64 * 1024;

struct OffsetState {
    std::once_flag once;
    bool available = false;
    intptr_t slide = 0;
    uintptr_t helper1 = 0; // absolute addresses (slide applied)
    uintptr_t helper2 = 0;
    QString status;
};

OffsetState &offsetState()
{
    static OffsetState *s = new OffsetState;
    return *s;
}

bool hasSuffix(const char *s, const char *suffix)
{
    const size_t ls = strlen(s), lf = strlen(suffix);
    return ls >= lf && strcmp(s + ls - lf, suffix) == 0;
}

QString bundleString(NSString *key)
{
    @autoreleasepool {
        id value = [[NSBundle mainBundle] objectForInfoDictionaryKey:key];
        return [value isKindOfClass:[NSString class]] ? QString::fromNSString(value) : QString();
    }
}

bool signatureMatches(uintptr_t address, const uint32_t *expected, size_t count)
{
    uint32_t actual[8] = {};
    if (count > 8 || !safeRead(reinterpret_cast<const void *>(address), actual, count * sizeof(uint32_t)))
        return false;
    return memcmp(actual, expected, count * sizeof(uint32_t)) == 0;
}

bool findLcTextImage(intptr_t *slide, const LcTextHelpers **helpers)
{
    const uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name)
            continue;
        for (const LcTextHelpers &h : kLcTextHelpers) {
            if (hasSuffix(name, h.imageSuffix)) {
                if (slide)
                    *slide = _dyld_get_image_vmaddr_slide(i);
                if (helpers)
                    *helpers = &h;
                return true;
            }
        }
    }
    return false;
}

void computeOffsetState(OffsetState &s)
{
#if !defined(__arm64__)
    s.status = QStringLiteral("disabled: offsets are only valid for the arm64 slice");
    return;
#else
    const LcTextHelpers *helpers = nullptr;
    if (!findLcTextImage(&s.slide, &helpers)) {
        s.status = QStringLiteral("disabled: neither LINE nor LineCall executable image found");
        return;
    }
    const QString shortVersion = bundleString(@"CFBundleShortVersionString");
    const QString build = bundleString(@"CFBundleVersion");
    const bool forced = qEnvironmentVariableIntValue("LINE_A11Y_FORCE_OFFSETS") == 1;
    if (!forced && (shortVersion != QLatin1StringView(kExpectedShortVersion) || build != QLatin1StringView(kExpectedBuild))) {
        s.status = QStringLiteral("disabled: LINE %1 (%2) differs from verified %3 (%4)")
                       .arg(shortVersion, build, QLatin1StringView(kExpectedShortVersion),
                            QLatin1StringView(kExpectedBuild));
        return;
    }
    const uintptr_t h1 = helpers->helper1 + s.slide;
    const uintptr_t h2 = helpers->helper2 + s.slide;
    if (!signatureMatches(h1, kHelper1Signature, std::size(kHelper1Signature))
        || !signatureMatches(h2, kHelper2Signature, std::size(kHelper2Signature))) {
        s.status = QStringLiteral("disabled: instruction signature mismatch at LcTextPainter helpers");
        return;
    }
    s.available = true;
    s.helper1 = h1;
    s.helper2 = h2;
    s.status = QStringLiteral("enabled: LINE %1 (%2), slide 0x%3%4")
                   .arg(shortVersion, build, QString::number(qulonglong(s.slide), 16),
                        forced ? QStringLiteral(" [forced]") : QString());
#endif
}

void ensureOffsetState()
{
    OffsetState &s = offsetState();
    std::call_once(s.once, [&s] {
        computeOffsetState(s);
        a11yLog("[introspect] offsets %s", qPrintable(s.status));
    });
}

bool isPlausibleText(const QString &text)
{
    if (text.isEmpty() || text.size() > 4096)
        return false;
    int printable = 0;
    for (const QChar c : text) {
        const ushort u = c.unicode();
        if (u < 0x20 && u != '\n' && u != '\t' && u != '\r')
            return false;
        if (c.isNonCharacter() || (c.isSurrogate() && !text.isValidUtf16()))
            return false;
        if (c.isLetterOrNumber() || c.isPunct() || c.isSymbol() || c.isHighSurrogate())
            ++printable;
    }
    return printable > 0;
}

QString stringProperty(const QObject *o, const char *name)
{
    const QMetaObject *mo = o->metaObject();
    const int index = mo->indexOfProperty(name);
    if (index < 0)
        return QString();
    const QVariant v = mo->property(index).read(o);
    return v.metaType().id() == QMetaType::QString ? v.toString() : QString();
}

bool isPasswordWidget(const QWidget *w)
{
    if (inheritsClass(w, "PasswordTextField"))
        return true;
    if (auto *le = qobject_cast<const QLineEdit *>(w))
        return le->echoMode() != QLineEdit::Normal;
    return false;
}

// ---- Icon names --------------------------------------------------------------------------------

const QHash<QString, QString> &iconLabels()
{
    static const QHash<QString, QString> map = {
        // Password visibility / login
        { QStringLiteral("eye-show"), QStringLiteral("Show password") },
        { QStringLiteral("show-eye"), QStringLiteral("Show password") },
        { QStringLiteral("eye-open"), QStringLiteral("Show password") },
        { QStringLiteral("show-password"), QStringLiteral("Show password") },
        { QStringLiteral("eye"), QStringLiteral("Show password") },
        { QStringLiteral("eye-hide"), QStringLiteral("Hide password") },
        { QStringLiteral("hide-eye"), QStringLiteral("Hide password") },
        { QStringLiteral("eye-close"), QStringLiteral("Hide password") },
        { QStringLiteral("eye-closed"), QStringLiteral("Hide password") },
        { QStringLiteral("eye-slash"), QStringLiteral("Hide password") },
        { QStringLiteral("hide-password"), QStringLiteral("Hide password") },
        { QStringLiteral("refresh"), QStringLiteral("Refresh QR code") },
        { QStringLiteral("reload"), QStringLiteral("Refresh QR code") },
        { QStringLiteral("qr-refresh"), QStringLiteral("Refresh QR code") },
        { QStringLiteral("refresh-qr"), QStringLiteral("Refresh QR code") },
        { QStringLiteral("qr"), QStringLiteral("QR code") },
        { QStringLiteral("qrcode"), QStringLiteral("QR code") },
        // Navigation sidebar
        { QStringLiteral("friend"), QStringLiteral("Friends") },
        { QStringLiteral("friends"), QStringLiteral("Friends") },
        { QStringLiteral("friend-list"), QStringLiteral("Friends") },
        { QStringLiteral("home"), QStringLiteral("Home") },
        { QStringLiteral("chat"), QStringLiteral("Chats") },
        { QStringLiteral("chats"), QStringLiteral("Chats") },
        { QStringLiteral("chat-list"), QStringLiteral("Chats") },
        { QStringLiteral("talk"), QStringLiteral("Chats") },
        { QStringLiteral("add-friend"), QStringLiteral("Add friends") },
        { QStringLiteral("add-friends"), QStringLiteral("Add friends") },
        { QStringLiteral("friend-add"), QStringLiteral("Add friends") },
        { QStringLiteral("addfriend"), QStringLiteral("Add friends") },
        { QStringLiteral("keep"), QStringLiteral("Keep") },
        { QStringLiteral("timeline"), QStringLiteral("Timeline") },
        { QStringLiteral("voom"), QStringLiteral("LINE VOOM") },
        { QStringLiteral("story"), QStringLiteral("Story") },
        { QStringLiteral("news"), QStringLiteral("News") },
        { QStringLiteral("today"), QStringLiteral("LINE Today") },
        { QStringLiteral("wallet"), QStringLiteral("Wallet") },
        { QStringLiteral("openchat"), QStringLiteral("OpenChat") },
        { QStringLiteral("open-chat"), QStringLiteral("OpenChat") },
        { QStringLiteral("setting"), QStringLiteral("Settings") },
        { QStringLiteral("settings"), QStringLiteral("Settings") },
        { QStringLiteral("config"), QStringLiteral("Settings") },
        { QStringLiteral("preference"), QStringLiteral("Settings") },
        { QStringLiteral("preferences"), QStringLiteral("Settings") },
        { QStringLiteral("call"), QStringLiteral("Calls") },
        { QStringLiteral("calls"), QStringLiteral("Calls") },
        { QStringLiteral("voip"), QStringLiteral("Calls") },
        { QStringLiteral("phone"), QStringLiteral("Calls") },
        { QStringLiteral("video-call"), QStringLiteral("Video call") },
        { QStringLiteral("voice-call"), QStringLiteral("Voice call") },
        { QStringLiteral("notification"), QStringLiteral("Notifications") },
        { QStringLiteral("notifications"), QStringLiteral("Notifications") },
        { QStringLiteral("noti"), QStringLiteral("Notifications") },
        { QStringLiteral("alarm"), QStringLiteral("Notifications") },
        { QStringLiteral("bell"), QStringLiteral("Notifications") },
        // Window / generic controls
        { QStringLiteral("close"), QStringLiteral("Close") },
        { QStringLiteral("x"), QStringLiteral("Close") },
        { QStringLiteral("minimize"), QStringLiteral("Minimize") },
        { QStringLiteral("min"), QStringLiteral("Minimize") },
        { QStringLiteral("maximize"), QStringLiteral("Maximize") },
        { QStringLiteral("max"), QStringLiteral("Maximize") },
        { QStringLiteral("search"), QStringLiteral("Search") },
        { QStringLiteral("search-delete"), QStringLiteral("Clear search") },
        { QStringLiteral("clear"), QStringLiteral("Clear") },
        { QStringLiteral("more"), QStringLiteral("More options") },
        { QStringLiteral("more-icon"), QStringLiteral("More options") },
        // Chat room header
        { QStringLiteral("chatroom-call"), QStringLiteral("Call") },
        // Call window (LineCall.app, image://voip/...)
        { QStringLiteral("call-end-bt"), QStringLiteral("End call") },
        { QStringLiteral("call-answer"), QStringLiteral("Answer") },
        { QStringLiteral("call-decline"), QStringLiteral("Decline") },
        { QStringLiteral("mic-bt"), QStringLiteral("Microphone") },
        { QStringLiteral("speaker-bt"), QStringLiteral("Speaker") },
        { QStringLiteral("video-bt"), QStringLiteral("Video") },
        { QStringLiteral("camera-bt"), QStringLiteral("Camera") },
        { QStringLiteral("userpopup-close"), QStringLiteral("Close") },
        { QStringLiteral("chatroom-search"), QStringLiteral("Search") },
        { QStringLiteral("chatroom-note"), QStringLiteral("Notes") },
        { QStringLiteral("chatroom-more"), QStringLiteral("More options") },
        // Chat list header: "<" / ">" next to the sort button
        { QStringLiteral("open-bt"), QStringLiteral("Show or hide chat list") },
        // Video ads
        { QStringLiteral("banner-pause-bt"), QStringLiteral("Pause") },
        { QStringLiteral("banner-play-bt"), QStringLiteral("Play") },
        { QStringLiteral("banner-sound-bt"), QStringLiteral("Sound") },
        { QStringLiteral("banner-mute-bt"), QStringLiteral("Mute") },
        { QStringLiteral("full-screen-icon"), QStringLiteral("Full screen") },
        { QStringLiteral("menu"), QStringLiteral("Menu") },
        { QStringLiteral("kebab"), QStringLiteral("More options") },
        { QStringLiteral("back"), QStringLiteral("Back") },
        { QStringLiteral("prev"), QStringLiteral("Previous") },
        { QStringLiteral("previous"), QStringLiteral("Previous") },
        { QStringLiteral("next"), QStringLiteral("Next") },
        { QStringLiteral("forward"), QStringLiteral("Forward") },
        { QStringLiteral("arrow-left"), QStringLiteral("Back") },
        { QStringLiteral("arrow-right"), QStringLiteral("Next") },
        { QStringLiteral("arrow-down"), QStringLiteral("Expand") },
        { QStringLiteral("arrow-up"), QStringLiteral("Collapse") },
        { QStringLiteral("expand"), QStringLiteral("Expand") },
        { QStringLiteral("collapse"), QStringLiteral("Collapse") },
        { QStringLiteral("add"), QStringLiteral("Add") },
        { QStringLiteral("plus"), QStringLiteral("Add") },
        { QStringLiteral("delete"), QStringLiteral("Delete") },
        { QStringLiteral("trash"), QStringLiteral("Delete") },
        { QStringLiteral("remove"), QStringLiteral("Remove") },
        { QStringLiteral("edit"), QStringLiteral("Edit") },
        { QStringLiteral("pencil"), QStringLiteral("Edit") },
        { QStringLiteral("copy"), QStringLiteral("Copy") },
        { QStringLiteral("share"), QStringLiteral("Share") },
        { QStringLiteral("download"), QStringLiteral("Download") },
        { QStringLiteral("upload"), QStringLiteral("Upload") },
        { QStringLiteral("save"), QStringLiteral("Save") },
        { QStringLiteral("pin"), QStringLiteral("Pin") },
        { QStringLiteral("unpin"), QStringLiteral("Unpin") },
        { QStringLiteral("mute"), QStringLiteral("Mute notifications") },
        { QStringLiteral("unmute"), QStringLiteral("Unmute notifications") },
        { QStringLiteral("check"), QStringLiteral("Selected") },
        { QStringLiteral("info"), QStringLiteral("Information") },
        { QStringLiteral("help"), QStringLiteral("Help") },
        { QStringLiteral("profile"), QStringLiteral("Profile") },
        { QStringLiteral("invite"), QStringLiteral("Invite") },
        { QStringLiteral("album"), QStringLiteral("Albums") },
        { QStringLiteral("note"), QStringLiteral("Notes") },
        { QStringLiteral("announcement"), QStringLiteral("Announcements") },
        { QStringLiteral("translate"), QStringLiteral("Translate") },
        // Chat input
        { QStringLiteral("emoji"), QStringLiteral("Stickers and emoji") },
        { QStringLiteral("emoticon"), QStringLiteral("Stickers and emoji") },
        { QStringLiteral("sticker"), QStringLiteral("Stickers and emoji") },
        { QStringLiteral("sticon"), QStringLiteral("Stickers and emoji") },
        { QStringLiteral("attach"), QStringLiteral("Attach file") },
        { QStringLiteral("attachment"), QStringLiteral("Attach file") },
        { QStringLiteral("file"), QStringLiteral("Attach file") },
        { QStringLiteral("clip"), QStringLiteral("Attach file") },
        { QStringLiteral("image"), QStringLiteral("Send image") },
        { QStringLiteral("photo"), QStringLiteral("Send image") },
        { QStringLiteral("gallery"), QStringLiteral("Send image") },
        { QStringLiteral("screenshot"), QStringLiteral("Take screenshot") },
        { QStringLiteral("capture"), QStringLiteral("Take screenshot") },
        { QStringLiteral("camera"), QStringLiteral("Camera") },
        { QStringLiteral("video"), QStringLiteral("Video") },
        { QStringLiteral("mic"), QStringLiteral("Voice message") },
        { QStringLiteral("voice"), QStringLiteral("Voice message") },
        { QStringLiteral("send"), QStringLiteral("Send") },
        { QStringLiteral("keyboard"), QStringLiteral("Keyboard") },
        { QStringLiteral("gift"), QStringLiteral("Send a gift") },
        { QStringLiteral("location"), QStringLiteral("Share location") },
        { QStringLiteral("contact"), QStringLiteral("Share contact") },
    };
    return map;
}

// Tokens that describe state, size or decoration rather than meaning.
bool isNoiseToken(const QString &t)
{
    static const QStringList noise = {
        QStringLiteral("res"), QStringLiteral("img"), QStringLiteral("imgs"), QStringLiteral("images"),
        QStringLiteral("icon"), QStringLiteral("icons"), QStringLiteral("ico"), QStringLiteral("ic"),
        QStringLiteral("btn"), QStringLiteral("button"), QStringLiteral("normal"), QStringLiteral("nor"),
        QStringLiteral("hover"), QStringLiteral("over"), QStringLiteral("press"), QStringLiteral("pressed"),
        QStringLiteral("on"), QStringLiteral("off"), QStringLiteral("dis"), QStringLiteral("disable"),
        QStringLiteral("disabled"), QStringLiteral("dimmed"), QStringLiteral("dim"), QStringLiteral("sel"),
        QStringLiteral("select"), QStringLiteral("selected"), QStringLiteral("active"),
        QStringLiteral("inactive"), QStringLiteral("focus"), QStringLiteral("focused"),
        QStringLiteral("dark"), QStringLiteral("light"), QStringLiteral("black"), QStringLiteral("white"),
        QStringLiteral("gray"), QStringLiteral("grey"), QStringLiteral("default"), QStringLiteral("new"),
        QStringLiteral("small"), QStringLiteral("large"), QStringLiteral("big"), QStringLiteral("mini"),
        QStringLiteral("png"), QStringLiteral("svg"), QStringLiteral("gnb"), QStringLiteral("lnb"),
        QStringLiteral("nav"), QStringLiteral("navi"), QStringLiteral("sidebar"), QStringLiteral("side"),
        QStringLiteral("tab"), QStringLiteral("main"), QStringLiteral("common"), QStringLiteral("titlebar"),
        QStringLiteral("toolbar"), QStringLiteral("n"), QStringLiteral("h"), QStringLiteral("p"),
        QStringLiteral("s"), QStringLiteral("d"), QStringLiteral("2x"), QStringLiteral("3x"),
        QStringLiteral("lc"),
    };
    if (noise.contains(t))
        return true;
    static const QRegularExpression numeric(QStringLiteral("^\\d+(x\\d+)?$"));
    return numeric.match(t).hasMatch();
}

QStringList splitIdentifier(const QString &s)
{
    // "accessUrlTextField" -> "access Url Text Field"; separators -> space.
    QString spaced;
    spaced.reserve(s.size() * 2);
    for (qsizetype i = 0; i < s.size(); ++i) {
        const QChar c = s.at(i);
        if (c == u'_' || c == u'-' || c == u'.' || c == u'/' || c == u':' || c == u'@' || c.isSpace()) {
            spaced += u' ';
            continue;
        }
        if (i > 0 && c.isUpper() && (s.at(i - 1).isLower() || s.at(i - 1).isDigit()))
            spaced += u' ';
        spaced += c;
    }
    return spaced.toLower().split(u' ', Qt::SkipEmptyParts);
}

} // namespace

// ---- ASLR / raw memory -------------------------------------------------------------------------

bool lineImageSlide(intptr_t *slide)
{
    return findLcTextImage(slide, nullptr);
}

bool offsetsAvailable()
{
    ensureOffsetState();
    return offsetState().available;
}

QString offsetsStatus()
{
    ensureOffsetState();
    return offsetState().status;
}

bool safeRead(const void *address, void *out, size_t size)
{
    if (!address || !out || size == 0)
        return false;
    vm_size_t copied = 0;
    const kern_return_t kr = vm_read_overwrite(mach_task_self(), reinterpret_cast<vm_address_t>(address), size,
                                               reinterpret_cast<vm_address_t>(out), &copied);
    return kr == KERN_SUCCESS && copied == size;
}

QString safeReadQString(const void *address)
{
    struct RawQString {
        const void *d;
        const char16_t *ptr;
        qsizetype size;
    } raw{};
    static_assert(sizeof(RawQString) == sizeof(QString), "Unexpected QString layout");

    if (!safeRead(address, &raw, sizeof(raw)))
        return QString();
    if (raw.size <= 0 || raw.size > kMaxQStringLength || !raw.ptr)
        return QString();
    QString result(raw.size, Qt::Uninitialized);
    if (!safeRead(raw.ptr, result.data(), size_t(raw.size) * sizeof(char16_t)))
        return QString();
    return result;
}

// ---- Class helpers -----------------------------------------------------------------------------

bool inheritsClass(const QMetaObject *mo, const char *className)
{
    for (; mo; mo = mo->superClass()) {
        if (strcmp(mo->className(), className) == 0)
            return true;
    }
    return false;
}

bool inheritsClass(const QObject *object, const char *className)
{
    return object && inheritsClass(object->metaObject(), className);
}

bool inheritsAnyClass(const QObject *object, std::initializer_list<const char *> classNames)
{
    if (!object)
        return false;
    for (const QMetaObject *mo = object->metaObject(); mo; mo = mo->superClass()) {
        for (const char *name : classNames) {
            if (strcmp(mo->className(), name) == 0)
                return true;
        }
    }
    return false;
}

QWidget *ancestorInheriting(const QWidget *w, const char *className)
{
    for (QWidget *p = w ? w->parentWidget() : nullptr; p; p = p->parentWidget()) {
        if (inheritsClass(p, className))
            return p;
    }
    return nullptr;
}

// ---- Text extraction ---------------------------------------------------------------------------

QString cleanText(const QString &text)
{
    if (text.isEmpty())
        return text;
    QString plain = Qt::mightBeRichText(text) ? QTextDocumentFragment::fromHtml(text).toPlainText() : text;
    plain.replace(QChar::ObjectReplacementCharacter, u' ');
    plain.replace(QChar::LineSeparator, u' ');
    plain.replace(QChar::ParagraphSeparator, u' ');
    plain.replace(QChar(0x200b), QString()); // zero-width space
    return plain.simplified();
}

QString extractLcTextString(QWidget *w)
{
    if (!w || !inheritsClass(w, "LcText"))
        return QString();

    // Some LcText subclasses do declare a property; prefer it when present.
    const QString property = cleanText(stringProperty(w, "text"));
    if (!property.isEmpty())
        return property;

    if (!offsetsAvailable())
        return QString();

    const auto fn1 = reinterpret_cast<LcTextHelper1>(offsetState().helper1);
    const auto fn2 = reinterpret_cast<LcTextHelper2>(offsetState().helper2);

    const char *painterSlot = reinterpret_cast<const char *>(w) + kLcTextPainterOffset;
    void *slotValue = nullptr;
    if (!safeRead(painterSlot, &slotValue, sizeof(slotValue)) || !slotValue)
        return QString();

    void *p1 = fn1(painterSlot);
    void *p1Inner = nullptr;
    if (!p1 || !safeRead(p1, &p1Inner, sizeof(p1Inner)) || !p1Inner)
        return QString();

    void *p2 = fn2(p1, false);
    if (!p2)
        return QString();

    void *p3 = nullptr;
    if (!safeRead(reinterpret_cast<const char *>(p2) + kLcTextDataOffset, &p3, sizeof(p3)) || !p3)
        return QString();

    QString text = safeReadQString(reinterpret_cast<const char *>(p3) + kLcTextFullTextOffset);
    if (!isPlausibleText(text))
        text = safeReadQString(reinterpret_cast<const char *>(p3) + kLcTextDisplayTextOffset);
    return isPlausibleText(text) ? cleanText(text) : QString();
}

QStringList lcTextPainterStrings(QWidget *w)
{
    if (!w || !inheritsClass(w, "LcText") || !offsetsAvailable())
        return {};
    const auto fn1 = reinterpret_cast<LcTextHelper1>(offsetState().helper1);
    const auto fn2 = reinterpret_cast<LcTextHelper2>(offsetState().helper2);
    const char *painterSlot = reinterpret_cast<const char *>(w) + kLcTextPainterOffset;
    void *slotValue = nullptr;
    if (!safeRead(painterSlot, &slotValue, sizeof(slotValue)) || !slotValue)
        return {};
    void *p1 = fn1(painterSlot);
    void *p1Inner = nullptr;
    if (!p1 || !safeRead(p1, &p1Inner, sizeof(p1Inner)) || !p1Inner)
        return {};
    void *p2 = fn2(p1, false);
    void *p3 = nullptr;
    if (!p2 || !safeRead(reinterpret_cast<const char *>(p2) + kLcTextDataOffset, &p3, sizeof(p3)) || !p3)
        return {};
    return { safeReadQString(reinterpret_cast<const char *>(p3) + kLcTextFullTextOffset),
             safeReadQString(reinterpret_cast<const char *>(p3) + kLcTextDisplayTextOffset) };
}

ChatMessageFields readChatMessageData(const QObject *data)
{
    ChatMessageFields fields;
    if (!data || !offsetsAvailable() || !inheritsClass(data, "ChatMessageData"))
        return fields;
    const char *base = reinterpret_cast<const char *>(data);
    auto read = [base](ptrdiff_t offset) {
        const QString text = safeReadQString(base + offset);
        return isPlausibleText(text) ? text : QString();
    };
    fields.id = read(kChatMessageIdOffset);
    fields.mediaPath = read(kChatMessageMediaOffset);
    fields.senderMid = read(kChatMessageSenderOffset);
    if (fields.senderMid.size() != 33) // "u" / "c" / "r" + 32 hex digits
        fields.senderMid.clear();
    fields.senderImage = read(kChatMessageSenderImageOffset);
    fields.text = read(kChatMessageTextOffset);
    fields.fileName = read(kChatMessageFileNameOffset);
    fields.fileSize = read(kChatMessageFileSizeOffset);
    fields.fileStatus = read(kChatMessageFileStatusOffset);
    fields.timeLabel = read(kChatMessageTimeOffset);
    fields.senderName = read(kChatMessageSenderNameOffset);
    fields.receipt = read(kChatMessageReceiptOffset);
    return fields;
}

QString lcImageSource(const QWidget *image)
{
    if (!image || !offsetsAvailable() || !inheritsClass(image, "LcImage"))
        return QString();
    const QString source = safeReadQString(reinterpret_cast<const char *>(image) + kLcImageSourceOffset);
    return isPlausibleText(source) && source.startsWith(QLatin1StringView("image://")) ? source : QString();
}

bool lcListDelegateDataPointerAvailable()
{
    return offsetsAvailable();
}

quintptr lcListDelegateDataPointer(const QWidget *delegate)
{
    if (!delegate || !offsetsAvailable() || !inheritsClass(delegate, "LcListDelegateWidget"))
        return 0;
    quintptr value = 0;
    if (!safeRead(reinterpret_cast<const char *>(delegate) + kLcListDelegateDataOffset, &value, sizeof(value)))
        return 0;
    return value;
}

QString extractLcWidgetToolTip(QWidget *w)
{
    if (!w)
        return QString();
    const QString tip = cleanText(w->toolTip());
    if (!tip.isEmpty())
        return tip;
    if (!inheritsClass(w, "LcWidget") || !offsetsAvailable())
        return QString();
    const QString raw = safeReadQString(reinterpret_cast<const char *>(w) + kLcWidgetToolTipOffset);
    return isPlausibleText(raw) ? cleanText(raw) : QString();
}

QString humanizeIconName(const QString &iconName)
{
    QString name = iconName.trimmed();
    if (name.isEmpty())
        return QString();
    // Strip URL scheme / query, directories and the file extension.
    if (const qsizetype q = name.indexOf(u'?'); q >= 0)
        name.truncate(q);
    if (const qsizetype slash = name.lastIndexOf(u'/'); slash >= 0)
        name = name.mid(slash + 1);
    if (const qsizetype dot = name.lastIndexOf(u'.'); dot > 0)
        name.truncate(dot);
    name.remove(QRegularExpression(QStringLiteral("@\\d+x$")));

    const QStringList all = splitIdentifier(name);
    QStringList tokens;
    for (const QString &t : all) {
        if (!isNoiseToken(t))
            tokens << t;
    }
    if (tokens.isEmpty())
        tokens = all;
    if (tokens.isEmpty())
        return QString();

    const auto &labels = iconLabels();
    const QString dashed = tokens.join(u'-');
    if (auto it = labels.constFind(dashed); it != labels.constEnd())
        return *it;
    if (auto it = labels.constFind(tokens.join(QString())); it != labels.constEnd())
        return *it;

    // Longest contiguous token run with a known label wins ("gnb_friend_add_count" -> "Add friends").
    for (qsizetype len = tokens.size() - 1; len >= 1; --len) {
        for (qsizetype start = 0; start + len <= tokens.size(); ++start) {
            const QString key = tokens.mid(start, len).join(u'-');
            if (auto it = labels.constFind(key); it != labels.constEnd())
                return *it;
        }
    }

    QString words = tokens.join(u' ');
    words[0] = words[0].toUpper();
    return words;
}

QString humanizeIdentifier(const QString &identifier)
{
    static const QStringList widgetSuffixes = {
        QStringLiteral("text field"), QStringLiteral("textfield"), QStringLiteral("text edit"),
        QStringLiteral("text area"), QStringLiteral("line edit"), QStringLiteral("button"),
        QStringLiteral("btn"), QStringLiteral("label"), QStringLiteral("text"), QStringLiteral("panel"),
        QStringLiteral("widget"), QStringLiteral("input"), QStringLiteral("field"), QStringLiteral("edit"),
    };
    QStringList tokens = splitIdentifier(identifier);
    QString phrase = tokens.join(u' ');
    for (const QString &suffix : widgetSuffixes) {
        if (phrase.endsWith(u' ' + suffix)) {
            phrase.chop(suffix.size() + 1);
            break;
        }
    }
    tokens = phrase.split(u' ', Qt::SkipEmptyParts);
    while (!tokens.isEmpty() && (tokens.first() == u"btn" || tokens.first() == u"lc" || tokens.first() == u"m"))
        tokens.removeFirst();
    if (tokens.isEmpty())
        return QString();
    const QString key = tokens.join(u'-');
    if (auto it = iconLabels().constFind(key); it != iconLabels().constEnd())
        return *it;
    QString words = tokens.join(u' ');
    words[0] = words[0].toUpper();
    return words;
}

QString widgetText(QWidget *w)
{
    if (!w || isPasswordWidget(w))
        return QString();

    const QString explicitName = cleanText(w->accessibleName());
    if (!explicitName.isEmpty())
        return explicitName;

    if (auto *label = qobject_cast<QLabel *>(w))
        return cleanText(label->text());
    if (auto *button = qobject_cast<QAbstractButton *>(w))
        return cleanText(button->text());
    if (auto *edit = qobject_cast<QLineEdit *>(w))
        return cleanText(edit->text());
    if (auto *edit = qobject_cast<QTextEdit *>(w))
        return cleanText(edit->toPlainText());
    if (auto *edit = qobject_cast<QPlainTextEdit *>(w))
        return cleanText(edit->toPlainText());

    if (inheritsClass(w, "LcText"))
        return extractLcTextString(w);

    if (inheritsAnyClass(w, { "HighlightableTextWidget", "LcLabel" }) || w->metaObject()->indexOfProperty("text") >= 0)
        return cleanText(stringProperty(w, "text"));
    return QString();
}

namespace {

void gatherTexts(QWidget *root, QWidget *parent, QList<PositionedText> &out, int depth)
{
    if (depth > 24 || out.size() > 256)
        return;
    for (QObject *child : parent->children()) {
        if (!child->isWidgetType())
            continue;
        auto *c = static_cast<QWidget *>(child);
        if (c->isWindow() || c->isHidden() || c->width() <= 0 || c->height() <= 0)
            continue;
        const QString text = widgetText(c);
        if (!text.isEmpty()) {
            out.append({ c->mapTo(root, QPoint(0, 0)), c->size(), text });
            continue; // the widget's text already represents its subtree
        }
        gatherTexts(root, c, out, depth + 1);
    }
}

} // namespace

QList<PositionedText> collectPositionedChildTexts(QWidget *root)
{
    QList<PositionedText> items;
    if (!root)
        return items;
    gatherTexts(root, root, items, 0);
    std::stable_sort(items.begin(), items.end(), [](const PositionedText &a, const PositionedText &b) {
        return a.pos.y() != b.pos.y() ? a.pos.y() < b.pos.y() : a.pos.x() < b.pos.x();
    });
    // A timestamp at the top right usually starts a pixel or two above the name on its left;
    // group such items into one line so the name is read first.
    QList<PositionedText> ordered;
    ordered.reserve(items.size());
    for (qsizetype start = 0; start < items.size();) {
        int lineTop = items[start].pos.y();
        int lineBottom = lineTop + items[start].size.height();
        qsizetype end = start + 1;
        while (end < items.size()) {
            const int centre = items[end].pos.y() + items[end].size.height() / 2;
            if (centre < lineTop || centre > lineBottom)
                break;
            lineBottom = qMax(lineBottom, items[end].pos.y() + items[end].size.height());
            ++end;
        }
        QList<PositionedText> line = items.mid(start, end - start);
        std::stable_sort(line.begin(), line.end(),
                         [](const PositionedText &a, const PositionedText &b) { return a.pos.x() < b.pos.x(); });
        ordered += line;
        start = end;
    }
    return ordered;
}

QString collectVisibleChildTexts(QWidget *root, const QString &separator)
{
    QStringList parts;
    for (const PositionedText &item : collectPositionedChildTexts(root)) {
        if (parts.isEmpty() || parts.constLast() != item.text)
            parts << item.text;
    }
    return parts.join(separator);
}

bool isBadgeText(const QString &text)
{
    static const QRegularExpression badge(QStringLiteral("^\\(?\\d+\\+?\\)?$"));
    return badge.match(text.trimmed()).hasMatch();
}

QString nearbyLabelText(QWidget *w)
{
    QWidget *parent = w ? w->parentWidget() : nullptr;
    if (!parent)
        return QString();

    const QRect g = w->geometry();
    QString best;
    int bestScore = INT_MAX;
    for (QObject *child : parent->children()) {
        if (child == w || !child->isWidgetType())
            continue;
        auto *c = static_cast<QWidget *>(child);
        if (c->isHidden() || c->isWindow())
            continue;
        if (qobject_cast<QLineEdit *>(c) || qobject_cast<QTextEdit *>(c) || qobject_cast<QAbstractButton *>(c)
            || inheritsAnyClass(c, { "LcButton", "LcCheckBox", "LcTextField", "LcTextArea" }))
            continue;
        const QRect cg = c->geometry();
        const int dy = qAbs(cg.center().y() - g.center().y());
        int score = INT_MAX;
        if (dy <= qMax(g.height(), cg.height()) / 2) {
            if (cg.left() >= g.right())
                score = cg.left() - g.right();               // same row, to the right
            else if (cg.right() <= g.left())
                score = 1000 + g.left() - cg.right();        // same row, to the left
        } else if (cg.bottom() <= g.top() && g.top() - cg.bottom() < 48
                   && cg.left() < g.right() && cg.right() > g.left()) {
            score = 2000 + g.top() - cg.bottom();            // directly above
        }
        if (score >= bestScore)
            continue;
        QString text = widgetText(c);
        if (text.isEmpty())
            text = collectVisibleChildTexts(c, QStringLiteral(" "));
        if (!text.isEmpty() && !isBadgeText(text)) {
            best = text;
            bestScore = score;
        }
    }
    return best;
}

} // namespace line_a11y
