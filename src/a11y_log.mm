#include "a11y_log.h"

#import <Foundation/Foundation.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <mutex>
#include <string>

namespace line_a11y {
namespace {

constexpr const char *kBundleId = "jp.naver.line.mac";

std::string parentDirectory(const std::string &path)
{
    const auto slash = path.find_last_of('/');
    return slash == std::string::npos ? std::string() : path.substr(0, slash);
}

std::string computeA11yDirectory()
{
    // Preferred: derive from our own location, ".../a11y/platformthemes/libline_a11y.dylib".
    Dl_info info{};
    if (dladdr(reinterpret_cast<const void *>(&computeA11yDirectory), &info) && info.dli_fname) {
        const std::string pluginDir = parentDirectory(info.dli_fname);
        if (pluginDir.size() > 15 && pluginDir.compare(pluginDir.size() - 15, 15, "/platformthemes") == 0)
            return parentDirectory(pluginDir);
    }

    // Fallback: the Darwin user cache dir. Inside LINE's sandbox it already carries the
    // bundle-id suffix ("/var/folders/../C/jp.naver.line.mac/"); outside it does not.
    char buf[PATH_MAX] = {};
    if (confstr(_CS_DARWIN_USER_CACHE_DIR, buf, sizeof(buf)) > 0) {
        std::string dir(buf);
        while (!dir.empty() && dir.back() == '/')
            dir.pop_back();
        const std::string suffix = std::string("/") + kBundleId;
        if (dir.size() < suffix.size() || dir.compare(dir.size() - suffix.size(), suffix.size(), suffix) != 0)
            dir += suffix;
        return dir + "/a11y";
    }

    @autoreleasepool {
        return std::string(NSTemporaryDirectory().fileSystemRepresentation) + "line_a11y";
    }
}

struct LogState {
    std::mutex mutex;
    std::string directory;
    FILE *file = nullptr;
    bool opened = false;
};

LogState &state()
{
    static LogState *s = new LogState; // intentionally leaked: usable during static destruction
    return *s;
}

FILE *logFile(LogState &s)
{
    if (s.opened)
        return s.file;
    s.opened = true;
    s.directory = computeA11yDirectory();
    mkdir(s.directory.c_str(), 0755);
    const std::string path = s.directory + "/a11y.log";
    s.file = fopen(path.c_str(), "a");
    if (!s.file) {
        @autoreleasepool {
            const std::string fallback = std::string(NSTemporaryDirectory().fileSystemRepresentation) + "line_a11y.log";
            s.file = fopen(fallback.c_str(), "a");
        }
    }
    if (s.file)
        setvbuf(s.file, nullptr, _IOLBF, 0);
    return s.file;
}

} // namespace

const char *a11yDirectory()
{
    LogState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    logFile(s);
    return s.directory.c_str();
}

void a11yLog(const char *fmt, ...)
{
    LogState &s = state();
    std::lock_guard<std::mutex> lock(s.mutex);
    FILE *f = logFile(s);
    if (!f)
        return;

    struct timespec ts {};
    clock_gettime(CLOCK_REALTIME, &ts);
    struct tm tmv {};
    localtime_r(&ts.tv_sec, &tmv);
    char stamp[32];
    strftime(stamp, sizeof(stamp), "%Y-%m-%d %H:%M:%S", &tmv);

    uint64_t tid = 0;
    pthread_threadid_np(nullptr, &tid);
    fprintf(f, "%s.%03ld [pid %d tid %llu] ", stamp, ts.tv_nsec / 1000000, getpid(),
            static_cast<unsigned long long>(tid));

    va_list ap;
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);

    const size_t len = strlen(fmt);
    if (len == 0 || fmt[len - 1] != '\n')
        fputc('\n', f);
}

} // namespace line_a11y
