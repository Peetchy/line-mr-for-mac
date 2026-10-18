// LINE.app ships QtQml's headers without the QtQmlIntegration module they include. The bridge only
// uses QQuickItem / QQuickWindow from C++, so the QML registration macros can expand to nothing.
#pragma once

#define QML_ELEMENT
#define QML_ANONYMOUS
#define QML_INTERFACE
#define QML_SINGLETON
#define QML_VALUE_TYPE(...)
#define QML_CONSTRUCTIBLE_VALUE
#define QML_STRUCTURED_VALUE
#define QML_SEQUENTIAL_CONTAINER(...)
#define QML_NAMED_ELEMENT(...)
#define QML_UNCREATABLE(...)
#define QML_UNAVAILABLE
#define QML_FOREIGN(...)
#define QML_FOREIGN_NAMESPACE(...)
#define QML_ATTACHED(...)
#define QML_EXTENDED(...)
#define QML_EXTENDED_NAMESPACE(...)
#define QML_ADDED_IN_VERSION(...)
#define QML_ADDED_IN_MINOR_VERSION(...)
#define QML_REMOVED_IN_VERSION(...)
#define QML_REMOVED_IN_MINOR_VERSION(...)
#define QML_EXTRA_VERSION(...)
#define QML_IMPLEMENTS_INTERFACES(...)
