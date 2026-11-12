//
//  DeviceOffload.m
//  MinisApp
//
//  Native offload handler for `apple-device`.
//  Subcommands: info, battery, storage, env
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>
#include <stdlib.h>
#include <errno.h>
#include <dlfcn.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <mach/mach.h>

// SecTask* 在 Security.framework 里是未公开符号，而且这个工程没有显式链
// Security.framework（Swift 那边靠 autolink 拿到，ObjC 这边没有），
// 直接调会变成 undefined symbol。所以运行时 dlsym 取，少一个链接依赖。
typedef struct __SecTask *SecTaskRef;
typedef SecTaskRef (*SecTaskCreateFromSelfFn)(CFAllocatorRef);
typedef CFTypeRef (*SecTaskCopyValueForEntitlementFn)(SecTaskRef, CFStringRef, CFErrorRef *);

static NSString *const TOOL_NAME = @"apple-device";

static NSString *const HELP_TEXT =
    @"apple-device - Query device information\n"
     "\n"
     "USAGE:\n"
     "  apple-device [command] [options]\n"
     "\n"
     "COMMANDS:\n"
     "  info       Full device info (model, OS, CPU, memory, disk, network)\n"
     "             (default when no command given)\n"
     "  battery    Battery level and charging state\n"
     "  storage    Disk space information\n"
     "  env        Host filesystem environment: jailbreak kind, TrollStore /\n"
     "             platform-application entitlement, sandbox state.\n"
     "             This reads REAL iOS paths from the app process — unlike\n"
     "             the shell, whose / is an Alpine fake rootfs.\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h      Show this help message\n"
     "  --compact       Minimize JSON output\n"
     "  -q, --quiet     Output only data field\n"
     "\n"
     "EXAMPLES:\n"
     "  apple-device                   (same as: apple-device info)\n"
     "  apple-device battery\n"
     "  apple-device storage --compact\n"
     "  apple-device env\n";

static NSString *thermal_state_string(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateNominal:  return @"nominal";
        case NSProcessInfoThermalStateFair:     return @"fair";
        case NSProcessInfoThermalStateSerious:  return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
        default: return @"unknown";
    }
}

static NSString *battery_state_string(UIDeviceBatteryState state) {
    switch (state) {
        case UIDeviceBatteryStateUnplugged: return @"unplugged";
        case UIDeviceBatteryStateCharging:  return @"charging";
        case UIDeviceBatteryStateFull:      return @"full";
        default: return @"unknown";
    }
}

static NSDictionary *get_battery_data(void) {
    __block NSDictionary *data;
    noff_dispatch_main_sync(^id{
        UIDevice *dev = [UIDevice currentDevice];
        BOOL wasEnabled = dev.batteryMonitoringEnabled;
        dev.batteryMonitoringEnabled = YES;

        float level = dev.batteryLevel;
        UIDeviceBatteryState state = dev.batteryState;

        if (!wasEnabled) dev.batteryMonitoringEnabled = NO;

        data = @{
            @"level": level >= 0 ? @(level) : [NSNull null],
            @"level_percent": level >= 0 ? @((int)(level * 100)) : [NSNull null],
            @"state": battery_state_string(state),
            @"monitoring_enabled": @YES,
        };
        return nil;
    });
    return data;
}

/// Report free space the way Settings → General → iPhone Storage does.
///
/// [T-ios-device-storage-purgeable #102] `NSFileSystemFreeSize` is statfs's
/// `f_bavail`, which counts PURGEABLE space (caches, evictable Photos copies,
/// re-downloadable content) as UNAVAILABLE. Settings counts it as available, so
/// on a device with a large purgeable pool the two disagree badly — the reporter
/// saw ~230 GiB missing.
///
/// `NSURLVolumeAvailableCapacityForImportantUsageKey` is Apple's answer: per the
/// SDK header it is "total available capacity for 'Important' resources,
/// INCLUDING space expected to be cleared by purging non-essential and cached
/// resources" — i.e. the Settings number. iOS 11+, and our deployment target is
/// far above that, so no availability guard is needed.
///
/// Deliberate choices:
///   - `total_bytes` stays on statfs. `NSURLVolumeTotalCapacityKey` is
///     documented as an `int`-backed NSNumber and overflows on large volumes;
///     statfs's f_blocks*f_bsize does not.
///   - The important-usage value is read as `long long` (its documented backing
///     type), NOT `unsignedLongLongValue` — a negative/sentinel value would wrap
///     to ~1.8e19 and report an absurd free size.
///   - On ANY failure we fall back to the old statfs number rather than
///     emitting 0. Reporting 0 free would read as "device is full" and could
///     make an agent delete user data. [issue #102 review note]
static NSDictionary *get_storage_data(void) {
    NSError *error = nil;
    NSDictionary *attrs = [[NSFileManager defaultManager]
        attributesOfFileSystemForPath:NSHomeDirectory()
                                error:&error];
    if (!attrs) {
        return @{@"error": error.localizedDescription ?: @"unknown"};
    }

    unsigned long long totalSpace = [attrs[NSFileSystemSize] unsignedLongLongValue];
    // statfs f_bavail — excludes purgeable. Kept as the fallback and reported
    // alongside so callers can still see the conservative figure.
    unsigned long long freeExcludingPurgeable = [attrs[NSFileSystemFreeSize] unsignedLongLongValue];

    // Preferred figure: matches Settings.
    unsigned long long freeSpace = freeExcludingPurgeable;
    BOOL includesPurgeable = NO;
    NSURL *homeURL = [NSURL fileURLWithPath:NSHomeDirectory() isDirectory:YES];
    NSNumber *importantFree = nil;
    NSError *volErr = nil;
    if ([homeURL getResourceValue:&importantFree
                           forKey:NSURLVolumeAvailableCapacityForImportantUsageKey
                            error:&volErr]
        && importantFree != nil) {
        long long v = importantFree.longLongValue;
        // Guard the documented failure shapes: the key is optional and may come
        // back nil or non-positive on volumes that can't answer.
        if (v > 0) {
            freeSpace = (unsigned long long)v;
            includesPurgeable = YES;
        }
    }

    // used = total - (what the user can actually fill). Derived from the SAME
    // figure as free_bytes so used/free/usage_percent stay self-consistent;
    // otherwise usage_percent would keep the old inflated reading.
    unsigned long long usedSpace = totalSpace > freeSpace ? totalSpace - freeSpace : 0;
    // Purgeable is the gap between the two measurements. Only meaningful when
    // the important-usage read succeeded.
    unsigned long long purgeable = (includesPurgeable && freeSpace > freeExcludingPurgeable)
        ? freeSpace - freeExcludingPurgeable
        : 0;

    return @{
        @"total_bytes": @(totalSpace),
        @"free_bytes": @(freeSpace),
        @"used_bytes": @(usedSpace),
        @"total_gb": @(totalSpace / (1024.0 * 1024.0 * 1024.0)),
        @"free_gb": @(freeSpace / (1024.0 * 1024.0 * 1024.0)),
        @"used_gb": @(usedSpace / (1024.0 * 1024.0 * 1024.0)),
        @"usage_percent": totalSpace > 0 ? @((double)usedSpace / totalSpace * 100.0) : @(0),
        // Transparency fields: which measurement is in free_bytes, and the
        // conservative statfs figure for callers that must not count on purging.
        @"free_bytes_excluding_purgeable": @(freeExcludingPurgeable),
        @"purgeable_bytes": @(purgeable),
        @"free_includes_purgeable": @(includesPurgeable),
    };
}

static int cmd_info(int stdout_fd, BOOL compact, BOOL quiet) {
    __block NSDictionary *deviceData;

    noff_dispatch_main_sync(^id{
        UIDevice *dev = [UIDevice currentDevice];
        deviceData = @{
            @"name": dev.name ?: @"",
            @"system_name": dev.systemName ?: @"",
            @"system_version": dev.systemVersion ?: @"",
            @"model": dev.model ?: @"",
            @"localized_model": dev.localizedModel ?: @"",
            @"identifier_for_vendor": dev.identifierForVendor.UUIDString ?: @"",
            @"user_interface_idiom": (dev.userInterfaceIdiom == UIUserInterfaceIdiomPad) ? @"pad" : @"phone",
        };
        return nil;
    });

    struct utsname sysinfo;
    uname(&sysinfo);
    NSString *machine = [NSString stringWithCString:sysinfo.machine encoding:NSUTF8StringEncoding];

    NSProcessInfo *pi = [NSProcessInfo processInfo];
    NSUInteger physMem = pi.physicalMemory;

    // Get active memory usage
    mach_task_basic_info_data_t taskInfo;
    mach_msg_type_number_t infoCount = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                  (task_info_t)&taskInfo, &infoCount);
    NSNumber *appMemory = (kr == KERN_SUCCESS) ? @(taskInfo.resident_size) : [NSNull null];

    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    data[@"device"] = deviceData;
    data[@"machine"] = machine ?: @"unknown";
    data[@"processor_count"] = @(pi.processorCount);
    data[@"active_processor_count"] = @(pi.activeProcessorCount);
    data[@"physical_memory_bytes"] = @(physMem);
    data[@"physical_memory_gb"] = @(physMem / (1024.0 * 1024.0 * 1024.0));
    data[@"app_memory_bytes"] = appMemory;
    data[@"thermal_state"] = thermal_state_string(pi.thermalState);
    data[@"is_low_power_mode"] = @(pi.isLowPowerModeEnabled);
    data[@"os_version"] = pi.operatingSystemVersionString;
    data[@"uptime_seconds"] = @(pi.systemUptime);
    data[@"battery"] = get_battery_data();
    data[@"storage"] = get_storage_data();

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"info", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_battery(int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *data = get_battery_data();
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"battery", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_storage(int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *data = get_storage_data();
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"storage", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// ── env ────────────────────────────────────────────────────────────
//
// 越狱/提权形态探测，跑在**宿主 app 进程**里，查的是真实 iOS 路径。
//
// 为什么必须有这个子命令：shell_execute 跑的是 iSH 里的 Alpine 假根，
// 它的 `/` 是镜像文件渲染出来的，`/var/jb`、`/var/mobile`、`/Applications`
// 在里面永远不存在。模型拿 shell 去查越狱，结论必然是「无越狱」——
// 不管手机上装的是 TrollStore、Dopamine 还是什么都没装。
//
// 也不要把「没有 /var/jb」当成「没越狱」：TrollStore 根本不是越狱，
// 它没有 /var/jb，但会把 app 的签名换成 platform-application，
// 于是这个进程能读写 /var/mobile、能装任意签名的 ipa。

/// stat() 的 errno 能区分「沙箱拒了」和「真的不存在」，这是可信度的关键：
///   · stat 成功       → 确实有；
///   · ENOENT          → 确实没有（可信）；
///   · EPERM / EACCES  → 这条路径看不见，不能当成「不存在」。
typedef struct {
    BOOL exists;
    BOOL denied;
} NoffProbe;

static NoffProbe noff_probe(NSString *path) {
    NoffProbe result = {NO, NO};
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) == 0) {
        result.exists = YES;
        return result;
    }
    int err = errno;
    result.denied = (err == EACCES || err == EPERM);
    return result;
}

/// 能不能列目录 —— 沙箱外的目录列不动，这是「有没有被沙箱关着」最直接的证据。
static BOOL noff_dir_listable(NSString *path) {
    NSError *err = nil;
    NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:&err];
    return items != nil && err == nil;
}

/// 本进程自己的签名权限。符号是 dlsym 取的，取不到就返回 NO。
static BOOL noff_has_entitlement(NSString *name) {
    static SecTaskCreateFromSelfFn createFromSelf = NULL;
    static SecTaskCopyValueForEntitlementFn copyValue = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/Frameworks/Security.framework/Security",
                              RTLD_LAZY);
        if (!handle) return;
        createFromSelf = (SecTaskCreateFromSelfFn)dlsym(handle, "SecTaskCreateFromSelf");
        copyValue = (SecTaskCopyValueForEntitlementFn)dlsym(handle,
                                                           "SecTaskCopyValueForEntitlement");
    });
    if (!createFromSelf || !copyValue) return NO;

    SecTaskRef task = createFromSelf(kCFAllocatorDefault);
    if (!task) return NO;

    CFTypeRef value = copyValue(task, (__bridge CFStringRef)name, NULL);
    BOOL granted = NO;
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            granted = CFBooleanGetValue((CFBooleanRef)value);
        } else if (CFGetTypeID(value) == CFStringGetTypeID()) {
            granted = CFStringGetLength((CFStringRef)value) > 0;
        }
        CFRelease(value);
    }
    CFRelease(task);
    return granted;
}

static int cmd_env(int stdout_fd, BOOL compact, BOOL quiet) {
    // ── 越狱痕迹 ──
    // rootless（Dopamine / palera1n rootless）：越狱根挂在 /var/jb
    NoffProbe jbVar     = noff_probe(@"/var/jb");
    NoffProbe jbPreboot = noff_probe(@"/private/preboot/jb");
    // rootful（unc0ver / checkra1n 一代）：直接改系统分区 / 装注入框架
    NoffProbe cydia     = noff_probe(@"/Applications/Cydia.app");
    NoffProbe bash      = noff_probe(@"/bin/bash");
    NoffProbe sshd      = noff_probe(@"/usr/sbin/sshd");
    NoffProbe substrate = noff_probe(@"/usr/lib/libsubstrate.dylib");
    NoffProbe hooker    = noff_probe(@"/usr/lib/libhooker.dylib");
    NoffProbe ellekit   = noff_probe(@"/usr/lib/libellekit.dylib");
    // TrollStore 的安装助手
    NoffProbe tsHelper  = noff_probe(@"/var/containers/Bundle/trollstorehelper");

    BOOL rootless = jbVar.exists || jbPreboot.exists;
    BOOL rootful  = cydia.exists || bash.exists || sshd.exists
                 || substrate.exists || hooker.exists || ellekit.exists;

    // ── 提权 / 沙箱状态 ──
    BOOL canListVarMobile = noff_dir_listable(@"/var/mobile");
    BOOL platformApp      = noff_has_entitlement(@"platform-application");
    BOOL noSandbox        = noff_has_entitlement(@"com.apple.private.security.no-sandbox");
    BOOL getTaskAllow     = noff_has_entitlement(@"get-task-allow");

    NSString *jailbreak = @"none";
    if (rootless) {
        jailbreak = @"rootless";
    } else if (rootful) {
        jailbreak = @"rootful";
    } else if (tsHelper.exists || platformApp || noSandbox) {
        jailbreak = @"trollstore";
    }

    // 有没有被沙箱挡住过。挡住过就说明「没查不到」不等于「没有」，
    // 这时候结论只能叫 low —— 不装懂。
    BOOL denied = jbVar.denied || jbPreboot.denied || cydia.denied
               || substrate.denied || hooker.denied || ellekit.denied;
    NSString *confidence = denied ? @"low" : @"high";

    NSString *note;
    if (denied) {
        note = @"At least one probe came back EPERM/EACCES instead of ENOENT: the sandbox "
                "blocked the look inside, so \"not found\" here does NOT mean \"not there\". "
                "Treat this answer as undetectable rather than as \"no jailbreak\"; install "
                "through TrollStore (platform-application) to read the real state.";
    } else if ([jailbreak isEqualToString:@"trollstore"]) {
        note = @"TrollStore is NOT a jailbreak: no /var/jb, no root filesystem write access. "
                "What it does give you is a platform-application signature, so this process "
                "can read /var/mobile, install any signed ipa and repackage apps. Expect "
                "jailbreak-only things (substrate/ellekit injection into other processes, "
                "dpkg, sshd) to be absent.";
    } else if ([jailbreak isEqualToString:@"none"]) {
        note = @"No jailbreak artifacts on the real iOS filesystem, and no elevated "
                "entitlement: this is a sandboxed app on a stock device.";
    } else {
        note = @"Jailbreak artifacts found on the real iOS filesystem; injection libraries "
                "are listed under checks.";
    }

    NSMutableDictionary *checks = [NSMutableDictionary dictionary];
    checks[@"var_jb"]              = @(jbVar.exists);
    checks[@"private_preboot_jb"]  = @(jbPreboot.exists);
    checks[@"cydia_app"]           = @(cydia.exists);
    checks[@"bin_bash"]            = @(bash.exists);
    checks[@"usr_sbin_sshd"]       = @(sshd.exists);
    checks[@"libsubstrate"]        = @(substrate.exists);
    checks[@"libhooker"]           = @(hooker.exists);
    checks[@"libellekit"]          = @(ellekit.exists);
    checks[@"trollstore_helper"]   = @(tsHelper.exists);
    checks[@"list_var_mobile"]     = @(canListVarMobile);
    checks[@"sandbox_denied_probe"] = @(denied);

    NSMutableDictionary *ents = [NSMutableDictionary dictionary];
    ents[@"platform-application"] = @(platformApp);
    ents[@"com.apple.private.security.no-sandbox"] = @(noSandbox);
    ents[@"get-task-allow"] = @(getTaskAllow);

    const char *dyldInsert = getenv("DYLD_INSERT_LIBRARIES");

    NSMutableDictionary *data = [NSMutableDictionary dictionary];
    data[@"jailbreak"] = jailbreak;
    data[@"confidence"] = confidence;
    data[@"is_sandboxed"] = @(!(noSandbox || canListVarMobile));
    data[@"uid"] = @((int)getuid());
    data[@"entitlements"] = ents;
    data[@"checks"] = checks;
    data[@"dyld_insert_libraries"] = dyldInsert
        ? [NSString stringWithUTF8String:dyldInsert]
        : (id)[NSNull null];
    data[@"shell_rootfs"] = @"alpine (iSH fake root) — its / is NOT the iOS filesystem";
    data[@"note"] = note;

    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"env", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int device_handler(int argc, char **argv,
                           int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd) {
        // [T-offload-defaults-batch-ios] Bare `apple-device` (including
        // flags-only invocations) defaults to `info` — the full-info dump is
        // the obvious "tell me about this device" intent. (Android's
        // android-device defaults to its `all` verb; the verbs differ per
        // platform but the bare-invocation behavior now matches.)
        subcmd = @"info";
    }

    if ([subcmd isEqualToString:@"info"]) {
        return cmd_info(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"battery"]) {
        return cmd_battery(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"storage"]) {
        return cmd_storage(stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"env"]) {
        return cmd_env(stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd,
                                         NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid commands: info, battery, storage, env. Use --help for details.", subcmd]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void device_offload_register(void) {
    int err = native_offload_add_handler("apple-device", device_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/apple-device");
        NSLog(@"NativeOffloads: apple-device handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register apple-device handler (err=%d)", err);
    }
}
