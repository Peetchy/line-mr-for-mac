// libqcocoa_a11y.dylib: a stand-in "cocoa" platform-integration plugin for LineCall.app.
//
// LaunchServices drops the environment LINE passes when it launches LineCall, so QT_PLUGIN_PATH
// cannot reach it (see src/call_launch_hook.h). Command-line arguments do get through, and Qt
// honours `-platformpluginpath DIR`: it looks for the platform plugin ("cocoa") in DIR before its
// own PlugIns/platforms. This plugin lives in that DIR; its qt_plugin_instance() bootstraps the
// accessibility bridge (../platformthemes/libline_a11y.dylib) and hands Qt the real Cocoa plugin's
// instance from LINE.app/Contents/PlugIns/platforms/libqcocoa.dylib, so nothing else changes.

#include <QtCore/QObject>
#include <QtCore/qplugin.h>

#include <dlfcn.h>
#include <stdio.h>
#include <string>

namespace {

// moc's output for Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QPA.QPlatformIntegrationFactoryInterface.5.3")
// with {"Keys": ["cocoa"]}; same layout as src/line_metadata.h (checked against libqcocoa.dylib).
constexpr unsigned char kShimMetaData[] = {
    0xbf,
    0x02,
    0x78, 0x3e,
    'o', 'r', 'g', '.', 'q', 't', '-', 'p', 'r', 'o', 'j', 'e', 'c', 't', '.',
    'Q', 't', '.', 'Q', 'P', 'A', '.',
    'Q', 'P', 'l', 'a', 't', 'f', 'o', 'r', 'm', 'I', 'n', 't', 'e', 'g', 'r', 'a', 't', 'i', 'o', 'n',
    'F', 'a', 'c', 't', 'o', 'r', 'y', 'I', 'n', 't', 'e', 'r', 'f', 'a', 'c', 'e',
    '.', '5', '.', '3',
    0x03,
    0x77,
    'Q', 'C', 'o', 'c', 'o', 'a', 'I', 'n', 't', 'e', 'g', 'r', 'a', 't', 'i', 'o', 'n',
    'P', 'l', 'u', 'g', 'i', 'n',
    0x04,
    0xa1,
    0x64, 'K', 'e', 'y', 's',
    0x81,
    0x65, 'c', 'o', 'c', 'o', 'a',
    0xff,
};

static_assert(sizeof("org.qt-project.Qt.QPA.QPlatformIntegrationFactoryInterface.5.3") - 1 == 0x3e,
              "IID length must match its CBOR text header");

using InstanceFn = QObject *(*)();

std::string parentDirectory(const std::string &path, int levels = 1)
{
    std::string dir = path;
    for (int i = 0; i < levels; ++i) {
        const auto slash = dir.find_last_of('/');
        if (slash == std::string::npos)
            return std::string();
        dir.resize(slash);
    }
    return dir;
}

std::string imagePath(const void *address)
{
    Dl_info info{};
    return dladdr(address, &info) && info.dli_fname ? std::string(info.dli_fname) : std::string();
}

InstanceFn instanceOf(const std::string &path)
{
    void *handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "libqcocoa_a11y: cannot load %s: %s\n", path.c_str(), dlerror());
        return nullptr;
    }
    return reinterpret_cast<InstanceFn>(dlsym(handle, "qt_plugin_instance"));
}

} // namespace

extern "C" Q_DECL_EXPORT QT_PREPEND_NAMESPACE(QPluginMetaData) qt_plugin_query_metadata_v2()
{
    static constexpr QT_PLUGIN_METADATAV2_SECTION QPluginMetaDataV2<kShimMetaData> md{};
    return md;
}

extern "C" Q_DECL_EXPORT QT_PREPEND_NAMESPACE(QObject) *qt_plugin_instance()
{
    static QObject *instance = [] () -> QObject * {
        // ".../a11y/platforms/libqcocoa_a11y.dylib" -> ".../a11y/platformthemes/libline_a11y.dylib"
        const std::string a11yDir = parentDirectory(imagePath(reinterpret_cast<const void *>(&qt_plugin_instance)), 2);
        if (InstanceFn bridge = instanceOf(a11yDir + "/platformthemes/libline_a11y.dylib"))
            bridge(); // bootstraps the bridge; returns nullptr

        // ".../Contents/Frameworks/QtCore.framework/Versions/A/QtCore" -> ".../Contents/PlugIns/platforms/libqcocoa.dylib"
        const std::string contents = parentDirectory(imagePath(reinterpret_cast<const void *>(&qVersion)), 5);
        InstanceFn cocoa = instanceOf(contents + "/PlugIns/platforms/libqcocoa.dylib");
        return cocoa ? cocoa() : nullptr;
    }();
    return instance;
}
