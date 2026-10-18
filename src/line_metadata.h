// Qt 6.6 plugin metadata for libline_a11y.dylib.
//
// Qt's QFactoryLoader scans every dylib in "<QT_PLUGIN_PATH>/platformthemes" for a
// `__TEXT,qtmetadata` section that starts with the magic string "QTMETADATA !",
// followed by a 4-byte header (metadata version, Qt major, Qt minor, arch
// requirements) and a CBOR map. This is byte-for-byte what moc would emit for
//
//   Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QPA.QPlatformThemeFactoryInterface.5.1"
//                     FILE "line_a11y.json")   // {"Keys": ["cocoa"]}
//
// The CBOR integer keys are QtPluginMetaDataKeys: 2 = IID, 3 = ClassName, 4 = MetaData.
// The layout was cross-checked against LINE.app/Contents/PlugIns/platforms/libqcocoa.dylib.

#pragma once

#include <QtCore/qplugin.h>

namespace line_a11y {

inline constexpr unsigned char kPluginMetaData[] = {
    0xbf,                                   // map (indefinite length)
    // key 2: "IID"
    0x02,
    0x78, 0x38,                             // text(56)
    'o', 'r', 'g', '.', 'q', 't', '-', 'p', 'r', 'o', 'j', 'e', 'c', 't', '.',
    'Q', 't', '.', 'Q', 'P', 'A', '.',
    'Q', 'P', 'l', 'a', 't', 'f', 'o', 'r', 'm', 'T', 'h', 'e', 'm', 'e',
    'F', 'a', 'c', 't', 'o', 'r', 'y', 'I', 'n', 't', 'e', 'r', 'f', 'a', 'c', 'e',
    '.', '5', '.', '1',
    // key 3: "className"
    0x03,
    0x6e,                                   // text(14)
    'L', 'i', 'n', 'e', 'A', '1', '1', 'y', 'P', 'l', 'u', 'g', 'i', 'n',
    // key 4: "MetaData" -> {"Keys": ["cocoa"]}
    0x04,
    0xa1,                                   // map(1)
    0x64, 'K', 'e', 'y', 's',               // text(4) "Keys"
    0x81,                                   // array(1)
    0x65, 'c', 'o', 'c', 'o', 'a',          // text(5) "cocoa"
    0xff,                                   // break
};

static_assert(sizeof("org.qt-project.Qt.QPA.QPlatformThemeFactoryInterface.5.1") - 1 == 0x38,
              "IID length must match its CBOR text header");

} // namespace line_a11y
