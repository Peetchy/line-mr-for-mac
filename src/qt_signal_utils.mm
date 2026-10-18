#include "qt_signal_utils.h"

#include <QtCore/QMetaMethod>

// QObjectPrivate::connect(sender, methodIndex, receiver, slotObject, type) is exported by QtCore
// but declared only in the private qobject_p.h. It connects a signal by index to a slot object.
QT_BEGIN_NAMESPACE
class QObjectPrivate
{
public:
    Q_DECL_IMPORT static QMetaObject::Connection connect(const QObject *sender, int signal_index,
                                                         const QObject *receiver,
                                                         QtPrivate::QSlotObjectBase *slotObj,
                                                         Qt::ConnectionType type);
};
QT_END_NAMESPACE

namespace line_a11y {
namespace {

class RawSlot : public QtPrivate::QSlotObjectBase
{
public:
    using Fn = std::function<void(void **)>;
    explicit RawSlot(Fn fn)
        : QSlotObjectBase(&impl)
        , m_fn(std::move(fn))
    {
    }

private:
    static void impl(int which, QSlotObjectBase *self, QObject *, void **args, bool *ret)
    {
        switch (which) {
        case Destroy:
            delete static_cast<RawSlot *>(self);
            break;
        case Call:
            static_cast<RawSlot *>(self)->m_fn(args);
            break;
        case Compare:
            if (ret)
                *ret = false;
            break;
        default:
            break;
        }
    }

    Fn m_fn;
};

// The class in `sender`'s hierarchy that declares method `index`, and the signal's index among
// that class's own signals (what QMetaObject::activate() expects).
bool localSignalIndex(const QObject *sender, int index, const QMetaObject **declaring, int *local)
{
    for (const QMetaObject *mo = sender->metaObject(); mo; mo = mo->superClass()) {
        if (index < mo->methodOffset())
            continue;
        int count = 0;
        for (int i = mo->methodOffset(); i < index; ++i) {
            if (mo->method(i).methodType() == QMetaMethod::Signal)
                ++count;
        }
        *declaring = mo;
        *local = count;
        return true;
    }
    return false;
}

} // namespace

int signalIndex(const QObject *sender, const char *signature)
{
    const QMetaObject *mo = sender->metaObject();
    const int index = mo->indexOfSignal(QMetaObject::normalizedSignature(signature).constData());
    return index >= 0 && mo->method(index).methodType() == QMetaMethod::Signal ? index : -1;
}

QMetaObject::Connection connectRaw(QObject *sender, int signal, QObject *context, std::function<void(void **)> fn)
{
    return QObjectPrivate::connect(sender, signal, context, new RawSlot(std::move(fn)), Qt::DirectConnection);
}

bool emitRaw(QObject *sender, int signal, void **args)
{
    const QMetaObject *declaring = nullptr;
    int local = -1;
    if (!sender || signal < 0 || !localSignalIndex(sender, signal, &declaring, &local))
        return false;
    void *noArgs[] = { nullptr };
    QMetaObject::activate(sender, declaring, local, args ? args : noArgs);
    return true;
}

bool emitSignal(QObject *sender, const char *signature, void **args)
{
    return sender && emitRaw(sender, signalIndex(sender, signature), args);
}

} // namespace line_a11y
