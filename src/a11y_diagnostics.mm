#include "a11y_diagnostics.h"

#include "a11y_log.h"
#include "accessible_widgets.h"
#include "line_introspect.h"
#include "native_buttons.h"
#include "text_capture.h"

#include <QtCore/QAbstractItemModel>
#include <QtCore/QDate>
#include <QtCore/QDateTime>
#include <QtCore/QFile>
#include <QtGui/QImage>
#include <QtCore/QMetaObject>
#include <QtCore/QMetaProperty>
#include <QtCore/QSet>
#include <QtCore/QTextStream>
#include <QtCore/QVariant>
#include <QtGui/QAccessible>
#include <QtWidgets/QAbstractItemDelegate>
#include <QtWidgets/QAbstractItemView>
#include <QtWidgets/QApplication>
#include <QtWidgets/QScrollBar>
#include <QtWidgets/QWidget>
#include <QtQuick/QQuickItem>
#include <QtQuick/QQuickWindow>

#include <sys/stat.h>
#include <unistd.h>

#include <string>

namespace line_a11y {
namespace {

constexpr int kMaxDumpRows = 6;
constexpr int kMaxAccessibleDepth = 4;

std::string requestPath()
{
    return std::string(a11yDirectory()) + "/dump-request";
}

QString classChain(const QObject *o)
{
    QStringList names;
    for (const QMetaObject *mo = o->metaObject(); mo; mo = mo->superClass()) {
        names << QLatin1StringView(mo->className());
        if (qstrcmp(mo->className(), "QWidget") == 0 || names.size() >= 5)
            break;
    }
    return names.join(QLatin1StringView("<"));
}

QString shortVariant(const QVariant &v)
{
    if (!v.isValid())
        return QString();
    const char *type = v.metaType().name();
    if (v.canConvert<QString>()) {
        QString s = v.toString();
        if (s.size() > 80)
            s = s.left(77) + QLatin1StringView("...");
        return QStringLiteral("%1:\"%2\"").arg(QLatin1StringView(type), s);
    }
    return QStringLiteral("%1").arg(QLatin1StringView(type));
}

QString rect(const QRect &r)
{
    return QStringLiteral("%1,%2 %3x%4").arg(r.x()).arg(r.y()).arg(r.width()).arg(r.height());
}

void dumpMetaObject(QTextStream &out, const QString &pad, const QMetaObject *mo)
{
    for (; mo && qstrcmp(mo->className(), "QObject") != 0 && qstrcmp(mo->className(), "QWidget") != 0
           && qstrcmp(mo->className(), "QAbstractItemView") != 0;
         mo = mo->superClass()) {
        out << pad << "  [meta " << mo->className() << "]";
        for (int i = mo->propertyOffset(); i < mo->propertyCount(); ++i)
            out << " prop:" << mo->property(i).typeName() << " " << mo->property(i).name();
        for (int i = mo->methodOffset(); i < mo->methodCount(); ++i)
            out << " method:" << mo->method(i).methodSignature().constData();
        out << "\n";
    }
}

void dumpObjectProperties(QTextStream &out, const QString &pad, const QObject *o)
{
    const QMetaObject *mo = o->metaObject();
    out << pad << "      object " << classChain(o);
    for (int i = 0; i < mo->propertyCount(); ++i) {
        const QString v = shortVariant(mo->property(i).read(o));
        if (!v.isEmpty() && qstrcmp(mo->property(i).name(), "objectName") != 0)
            out << " " << mo->property(i).name() << "=" << v;
    }
    out << "\n";
    dumpMetaObject(out, pad + QLatin1StringView("    "), mo);
}

void dumpItemData(QTextStream &out, const QString &pad, const QVariant &v)
{
    const QMetaType type = v.metaType();
    out << pad << "      itemData type=" << type.name() << " flags=0x" << Qt::hex << int(type.flags()) << Qt::dec
        << " metaObject=" << (type.metaObject() ? type.metaObject()->className() : "none") << "\n";
    if (type.flags() & QMetaType::PointerToQObject) {
        if (QObject *o = v.value<QObject *>())
            dumpObjectProperties(out, pad, o);
    } else if (type.metaObject()) {
        dumpMetaObject(out, pad + QLatin1StringView("    "), type.metaObject());
    }
}

void dumpModel(QTextStream &out, const QString &pad, QAbstractItemView *view)
{
    QAbstractItemModel *model = view->model();
    out << pad << "  [view] model=" << (model ? model->metaObject()->className() : "null")
        << " delegate=" << (view->itemDelegate() ? view->itemDelegate()->metaObject()->className() : "null");
    if (!model) {
        out << "\n";
        return;
    }
    out << " rows=" << model->rowCount() << " cols=" << model->columnCount() << "\n";
    const QHash<int, QByteArray> roleNames = model->roleNames();
    if (!roleNames.isEmpty()) {
        QStringList names;
        for (auto it = roleNames.cbegin(); it != roleNames.cend(); ++it)
            names << QStringLiteral("%1=%2").arg(it.key()).arg(QLatin1StringView(it.value()));
        out << pad << "  [view] roleNames " << names.join(QLatin1StringView(" ")) << "\n";
    }
    dumpMetaObject(out, pad, view->metaObject());
    for (QObject *child : view->children()) {
        if (!child->isWidgetType()) {
            out << pad << "  [view child] " << classChain(child) << " '" << child->objectName() << "'\n";
            dumpMetaObject(out, pad + QLatin1StringView("    "), child->metaObject());
        }
    }
    dumpMetaObject(out, pad, model->metaObject());
    const int rows = qMin(model->rowCount(), kMaxDumpRows);
    for (int r = 0; r < rows; ++r) {
        const QModelIndex idx = model->index(r, 0);
        out << pad << "  [row " << r << "] rect=" << rect(view->visualRect(idx));
        if (QWidget *iw = view->indexWidget(idx))
            out << " indexWidget=" << iw->metaObject()->className();
        out << "\n";
        dumpItemData(out, pad, model->data(idx, 257));
        QList<int> roles;
        for (int role = 0; role <= 15; ++role)
            roles << role;
        for (int role : roleNames.keys())
            if (!roles.contains(role))
                roles << role;
        for (int role : roles) {
            const QString v = shortVariant(model->data(idx, role));
            if (!v.isEmpty())
                out << pad << "      role " << role << " " << v << "\n";
        }
    }
}

void dumpWidget(QTextStream &out, QWidget *w, int depth)
{
    const QString pad(depth * 2, QLatin1Char(' '));
    out << pad << classChain(w);
    if (!w->objectName().isEmpty())
        out << " '" << w->objectName() << "'";
    out << " geo=" << rect(w->geometry()) << (w->isVisible() ? "" : " hidden");
    if (const QString text = widgetText(w); !text.isEmpty())
        out << " text=\"" << text.left(80) << "\"";
    if (QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(w)) {
        out << " ax=" << int(iface->role()) << ":\"" << iface->text(QAccessible::Name).left(60) << "\"";
        if (dynamic_cast<LineAccessibleWidget *>(iface))
            out << " [bridge]";
    }
    if (inheritsClass(w, "LcButton") || inheritsClass(w, "LcImage")) {
        const QMetaObject *mo = w->metaObject();
        for (int i = QWidget::staticMetaObject.propertyCount(); i < mo->propertyCount(); ++i) {
            const QVariant v = mo->property(i).read(w);
            if ((v.metaType().id() == QMetaType::QString && !v.toString().isEmpty()) || v.metaType().id() == QMetaType::Bool)
                out << " " << mo->property(i).name() << "=" << shortVariant(v);
        }
    }
    out << "\n";
    static QSet<QByteArray> dumpedWidgetClasses;
    if ((inheritsClass(w, "LcButton") || inheritsClass(w, "LcText") || inheritsClass(w, "LcImage"))
        && !dumpedWidgetClasses.contains(w->metaObject()->className())) {
        dumpedWidgetClasses.insert(w->metaObject()->className());
        dumpMetaObject(out, pad, w->metaObject());
    }
    if (auto *view = qobject_cast<QAbstractItemView *>(w))
        dumpModel(out, pad, view);
    for (QObject *child : w->children()) {
        if (child->isWidgetType())
            dumpWidget(out, static_cast<QWidget *>(child), depth + 1);
    }
}

void dumpAccessible(QTextStream &out, QAccessibleInterface *iface, int depth)
{
    if (!iface || depth > kMaxAccessibleDepth + 2)
        return;
    const QString pad(depth * 2, QLatin1Char(' '));
    QObject *o = iface->object();
    out << pad << "role=" << int(iface->role()) << " name=\"" << iface->text(QAccessible::Name).left(60)
        << "\" obj=" << (o ? o->metaObject()->className() : "-") << " children=" << iface->childCount() << "\n";
    const int count = qMin(iface->childCount(), 40);
    for (int i = 0; i < count; ++i)
        dumpAccessible(out, iface->child(i), depth + 1);
}

void dumpQuickItem(QTextStream &out, QQuickItem *item, int depth)
{
    if (!item || depth > 60)
        return;
    const QString pad(depth * 2, QLatin1Char(' '));
    const QRectF r = item->mapRectToScene(item->boundingRect());
    out << pad << classChain(item);
    if (!item->objectName().isEmpty())
        out << " '" << item->objectName() << "'";
    out << " geo=" << rect(r.toRect()) << (item->isVisible() ? "" : " hidden") << (item->isEnabled() ? "" : " disabled");
    const QMetaObject *mo = item->metaObject();
    for (int i = QQuickItem::staticMetaObject.propertyCount(); i < mo->propertyCount(); ++i) {
        const QMetaProperty p = mo->property(i);
        const int type = p.metaType().id();
        if (type != QMetaType::QString && type != QMetaType::Bool && type != QMetaType::QUrl && type != QMetaType::Int)
            continue;
        const QVariant v = p.read(item);
        if (type == QMetaType::QString || type == QMetaType::QUrl) {
            if (v.toString().isEmpty())
                continue;
        }
        out << " " << p.name() << "=" << shortVariant(v);
    }
    if (QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(item))
        out << " ax=" << int(iface->role()) << ":\"" << iface->text(QAccessible::Name).left(60) << "\"";
    out << "\n";
    static QSet<QByteArray> dumpedClasses;
    if (!dumpedClasses.contains(mo->className())) {
        dumpedClasses.insert(mo->className());
        for (const QMetaObject *m = mo; m && m != &QQuickItem::staticMetaObject; m = m->superClass()) {
            out << pad << "  [meta " << m->className() << "]";
            for (int i = m->methodOffset(); i < m->methodCount(); ++i) {
                if (m->method(i).methodType() == QMetaMethod::Signal || m->method(i).methodType() == QMetaMethod::Slot
                    || m->method(i).methodType() == QMetaMethod::Method)
                    out << " " << m->method(i).methodSignature().constData();
            }
            out << "\n";
        }
    }
    const QList<QQuickItem *> children = item->childItems();
    for (QQuickItem *child : children)
        dumpQuickItem(out, child, depth + 1);
}

} // namespace

bool writeWidgetDump()
{
    const QString path = QString::fromUtf8(a11yDirectory()) + QLatin1StringView("/widget-dump.txt");
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate | QIODevice::Text)) {
        a11yLog("[dump] cannot open %s", qPrintable(path));
        return false;
    }
    // Force a synchronous repaint of every visible item view first, so row hooks see fresh data.
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!top->isVisible())
            continue;
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            if (view->isVisible())
                view->viewport()->repaint();
        }
    }
    QTextStream out(&file);
    out << "# LINE widget dump " << QDateTime::currentDateTime().toString(Qt::ISODate) << "\n";
    for (QWindow *window : QGuiApplication::topLevelWindows()) {
        auto *quick = qobject_cast<QQuickWindow *>(window);
        out << "\n## QWindow " << classChain(window) << " \"" << window->title() << "\" visible=" << window->isVisible()
            << " geo=" << rect(window->geometry()) << "\n";
        if (quick && window->isVisible()) {
            if (QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(window))
                dumpAccessible(out, iface, 0);
            dumpQuickItem(out, quick->contentItem(), 0);
        }
    }
    for (QWidget *top : QApplication::topLevelWidgets()) {
        if (!top->isVisible())
            continue;
        out << "\n## window " << top->metaObject()->className() << " \"" << top->windowTitle() << "\"\n";
        dumpWidget(out, top, 0);
        out << "\n## painted texts and icons (text_capture)\n";
        for (QWidget *w : top->findChildren<QWidget *>()) {
            if (!w->isVisible() || !inheritsAnyClass(w, { "LcText", "LcButton", "LcImage", "LcCheckBox", "LcTextField" }))
                continue;
            const QString text = paintedText(w);
            const QString icon = paintedIcon(w);
            if (!text.isEmpty() || !icon.isEmpty())
                out << "  " << w->metaObject()->className() << " painted=\"" << text.left(80) << "\" icon=" << icon << "\n";
        }
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            if (!view->isVisible() || !view->model())
                continue;
            out << "  rows of " << view->metaObject()->className() << ":\n";
            for (int r = 0; r < view->model()->rowCount(view->rootIndex()) && r < 60; ++r) {
                const QRect rect = view->visualRect(view->model()->index(r, 0, view->rootIndex()));
                if (!rect.intersects(view->viewport()->rect()))
                    continue;
                const CaptureResult cap = captureRegionText(view->viewport(), rect);
                out << "    row " << r << " " << rect.width() << "x" << rect.height() << (cap.skipped ? " SKIPPED" : "")
                    << " text=\"" << capturedTextInReadingOrder(cap).replace(QLatin1Char('\n'), QLatin1StringView(" | ")).left(160)
                    << "\"";
                for (const PaintedImage &pi : cap.images)
                    out << " img[" << int(pi.rect.x()) << "," << int(pi.rect.y()) << " " << int(pi.rect.width()) << "x"
                        << int(pi.rect.height()) << (pi.alpha ? " a" : "") << (pi.clipped ? " clip" : "")
                        << (pi.clearCorners ? " cc" : "") << (pi.icon.isEmpty() ? QString() : QStringLiteral(" ") + pi.icon) << "]";
                for (const PaintedShape &sh : cap.shapes)
                    out << " shape[" << int(sh.rect.x()) << "," << int(sh.rect.y()) << " " << int(sh.rect.width()) << "x"
                        << int(sh.rect.height()) << "]";
                out << "\n";
            }
        }
        out << "\n## accessible tree of item views\n";
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            if (view->isVisible())
                dumpAccessible(out, QAccessible::queryAccessibleInterface(view), 0);
        }
    }
    // Which row does each delegate show? Look for row data-object pointers inside the delegate.
    QHash<quintptr, QString> rowObjects;
    for (QWidget *top : QApplication::topLevelWidgets()) {
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            QAbstractItemModel *model = view->model();
            if (!model || !view->isVisible())
                continue;
            for (int r = 0; r < model->rowCount(); ++r) {
                QObject *o = model->index(r, 0).data(Qt::UserRole + 1).value<QObject *>();
                if (o)
                    rowObjects.insert(reinterpret_cast<quintptr>(o),
                                      QStringLiteral("%1[%2]").arg(QLatin1StringView(model->metaObject()->className())).arg(r));
            }
        }
    }
    // QString-shaped members of property-less row data objects (and of objects they point to).
    auto plausible = [](const QString &t) {
        if (t.isEmpty() || t.size() > 2000)
            return false;
        int letters = 0;
        for (QChar c : t) {
            if (c.unicode() < 0x20 && c != QLatin1Char('\n'))
                return false;
            if (c.isSurrogate() || c.isNonCharacter())
                return false;
            if (c.isLetterOrNumber())
                ++letters;
        }
        return letters > 0;
    };
    auto scanStrings = [&](const void *base, size_t span) {
        QStringList found;
        for (size_t off = 0; off + sizeof(QString) <= span; off += sizeof(void *)) {
            const QString t = safeReadQString(static_cast<const char *>(base) + off);
            if (plausible(t))
                found << QStringLiteral("+0x%1=\"%2\"").arg(off, 0, 16).arg(t.startsWith(QLatin1Char('/')) ? t.right(90) : t.left(50));
        }
        return found;
    };
    // Render each visible message row offscreen; compare the picture with the delegate's texts.
    out << "\n## native buttons\n";
    for (const QString &line : nativeButtonReport())
        out << "  " << line << "\n";
    out << "\n## known icons\n";
    for (const QString &line : knownIconReport())
        out << "  " << line << "\n";
    out << "\n## rendered message rows\n";
    for (QWidget *top : QApplication::topLevelWidgets()) {
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            QAbstractItemModel *model = view->model();
            if (!model || !view->isVisible() || qstrcmp(model->metaObject()->className(), "ChatMessageModel") != 0)
                continue;
            for (int r = 0; r < model->rowCount(); ++r) {
                const QModelIndex idx = model->index(r, 0);
                const QRect rect = view->visualRect(idx) & view->viewport()->rect();
                if (rect.isEmpty())
                    continue;
                QImage image(rect.size() * 2, QImage::Format_ARGB32_Premultiplied);
                image.setDevicePixelRatio(2);
                image.fill(Qt::white);
                view->viewport()->render(&image, QPoint(), QRegion(rect), QWidget::DrawChildren);
                const QString file = QString::fromUtf8(a11yDirectory()) + QStringLiteral("/row-%1.png").arg(r);
                image.save(file);
                const quintptr data = reinterpret_cast<quintptr>(idx.data(Qt::UserRole + 1).value<QObject *>());
                QString shown;
                for (QWidget *w : QApplication::allWidgets()) {
                    if (w->isWindow() && lcListDelegateDataPointer(w) == data)
                        shown += QStringLiteral("%1 \"%2\" ").arg(QLatin1StringView(w->metaObject()->className()),
                                                                 collectVisibleChildTexts(w));
                }
                out << "[row " << r << "] " << file << " delegate: " << shown << "\n";
                for (QWidget *w : QApplication::allWidgets()) {
                    if (!w->isWindow() || lcListDelegateDataPointer(w) != data)
                        continue;
                    for (QWidget *t : w->findChildren<QWidget *>()) {
                        if (!inheritsClass(t, "LcText") || t->isHidden())
                            continue;
                        const QStringList both = lcTextPainterStrings(t);
                        out << "    LcText full=\"" << (both.value(0).left(40)) << "\" display=\"" << both.value(1).left(40) << "\"\n";
                    }
                }
            }
        }
    }

    // Small integer members that differ between message rows (content type candidates).
    out << "\n## message int columns\n";
    for (QWidget *top : QApplication::topLevelWidgets()) {
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            QAbstractItemModel *model = view->model();
            if (!model || !view->isVisible() || qstrcmp(model->metaObject()->className(), "ChatMessageModel") != 0)
                continue;
            const int rows = model->rowCount();
            // Columns in the object itself (via == -1) and in the structs its pointers lead to.
            for (int via = -1; via < 0; ++via) {
                for (size_t off = 0; off < 0x600; off += 4) {
                    QStringList values;
                    bool small = true;
                    QSet<qint32> distinct;
                    for (int r = 0; r < rows && small; ++r) {
                        QObject *o = model->index(r, 0).data(Qt::UserRole + 1).value<QObject *>();
                        const char *base = reinterpret_cast<const char *>(o);
                        if (o && via >= 0) {
                            const char *ptr = nullptr;
                            if (!safeRead(base + via, &ptr, sizeof(ptr)) || (reinterpret_cast<quintptr>(ptr) & 7))
                                ptr = nullptr;
                            base = ptr;
                        }
                        qint32 v = 0;
                        if (!base || !safeRead(base + off, &v, sizeof(v)) || v < 0 || v > 64)
                            small = false;
                        distinct.insert(v);
                        values << QString::number(v);
                    }
                    if (small && distinct.size() > 2)
                        out << (via < 0 ? QString() : QStringLiteral("->+0x%1").arg(via, 0, 16)) << " +0x"
                            << QString::number(off, 16) << ": " << values.join(QLatin1Char(' ')) << "\n";
                }
            }
        }
    }

    // Byte fields that are 0 on every text row and non-zero on every media row (content type).
    // Ground truth for every message row: scroll it into view, render it, note the delegate class
    // that now points at it, restore the scroll position (all within one event-loop turn).
    if (qEnvironmentVariableIntValue("LINE_A11Y_DUMP_ALL_ROWS") == 1) {
        out << "\n## all message rows\n";
        for (QWidget *top : QApplication::topLevelWidgets()) {
            for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
                QAbstractItemModel *model = view->model();
                if (!model || !view->isVisible() || qstrcmp(model->metaObject()->className(), "ChatMessageModel") != 0)
                    continue;
                QScrollBar *bar = view->verticalScrollBar();
                const int saved = bar ? bar->value() : 0;
                for (int r = 0; r < model->rowCount(); ++r) {
                    const QModelIndex idx = model->index(r, 0);
                    view->scrollTo(idx, QAbstractItemView::PositionAtCenter);
                    const QRect rect = view->visualRect(idx) & view->viewport()->rect();
                    QImage image(rect.size() * 2, QImage::Format_ARGB32_Premultiplied);
                    image.setDevicePixelRatio(2);
                    image.fill(Qt::white);
                    view->viewport()->render(&image, QPoint(), QRegion(rect), QWidget::DrawChildren);
                    image.save(QString::fromUtf8(a11yDirectory()) + QStringLiteral("/all-row-%1.png").arg(r));
                    const quintptr data = reinterpret_cast<quintptr>(idx.data(Qt::UserRole + 1).value<QObject *>());
                    QStringList classes;
                    for (QWidget *w : QApplication::allWidgets()) {
                        if (w->isWindow() && lcListDelegateDataPointer(w) == data)
                            classes << QLatin1StringView(w->metaObject()->className());
                    }
                    out << "[row " << r << "] rect=" << rect.height() << " " << classes.join(QLatin1Char(',')) << "\n";
                }
                if (bar)
                    bar->setValue(saved);
            }
        }
    }

    out << "\n## content type candidates\n";
    for (QWidget *top : QApplication::topLevelWidgets()) {
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            QAbstractItemModel *model = view->model();
            if (!model || !view->isVisible() || qstrcmp(model->metaObject()->className(), "ChatMessageModel") != 0)
                continue;
            const int rows = model->rowCount();
            QList<int> textRows, mediaRows;
            for (int r = 0; r < rows; ++r) {
                QObject *o = model->index(r, 0).data(Qt::UserRole + 1).value<QObject *>();
                const ChatMessageFields f = readChatMessageData(o);
                if (f.id.startsWith(QLatin1Char('l')))
                    continue;
                if (!f.text.isEmpty())
                    textRows << r;
                else if (!safeReadQString(reinterpret_cast<const char *>(o) + 0x1f0).isEmpty())
                    mediaRows << r;
            }
            out << "text rows " << textRows.size() << ", media rows " << mediaRows.size() << "\n";
            for (int via = -1; via < 0x300; via += (via < 0 ? 1 : 8)) {
                for (size_t off = 0; off < 0x300; ++off) {
                    auto byteAt = [&](int r, quint8 *v) {
                        QObject *o = model->index(r, 0).data(Qt::UserRole + 1).value<QObject *>();
                        const char *base = reinterpret_cast<const char *>(o);
                        if (o && via >= 0) {
                            const char *ptr = nullptr;
                            if (!safeRead(base + via, &ptr, sizeof(ptr)) || (reinterpret_cast<quintptr>(ptr) & 7))
                                return false;
                            base = ptr;
                        }
                        return base && safeRead(base + off, v, 1);
                    };
                    bool ok = !textRows.isEmpty() && !mediaRows.isEmpty();
                    for (int r : textRows) {
                        quint8 v = 1;
                        if (!byteAt(r, &v) || v != 0) { ok = false; break; }
                    }
                    QStringList media;
                    for (int r : mediaRows) {
                        quint8 v = 0;
                        if (!ok || !byteAt(r, &v) || v == 0 || v > 40) { ok = false; break; }
                        media << QStringLiteral("%1:%2").arg(r).arg(v);
                    }
                    if (ok)
                        out << (via < 0 ? QString() : QStringLiteral("->+0x%1").arg(via, 0, 16)) << " +0x"
                            << QString::number(off, 16) << " media " << media.join(QLatin1Char(' ')) << "\n";
                }
            }
        }
    }

    out << "\n## row object strings\n";
    for (QWidget *top : QApplication::topLevelWidgets()) {
        for (QAbstractItemView *view : top->findChildren<QAbstractItemView *>()) {
            QAbstractItemModel *model = view->model();
            if (!model || !view->isVisible() || qstrcmp(model->metaObject()->className(), "ChatMessageModel") != 0)
                continue;
            for (int r = 0; r < model->rowCount(); ++r) {
                QObject *o = model->index(r, 0).data(Qt::UserRole + 1).value<QObject *>();
                if (!o)
                    continue;
                out << "[row " << r << "] " << o->metaObject()->className() << " "
                    << scanStrings(o, 0x600).join(QLatin1StringView(" ")) << "\n";
                auto stampsIn = [](const void *base, size_t span) {
                    QStringList stamps;
                    for (size_t off = 0; off < span; off += 4) {
                        qint64 v = 0;
                        qint32 v32 = 0;
                        const char *at = static_cast<const char *>(base) + off;
                        if (off % 8 == 0 && safeRead(at, &v, sizeof(v))) {
                            const auto fmt = [&](qint64 ms, const char *kind) {
                                stamps << QStringLiteral("+0x%1(%2)=%3").arg(off, 0, 16).arg(QLatin1StringView(kind)).arg(
                                    QDateTime::fromMSecsSinceEpoch(ms).toString(QStringLiteral("MMM d hh:mm")));
                            };
                            if (v > 1577836800000LL && v < 1893456000000LL)
                                fmt(v, "ms");
                            else if ((v >> 8) > 1577836800000LL && (v >> 8) < 1893456000000LL)
                                fmt(v >> 8, "qdt");
                            else if (v > 1577836800LL && v < 1893456000LL)
                                fmt(v * 1000, "s64");
                            else if (v > 2458850 && v < 2462503)
                                stamps << QStringLiteral("+0x%1(qdate)=%2").arg(off, 0, 16).arg(
                                    QDate::fromJulianDay(v).toString(Qt::ISODate));
                        }
                        if (safeRead(at, &v32, sizeof(v32)) && v32 > 1577836800 && v32 < 1893456000)
                            stamps << QStringLiteral("+0x%1(s32)").arg(off, 0, 16);
                    }
                    return stamps;
                };
                out << "    stamps " << stampsIn(o, 0x300).join(QLatin1StringView(" ")) << "\n";
                for (size_t off = 0; off < 0x300; off += 8) {
                    const void *ptr = nullptr;
                    if (!safeRead(reinterpret_cast<const char *>(o) + off, &ptr, sizeof(ptr)) || !ptr
                        || (reinterpret_cast<quintptr>(ptr) & 7) != 0)
                        continue;
                    const QStringList found = stampsIn(ptr, 0x400);
                    if (!found.isEmpty())
                        out << "    ->+0x" << QString::number(off, 16) << " stamps " << found.join(QLatin1StringView(" ")) << "\n";
                }
                // One level of indirection: pointers stored in the object.
                for (size_t off = 0; off < 0x300; off += sizeof(void *)) {
                    const void *ptr = nullptr;
                    if (!safeRead(reinterpret_cast<const char *>(o) + off, &ptr, sizeof(ptr)) || !ptr
                        || (reinterpret_cast<quintptr>(ptr) & 7) != 0)
                        continue;
                    const QStringList inner = scanStrings(ptr, 0x200);
                    if (!inner.isEmpty())
                        out << "    ->+0x" << QString::number(off, 16) << " " << inner.join(QLatin1StringView(" ")) << "\n";
                }
            }
        }
    }

    out << "\n## delegate -> row data pointers (" << rowObjects.size() << " row objects)\n";
    for (QWidget *w : QApplication::allWidgets()) {
        if (!QLatin1StringView(w->metaObject()->className()).endsWith(QLatin1StringView("DelegateWidget")))
            continue;
        constexpr size_t kScan = 0x800;
        quintptr words[kScan / sizeof(quintptr)] = {};
        if (!safeRead(w, words, sizeof(words)))
            continue;
        QStringList hits;
        for (size_t i = 0; i < std::size(words); ++i) {
            if (const auto it = rowObjects.constFind(words[i]); it != rowObjects.cend())
                hits << QStringLiteral("+0x%1=%2").arg(i * sizeof(quintptr), 0, 16).arg(*it);
        }
        if (!hits.isEmpty())
            out << w->metaObject()->className() << " " << hits.join(QLatin1StringView(" ")) << " texts=\""
                << collectVisibleChildTexts(w).left(60) << "\"\n";
        if (!hits.isEmpty() && QLatin1StringView(w->metaObject()->className()).startsWith(QLatin1StringView("Chat")))
            dumpWidget(out, w, 1);
    }

    out << "\n## clickable images\n";
    for (QWidget *w : QApplication::allWidgets()) {
        if (!w->isVisible() || classifyWidget(w) != WidgetKind::Button || !inheritsClass(w, "LcImage"))
            continue;
        QStringList strings;
        for (size_t off = 0; off + sizeof(QString) <= 0x600; off += sizeof(void *)) {
            const QString t = safeReadQString(reinterpret_cast<const char *>(w) + off);
            if (plausible(t))
                strings << QStringLiteral("+0x%1=\"%2\"").arg(off, 0, 16).arg(t.left(70));
        }
        QStringList parents;
        for (QWidget *p = w->parentWidget(); p && parents.size() < 4; p = p->parentWidget())
            parents << QLatin1StringView(p->metaObject()->className());
        out << "LcImage " << rect(w->geometry()) << " in " << parents.join(QLatin1Char('>')) << " " << strings.join(QLatin1Char(' ')) << "\n";
    }

    out << "\n## tooltip / popup widgets\n";
    for (QWidget *w : QApplication::allWidgets()) {
        const QString cls = QLatin1StringView(w->metaObject()->className());
        if (!cls.contains(QLatin1StringView("ToolTip")) && !cls.contains(QLatin1StringView("Toast"))
            && !cls.contains(QLatin1StringView("Popup")) && !cls.contains(QLatin1StringView("Balloon")))
            continue;
        out << classChain(w) << " window=" << w->isWindow() << " type=0x" << Qt::hex << int(w->windowType()) << Qt::dec
            << " visible=" << w->isVisible() << " parent=" << (w->parentWidget() ? w->parentWidget()->metaObject()->className() : "-")
            << " text=\"" << collectVisibleChildTexts(w).left(60) << "\"\n";
    }

    out << "\n## delegate widgets (all)\n";
    for (QWidget *w : QApplication::allWidgets()) {
        if (!QLatin1StringView(w->metaObject()->className()).endsWith(QLatin1StringView("DelegateWidget")))
            continue;
        QStringList parents;
        for (QWidget *p = w->parentWidget(); p && parents.size() < 6; p = p->parentWidget())
            parents << QLatin1StringView(p->metaObject()->className());
        out << w->metaObject()->className() << " geo=" << rect(w->geometry()) << (w->isVisible() ? "" : " hidden")
            << " parents=" << (parents.isEmpty() ? QStringLiteral("<none>") : parents.join(QLatin1StringView(">")))
            << " texts=\"" << collectVisibleChildTexts(w).left(120) << "\"\n";
        static QSet<QByteArray> dumpedClasses;
        if (!dumpedClasses.contains(w->metaObject()->className())) {
            dumpedClasses.insert(w->metaObject()->className());
            dumpMetaObject(out, QString(), w->metaObject());
        }
    }
    a11yLog("[dump] wrote %s", qPrintable(path));
    return true;
}

void pollDumpRequest()
{
    const std::string request = requestPath();
    struct stat st {};
    if (stat(request.c_str(), &st) != 0)
        return;
    unlink(request.c_str());
    writeWidgetDump();
}

} // namespace line_a11y
