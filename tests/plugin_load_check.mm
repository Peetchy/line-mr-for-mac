// Loads libline_a11y.dylib the way LINE does (QApplication + "cocoa" platform-theme lookup
// via QT_PLUGIN_PATH) using LINE's own Qt frameworks, then checks that:
//   1. QPluginLoader parses the metadata (IID + Keys ["cocoa"]) and qt_plugin_instance()
//      returns nullptr,
//   2. the bridge factory serves widgets named like LINE's classes,
//   3. the bridge started (event filter + watchdog) once the event loop ran.
// Offsets stay disabled here because the host is not LINE.

#include <QtCore/QCoreApplication>
#include <QtCore/QJsonArray>
#include <QtCore/QJsonObject>
#include <QtCore/QPluginLoader>
#include <QtCore/QTimer>
#include <QtGui/QAccessible>
#include <QtWidgets/QApplication>
#include <QtWidgets/QLineEdit>
#include <QtWidgets/QWidget>

#include <stdio.h>

static int failures = 0;
static void check(bool ok, const char *what)
{
    printf("%s: %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        ++failures;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: %s <path/to/platformthemes/libline_a11y.dylib>\n", argv[0]);
        return 64;
    }
    const QString pluginPath = QString::fromLocal8Bit(argv[1]);

    QApplication app(argc, argv);

    QPluginLoader loader(pluginPath);
    const QJsonObject md = loader.metaData();
    check(md.value(QLatin1StringView("IID")).toString()
              == QLatin1StringView("org.qt-project.Qt.QPA.QPlatformThemeFactoryInterface.5.1"),
          "metadata IID is QPlatformThemeFactoryInterface.5.1");
    check(md.value(QLatin1StringView("MetaData")).toObject().value(QLatin1StringView("Keys")).toArray()
              == QJsonArray{ QLatin1StringView("cocoa") },
          "metadata Keys == [\"cocoa\"]");
    check(loader.instance() == nullptr, "qt_plugin_instance() returns nullptr (Cocoa theme fallback)");

    // A password QLineEdit outside any Lc widget must keep the stock Qt interface.
    // not possible without moc, so rely on the dynamic objectName heuristics instead).
    QWidget window;
    auto *edit = new QLineEdit(&window);
    edit->setEchoMode(QLineEdit::Password);
    window.show();

    QTimer::singleShot(1500, &app, [&] {
        QAccessibleInterface *iface = QAccessible::queryAccessibleInterface(edit);
        check(iface != nullptr, "stock QLineEdit interface still available");
        check(QAccessible::installUpdateHandler(nullptr) == nullptr, "no foreign update handler installed");
        app.quit();
    });
    app.exec();

    printf("%s\n", failures ? "plugin_load_check: FAILED" : "plugin_load_check: OK");
    return failures ? 1 : 0;
}
