#include "call_launch_hook.h"

#include "a11y_log.h"

#import <AppKit/AppKit.h>

#include <objc/runtime.h>

namespace line_a11y {
namespace {

NSString *const kCallBundleId = @"jp.naver.line.mac.LineCall";

using OpenImp = void (*)(id, SEL, NSURL *, NSWorkspaceOpenConfiguration *, id);
using LaunchImp = NSRunningApplication *(*)(id, SEL, NSURL *, NSWorkspaceLaunchOptions, NSDictionary *, NSError **);

OpenImp g_originalOpen = nullptr;
LaunchImp g_originalLaunch = nullptr;

// ".../C/jp.naver.line.mac/a11y" -> ".../C/jp.naver.line.mac.LineCall/a11y"
NSString *callPluginPath()
{
    NSString *ours = [NSString stringWithUTF8String:a11yDirectory()];
    NSString *cacheRoot = ours.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    return [[cacheRoot stringByAppendingPathComponent:kCallBundleId] stringByAppendingPathComponent:@"a11y"];
}

bool isCallApp(NSURL *url)
{
    if (!url.isFileURL)
        return false;
    NSString *bundleId = [NSBundle bundleWithURL:url].bundleIdentifier;
    return [bundleId isEqualToString:kCallBundleId] || [url.lastPathComponent isEqualToString:@"LineCall.app"];
}

NSDictionary<NSString *, NSString *> *withPluginPath(NSDictionary<NSString *, NSString *> *environment)
{
    NSMutableDictionary<NSString *, NSString *> *env = environment ? [environment mutableCopy] : [NSMutableDictionary dictionary];
    env[@"QT_PLUGIN_PATH"] = callPluginPath();
    return env;
}

// LaunchServices drops the environment of apps launched by a sandboxed app, but passes arguments:
// `-platformpluginpath` makes Qt load the platform shim (src/platform_shim.mm) from there.
NSArray<NSString *> *withPlatformPluginPath(NSArray<NSString *> *arguments)
{
    if ([arguments containsObject:@"-platformpluginpath"])
        return arguments;
    NSMutableArray<NSString *> *args = arguments ? [arguments mutableCopy] : [NSMutableArray array];
    [args addObject:@"-platformpluginpath"];
    [args addObject:[callPluginPath() stringByAppendingPathComponent:@"platforms"]];
    return args;
}

void hookedOpen(id self, SEL cmd, NSURL *url, NSWorkspaceOpenConfiguration *configuration, id completion)
{
    if (isCallApp(url)) {
        NSWorkspaceOpenConfiguration *config = configuration ? [configuration copy] : [NSWorkspaceOpenConfiguration configuration];
        config.environment = withPluginPath(config.environment);
        config.arguments = withPlatformPluginPath(config.arguments);
        a11yLog("[call] launching %s with %s", url.path.UTF8String, [config.arguments componentsJoinedByString:@" "].UTF8String);
        configuration = config;
    }
    g_originalOpen(self, cmd, url, configuration, completion);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
NSRunningApplication *hookedLaunch(id self, SEL cmd, NSURL *url, NSWorkspaceLaunchOptions options, NSDictionary *configuration,
                                   NSError **error)
{
    if (isCallApp(url)) {
        NSMutableDictionary *config = configuration ? [configuration mutableCopy] : [NSMutableDictionary dictionary];
        config[NSWorkspaceLaunchConfigurationEnvironment] = withPluginPath(config[NSWorkspaceLaunchConfigurationEnvironment]);
        config[NSWorkspaceLaunchConfigurationArguments] = withPlatformPluginPath(config[NSWorkspaceLaunchConfigurationArguments]);
        a11yLog("[call] launching %s (legacy API) with QT_PLUGIN_PATH=%s", url.path.UTF8String, callPluginPath().UTF8String);
        configuration = config;
    }
    return g_originalLaunch(self, cmd, url, options, configuration, error);
}
#pragma clang diagnostic pop

} // namespace

void installCallLaunchHook()
{
    static bool installed = false;
    if (installed)
        return;
    installed = true;
    if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"jp.naver.line.mac"])
        return;
    Class cls = [NSWorkspace class];
    if (Method m = class_getInstanceMethod(cls, @selector(openApplicationAtURL:configuration:completionHandler:)))
        g_originalOpen = reinterpret_cast<OpenImp>(method_setImplementation(m, reinterpret_cast<IMP>(hookedOpen)));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (Method m = class_getInstanceMethod(cls, @selector(launchApplicationAtURL:options:configuration:error:)))
        g_originalLaunch = reinterpret_cast<LaunchImp>(method_setImplementation(m, reinterpret_cast<IMP>(hookedLaunch)));
#pragma clang diagnostic pop
    a11yLog("[call] LineCall launch hook installed (open=%d legacy=%d), plugin path %s", g_originalOpen ? 1 : 0,
            g_originalLaunch ? 1 : 0, callPluginPath().UTF8String);
}

} // namespace line_a11y
