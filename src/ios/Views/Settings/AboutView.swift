import SwiftUI
import UIKit

struct AboutView: View {
    /// 版本号走 `SelfUpdate`，不读 Bundle。
    ///
    /// 原因：这个 App 的版本线是自有的（1.0.0 起步），跟原版 1.15.x
    /// 没有大小关系。读 Bundle 会拿到 pbxproj 里的值，两处不一致时
    /// 「关于页显示 1.0、检查更新却按别的数比」—— 这种 bug 查起来很费劲。
    /// `SelfUpdate` 是唯一真源，这里只做展示。
    private let appVersion: String = SelfUpdate.displayVersion

    /// 更新源。`SelfUpdate` 没有 @Published，所以得自己订阅变更，
    /// 否则用户在设置里改完更新源回到这一页，链接还指着旧仓库。
    @State private var updateRepo: String = SelfUpdate.repo

    /// When this binary was built, from the executable's modification date.
    ///
    /// Exists because the version string alone cannot answer "is the fix I
    /// just shipped actually running on that device?" — CFBundleVersion is
    /// static across rebuilds, so an OTA install that silently didn't replace
    /// the app looks identical to one that did. That ambiguity has cost real
    /// debugging time on the test devices. Same source as the debug server's
    /// `buildDate`, but visible in Release too, where no debug server exists.
    /// [T-env-diagnostic-line] One line naming the RUNTIME environment, for
    /// bug reports.
    ///
    /// A macOS 27 rendering report cost a full round trip because nothing in
    /// the app said which environment it was: "Designed for iPad" (an
    /// unmodified iOS binary on Apple Silicon) and Mac Catalyst (UIKit bridged
    /// onto AppKit) look identical in a screenshot but share almost no
    /// rendering path, and the SDK release notes that explain a symptom apply
    /// to one and not the other. Guessing wrong sends the whole diagnosis down
    /// the wrong track.
    ///
    /// `isiOSAppOnMac` is the authoritative discriminator and is what
    /// distinguishes the two; `targetEnvironment(macCatalyst)` is resolved at
    /// COMPILE time, so it reports how this binary was built rather than where
    /// it is running — both are printed because the pair is what identifies
    /// the mode unambiguously.
    private let environmentLine: String = {
        let osv = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(osv.majorVersion).\(osv.minorVersion).\(osv.patchVersion)"
        let idiom: String = switch UIDevice.current.userInterfaceIdiom {
        case .phone: "phone"
        case .pad: "pad"
        case .mac: "mac"
        case .tv: "tv"
        case .carPlay: "carPlay"
        case .vision: "vision"
        default: "unspecified"
        }
        #if targetEnvironment(macCatalyst)
        let built = "catalyst"
        #else
        let built = "ios"
        #endif
        let onMac = ProcessInfo.processInfo.isiOSAppOnMac
        // "iOSAppOnMac" is Designed for iPad; "catalyst" built + not
        // isiOSAppOnMac is a true Catalyst run; otherwise a real device.
        let mode = onMac ? "iOSAppOnMac" : (built == "catalyst" ? "catalyst" : "device")
        return "\(mode) · \(idiom) · OS \(os) · built:\(built)"
    }()

    private let buildDate: String = {
        guard let url = Bundle.main.executableURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mod = attrs[.modificationDate] as? Date
        else { return "unknown" }
        let fmt = DateFormatter()
        // Local time, seconds included: this gets compared by eye against the
        // timestamp of a build that just finished.
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return fmt.string(from: mod)
    }()

    var body: some View {
        List {
            // MARK: - Project Info
            Section {
                VStack(spacing: 8) {
                    if let icon = UIImage(named: "AppIcon60x60") ?? UIImage(named: "AppIcon") {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(Color(UIColor.separator), lineWidth: 0.5)
                            )
                    }
                    Text("全能AI · 改造版")
                        .font(.title2.bold())
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Built \(buildDate)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        // Selectable so it can be copied into a bug report.
                        .textSelection(.enabled)
                    // [T-env-diagnostic-line] Sits with the build date because
                    // it answers the same question — "what exactly is running?"
                    // — and gets copied into the same bug reports.
                    Text(environmentLine)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                    Text("本地运行、不上传的端上 Agent。这一版是自建版本线，更新只走你自己指定的仓库。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            // MARK: - Links
            //
            // 这里刻意**不再链到原版仓库和原版 issue 页**。
            // 我们是独立版本线：往原版报 bug 既是噪声，也会把用户
            // 引到「去装原版」的路上。链接只留我们自己的更新源。
            Section("Links") {
                if !updateRepo.isEmpty {
                    Link(destination: URL(string: "https://github.com/\(updateRepo)")!) {
                        Label {
                            HStack {
                                Text("更新源仓库")
                                    .foregroundStyle(Color(UIColor.label))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "link.circle.fill")
                        }
                    }
                }
                // 没配更新源时不给「去提 issue」的链接。
                // 指向原版 issue 页会把人引到原版项目去，那既解决不了
                // 我们的问题，也暗示「该去装原版」。宁可少一个链接。
                if !updateRepo.isEmpty {
                    Link(destination: URL(string: "https://github.com/\(updateRepo)/issues")!) {
                        Label {
                            HStack {
                                Text("给更新源提 Issue")
                                    .foregroundStyle(Color(UIColor.label))
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                    }
                }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: .selfUpdateSourceChanged)) { _ in
            updateRepo = SelfUpdate.repo
        }
    }
}
