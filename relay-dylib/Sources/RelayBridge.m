//
//  RelayBridge.m
//  RelayDylib — 借 App 自己的配置写入通道加一条服务商
//
//  ============================================================
//  为什么绕这一圈
//
//  dylib 是独立模块，编译期看不到 App 的 Swift 类型
//  （ProviderConfigStore / ProvidersCollection 都是 internal），
//  更不能自己去改 provider-config.json —— v3 之后 SQLite
//  （provider-config.db）才是权威，JSON 只是降级镜像：手写 JSON
//  会在下次启动被 DB dump 覆盖掉，等于白写。
//
//  但 App 已经把「改配置」这件事用 `@objc public class
//  ConfigOffloadBridge` 暴露给 ObjC 运行通了（官方自己的
//  minis-config CLI 就走这条）。它的 `writeFields` 支持
//  `providers.add`，一次调用就把下面这些全做完：
//
//    · 建 ProviderInstance，写 Keychain 里的 API Key
//    · 写 SQLite + 写 JSON 镜像
//    · 按接口拉 /v1/models 填模型列表（addInstance 里自带）
//    · 记一条可回滚的配置审计
//
//  代价：它走的是「用户确认」通道，保存后 App 会弹一次它自己的
//  确认弹窗。那是官方给 agent 改配置设的闸门，正式包里没有
//  bypass（writeFieldsForDebug 在 #if DEBUG 里），也确实不该绕。
//
//  找类用「类名后缀」扫 objc_getClassList，不写死
//  `Module.ConfigOffloadBridge`：模块名会随上游改，后缀不会。
//  ============================================================

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <stdlib.h>

/// 在已注册的 ObjC 类里按「类名后缀」找一个类。
/// Swift 里 `@objc public class Foo` 注册出来的名字是 `Module.Foo`，
/// 所以这里连点和模块前缀一起忽略，只认结尾。
static Class RelayFindClassWithSuffix(NSString *suffix) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) { return Nil; }

    Class *classes = (Class *)calloc((size_t)count, sizeof(Class));
    if (classes == NULL) { return Nil; }

    Class found = Nil;
    int real = objc_getClassList(classes, count);
    for (int i = 0; i < real; i++) {
        Class cls = classes[i];
        if (cls == Nil) { continue; }
        const char *raw = class_getName(cls);
        if (raw == NULL) { continue; }
        NSString *name = [NSString stringWithUTF8String:raw];
        if (name != nil && [name hasSuffix:suffix]) {
            found = cls;
            break;
        }
    }
    free(classes);
    return found;
}

/// 在类方法里按「方法名前缀」找 selector。
/// 不写死 `writeFieldsWithItems:caption:actorRaw:sessionId:`：
/// Swift 给首参生成 ObjC 名字的规则（WithXxx）不值得赌，扫前缀更稳。
static SEL RelayFindClassMethodWithPrefix(Class cls, NSString *prefix) {
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        Class meta = object_getClass(c);
        if (meta == Nil) { continue; }

        unsigned int count = 0;
        Method *methods = class_copyMethodList(meta, &count);
        if (methods == NULL) { continue; }

        SEL found = NULL;
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if (name != nil && [name hasPrefix:prefix]) {
                found = method_getName(methods[i]);
                break;
            }
        }
        free(methods);
        if (found != NULL) { return found; }
    }
    return NULL;
}

/// 找写入方法：先按 Swift 的标准首参命名试一次，不行再按前缀扫。
/// 优先精确名是因为 release 包里只有这一个 writeFields*；
/// 前缀扫是给「上游哪天改了参数名」留的后路。
static SEL RelayFindWriteSelector(Class cls) {
    SEL preferred = NSSelectorFromString(@"writeFieldsWithItems:caption:actorRaw:sessionId:");
    if (preferred != NULL && [cls respondsToSelector:preferred]) {
        return preferred;
    }
    return RelayFindClassMethodWithPrefix(cls, @"writeFields");
}

static NSDictionary *RelayBridgeFailure(NSString *code, NSString *reason) {
    return @{
        @"ok": @NO,
        @"error": code,
        @"reason": reason,
    };
}

/// 找不到写入方法时，把类上所有含 "write" 的方法名打进日志。
/// 真机上排查「官方改了接口」时，这一行比任何猜测都有用。
static void RelayLogWriteCandidates(Class cls) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (Class c = cls; c != Nil; c = class_getSuperclass(c)) {
        Class meta = object_getClass(c);
        if (meta == Nil) { continue; }
        unsigned int count = 0;
        Method *methods = class_copyMethodList(meta, &count);
        if (methods == NULL) { continue; }
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if (name != nil && [name rangeOfString:@"write"].location != NSNotFound) {
                [names addObject:name];
            }
        }
        free(methods);
    }
    NSLog(@"[RelayDylib] ConfigOffloadBridge 的 write* 类方法：%@",
          names.count > 0 ? [names componentsJoinedByString:@", "] : @"（一个都没有）");
}

/// 调 App 的 minis-config 写入通道，执行 `providers.add`。
///
/// @param payload 服务商配置，字段与 ProvidersCollection.add 一致：
///                providerType / label / apiKey / customBaseURL /
///                appendV1Suffix / imageEndpointMode
/// @return App 原样返回的 envelope（ok / applied / write_errors / reason …）。
///         本函数自己出错时返回同形状的 {ok:false, error:…, reason:…}。
///
/// 注意：内部会阻塞到用户在 App 的确认弹窗上点了「允许 / 拒绝」，
/// 最长 30 秒。调用方必须在后台线程调，别在主线程等。
NSDictionary *RelayConfigAddProvider(NSDictionary *payload) {
    if (payload == nil) {
        return RelayBridgeFailure(@"invalid_args", @"payload 为空");
    }

    Class cls = RelayFindClassWithSuffix(@"ConfigOffloadBridge");
    if (cls == Nil) {
        return RelayBridgeFailure(@"bridge_missing",
                                  @"当前 App 版本里没有 ConfigOffloadBridge（这个版本不支持从外部写入服务商）");
    }

    SEL sel = RelayFindWriteSelector(cls);
    if (sel == NULL) {
        RelayLogWriteCandidates(cls);
        return RelayBridgeFailure(@"bridge_missing",
                                  @"ConfigOffloadBridge 上没有 writeFields… 方法（官方改过接口）");
    }

    NSError *jsonError = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:&jsonError];
    if (jsonData == nil) {
        return RelayBridgeFailure(@"invalid_args",
                                  [NSString stringWithFormat:@"payload 无法序列化：%@",
                                   jsonError.localizedDescription ?: @"unknown"]);
    }
    NSString *valueJSON = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (valueJSON == nil) {
        return RelayBridgeFailure(@"invalid_args", @"payload 无法转成 UTF-8 JSON 文本");
    }

    // 与 minis-config CLI 的 `set providers.add '<json>'` 完全等价。
    NSArray *items = @[ @{ @"path": @"providers.add", @"value_json": valueJSON } ];

    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    if (sig == nil || sig.numberOfArguments < 6) {
        return RelayBridgeFailure(@"bridge_missing", @"writeFields 的参数个数对不上（官方改过签名）");
    }

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:sig];
    invocation.target = cls;
    invocation.selector = sel;

    NSArray *argItems = items;
    NSString *argCaption = @"添加中转站";
    // 审计里记成 user：这次确实是用户在本机点的「保存」。
    NSString *argActor = @"user";
    NSString *argSession = nil;

    [invocation setArgument:&argItems atIndex:2];
    [invocation setArgument:&argCaption atIndex:3];
    [invocation setArgument:&argActor atIndex:4];
    [invocation setArgument:&argSession atIndex:5];
    [invocation invoke];

    __unsafe_unretained id returned = nil;
    [invocation getReturnValue:&returned];
    if (![returned isKindOfClass:[NSDictionary class]]) {
        return RelayBridgeFailure(@"unexpected_return",
                                  @"写入通道返回的不是字典（官方改过返回类型）");
    }
    return (NSDictionary *)returned;
}
