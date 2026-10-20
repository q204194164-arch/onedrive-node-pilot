import SwiftUI
import AppKit
import ServiceManagement

enum CloudBoltIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)?
                .draw(in: NSRect(x: 0, y: 2, width: 20, height: 14))
            if let context = NSGraphicsContext.current?.cgContext {
                context.saveGState()
                context.setBlendMode(.clear)
                context.move(to: CGPoint(x: 11, y: 13))
                context.addLine(to: CGPoint(x: 7.3, y: 8.6))
                context.addLine(to: CGPoint(x: 9.5, y: 8.6))
                context.addLine(to: CGPoint(x: 8.6, y: 5.1))
                context.addLine(to: CGPoint(x: 12.6, y: 9.6))
                context.addLine(to: CGPoint(x: 10.3, y: 9.6))
                context.closePath()
                context.fillPath()
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

@MainActor final class PilotModel: ObservableObject {
    @Published var running = false
    @Published var status = "准备检查 OneDrive 专用线路"
    @Published var selected = "读取中…"
    @Published var report: ScanReport?
    @Published var nextDate: Date?
    @Published var automatic: Bool { didSet { UserDefaults.standard.set(automatic, forKey: "automatic"); reschedule() } }
    @Published var minutes: Int { didSet { UserDefaults.standard.set(minutes, forKey: "minutes"); reschedule() } }
    @Published var loginEnabled = false
    @Published var loginMessage = ""
    @Published var followOneDrive = false
    @Published var followMessage = ""
    private static let watcherLabel = "io.github.onedrivepilot.follow"
    private var watcherPlist: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/" + Self.watcherLabel + ".plist") }
    private let engine = PilotEngine()
    private var control = ScanControl()
    private var timer: Timer?
    private var rotation: Int
    private var observers: [NSObjectProtocol] = []
    private let stateURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/OneDrive Node Pilot/latest.json")
    init(preview: Bool = false) {
        let defaults = UserDefaults.standard
        automatic = preview ? true : (defaults.object(forKey: "automatic") as? Bool ?? true)
        let saved = defaults.integer(forKey: "minutes"); minutes = [15, 30, 60, 120].contains(saved) ? saved : 30
        rotation = defaults.integer(forKey: "rotation")
        report = try? JSONDecoder().decode(ScanReport.self, from: Data(contentsOf: stateURL))
        if let report { selected = report.selected; status = report.message }
        loginEnabled = SMAppService.mainApp.status == .enabled
        followOneDrive = FileManager.default.fileExists(atPath: watcherPlist.path)
        if preview { return }
        let shutdownEngine = engine
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in shutdownEngine.stopHelper() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.cancel(); self?.timer?.invalidate(); self?.nextDate = nil }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reschedule() }
        })
        reschedule()
        if automatic { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); await scan() } }
    }
    func reschedule() {
        timer?.invalidate(); timer = nil; nextDate = nil
        guard automatic, !running else { return }
        nextDate = Date().addingTimeInterval(Double(minutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.scan() }
        }
        timer?.tolerance = 30
    }
    func scan() async {
        guard !running else { return }
        running = true; timer?.invalidate(); nextDate = nil; control = ScanControl()
        status = "启动独立测速，不改动其他软件线路…"
        let currentControl = control, round = rotation, currentEngine = engine
        defer { running = false; reschedule() }
        do {
            let target = self
            let result = try await Task.detached(priority: .utility) {
                try await currentEngine.scan(rotation: round, control: currentControl, progress: { text in
                    Task { @MainActor in target.status = text }
                }, connected: { node in Task { @MainActor in target.selected = node } })
            }.value
            report = result; selected = result.selected; status = result.message
            rotation += 1; UserDefaults.standard.set(rotation, forKey: "rotation")
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(result).write(to: stateURL, options: .atomic)
        } catch is CancellationError { status = "已停止，本轮未自动切换。" }
        catch { status = error.localizedDescription }
    }
    func cancel() { control.cancel(); status = "正在停止，本轮不再切换…" }
    func quit() { control.cancel(); engine.stopHelper(); NSApplication.shared.terminate(nil) }
    func setFollowOneDrive(_ value: Bool) {
        let domain = "gui/\(getuid())"
        do {
            if value {
                let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/OneDriveLaunchWatcher")
                guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw RouterError.message("找不到启动联动组件，请重新安装 App。") }
                let settings: [String: Any] = ["Label": Self.watcherLabel, "ProgramArguments": [helper.path], "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10, "ProcessType": "Background"]
                let data = try PropertyListSerialization.data(fromPropertyList: settings, format: .xml, options: 0)
                try FileManager.default.createDirectory(at: watcherPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: watcherPlist, options: .atomic)
                let (code, _) = try Command.run("/bin/launchctl", ["bootstrap", domain, watcherPlist.path])
                if code != 0 {
                    let (loaded, _) = try Command.run("/bin/launchctl", ["print", domain + "/" + Self.watcherLabel])
                    if loaded != 0 { try? FileManager.default.removeItem(at: watcherPlist); throw RouterError.message("无法启用启动联动，请重试。") }
                }
            } else {
                _ = try Command.run("/bin/launchctl", ["bootout", domain + "/" + Self.watcherLabel])
                let (stillLoaded, _) = try Command.run("/bin/launchctl", ["print", domain + "/" + Self.watcherLabel])
                guard stillLoaded != 0 else { throw RouterError.message("启动联动尚未停止，请重试。") }
                if FileManager.default.fileExists(atPath: watcherPlist.path) { try FileManager.default.removeItem(at: watcherPlist) }
            }
            followOneDrive = value; followMessage = ""
        } catch { followMessage = error.localizedDescription }
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 登录项中允许。" : ""
        } catch { loginMessage = "登录项设置未成功：" + error.localizedDescription }
    }
}

struct NodeLabel {
    var flag: String
    var title: String
    var subtitle: String
    init(_ raw: String) {
        let pieces = raw.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        let first = pieces.first ?? raw
        let flags = first.filter { $0.unicodeScalars.contains { (0x1F1E6...0x1F1FF).contains($0.value) } }
        flag = flags
        title = first.replacingOccurrences(of: flags, with: "").trimmingCharacters(in: .whitespaces)
        subtitle = pieces.dropFirst().joined(separator: " / ")
    }
}

struct PilotView: View {
    @ObservedObject var model: PilotModel
    @State private var expanded = true
    @State private var settings = false
    @State private var nodeDetails = false
    private var waiting: Bool { model.status.contains("其他") && (model.status.contains("传输") || model.status.contains("暂停")) }
    private var headline: String {
        if model.running { return "正在检查" }
        if waiting { return "等待空闲" }
        if model.status.contains("无法") || model.status.contains("失败") { return "需要检查" }
        return model.automatic ? "自动选线已就绪" : "自动检查已暂停"
    }
    private var statusColor: Color { model.running ? .blue : waiting ? .orange : .secondary }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(nsImage: CloudBoltIcon.image).resizable().scaledToFit().frame(width: 29, height: 25).foregroundStyle(.blue)
                Text("OneDrive 选线").font(.system(size: 17, weight: .semibold))
                Spacer()
                Button { settings.toggle() } label: { Image(systemName: "gearshape").font(.system(size: 19)).foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("设置与测速说明").accessibilityLabel("设置")
                    .popover(isPresented: $settings) { settingsView }
            }.padding(.bottom, 13)
            Divider()
            HStack(alignment: .top, spacing: 9) {
                if model.running { ProgressView().controlSize(.small).frame(width: 12).padding(.top, 3) }
                else { Image(systemName: "circle.fill").font(.system(size: 11)).foregroundStyle(statusColor).padding(.top, 4) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(headline).font(.system(size: 15, weight: .semibold))
                    Text(waiting ? "网络使用中，保留当前节点" : model.status)
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineLimit(3)
                }
            }.padding(.vertical, 10)
            Button { nodeDetails.toggle() } label: {
                let node = NodeLabel(model.selected)
                HStack(spacing: 12) {
                    if !node.flag.isEmpty { Text(node.flag).font(.system(size: 30)) }
                    else { Image(systemName: "network").font(.system(size: 25)).foregroundStyle(.blue) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(node.title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
                        if !node.subtitle.isEmpty { Text(node.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).help("查看当前专用节点")
                .popover(isPresented: $nodeDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("当前 OneDrive 专用节点").font(.headline)
                        Text(model.selected).textSelection(.enabled)
                        Text("仅自动选择 OneDrive 专用线路，其他应用继续遵循 Clash 原有分流。").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).frame(width: 300)
                }
            Divider().padding(.vertical, 10)
            HStack(spacing: 7) {
                Text("每")
                Picker("检查间隔", selection: $model.minutes) {
                    ForEach([15, 30, 60, 120], id: \.self) { Text("\($0) 分钟").tag($0) }
                }.labelsHidden().pickerStyle(.menu).frame(width: 108)
                Text("检查一次")
                Spacer(minLength: 5)
                Toggle("自动检查", isOn: Binding(get: { model.automatic }, set: { value in
                    model.automatic = value
                    if !value && model.running { model.cancel() }
                })).labelsHidden().toggleStyle(SwitchToggleStyle(tint: .blue)).controlSize(.small).help("开启或暂停自动检查")
            }.font(.system(size: 13))
            Group {
                if let next = model.nextDate { Text("下次 \(next.formatted(date: .omitted, time: .shortened))") }
                else { Text(model.running ? "本轮结束后安排下次检查" : "自动检查已暂停") }
            }.font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 7)
            Button { if model.running { model.cancel() } else { Task { await model.scan() } } } label: {
                Text(model.running ? "停止本轮检查" : "立即检查").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 7)
            }.buttonStyle(.plain).foregroundStyle(.white).background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8)).padding(.top, 12)
            Divider().padding(.vertical, 11)
            if let report = model.report {
                Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack {
                        Text("上次测速").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(report.date.formatted(date: .omitted, time: .shortened)).font(.system(size: 12))
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 12, weight: .semibold))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(expanded ? "收起上次测速" : "展开上次测速")
                if expanded {
                    if let chosen = report.results.first(where: { $0.name == report.selected && $0.valid }) {
                        HStack(spacing: 15) {
                            speed(chosen.download, symbol: "arrow.down", color: .blue)
                            Divider().frame(height: 19)
                            speed(chosen.upload, symbol: "arrow.up", color: .green)
                            Spacer(minLength: 0)
                        }.padding(.vertical, 10)
                    }
                    if report.results.isEmpty {
                        Text("上轮未完成测速，保留当前节点").font(.caption).foregroundStyle(.secondary).padding(.vertical, 13)
                    } else {
                        HStack {
                            Text("节点名称").frame(maxWidth: .infinity, alignment: .leading)
                            Text("下载 (MB/s)").frame(width: 84, alignment: .trailing)
                            Text("上传 (MB/s)").frame(width: 84, alignment: .trailing)
                        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.bottom, 6)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(report.results) { row in
                                    Divider()
                                    HStack(spacing: 7) {
                                        Image(systemName: row.name == report.selected ? "checkmark.circle.fill" : "circle.fill")
                                            .font(.system(size: row.name == report.selected ? 16 : 9)).foregroundStyle(row.name == report.selected ? Color.blue : Color.secondary.opacity(0.6)).frame(width: 18)
                                        Text(NodeLabel(row.name).title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(row.name)
                                        if let error = row.error {
                                            Text("未完成").foregroundStyle(.secondary).frame(width: 175, alignment: .trailing).help(error)
                                        } else {
                                            Text(String(format: "%.2f", row.download)).monospacedDigit().frame(width: 84, alignment: .trailing)
                                            Text(String(format: "%.2f", row.upload)).monospacedDigit().frame(width: 84, alignment: .trailing)
                                        }
                                    }.font(.system(size: 12)).padding(.vertical, 9)
                                }
                            }
                        }.frame(height: CGFloat(min(report.results.count, 3)) * 36)
                    }
                    Text("已测 \(report.testedCandidates) / \(report.totalCandidates) 个候选 · 自动轮换抽测")
                        .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 9)
                }
            } else {
                Text("尚无测速记录").font(.system(size: 14, weight: .semibold))
                Text("检查完成后显示双向速度与候选结果").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
            }
            Divider().padding(.top, 11).padding(.bottom, 10)
            Label("只切换 OneDrive，保留原有分流", systemImage: "checkmark.shield.fill")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 460).tint(.blue).background(Color(nsColor: .windowBackgroundColor))
    }
    private func speed(_ value: Double, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(String(format: "%.2f", value)).monospacedDigit()
            Text("MB/s").font(.system(size: 13, weight: .semibold))
        }.font(.system(size: 21, weight: .semibold))
    }
    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("设置与测速说明").font(.headline)
            Toggle("登录后启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            if !model.loginMessage.isEmpty { Text(model.loginMessage).font(.caption).foregroundStyle(.secondary) }
            Toggle("跟随 OneDrive 启动", isOn: Binding(get: { model.followOneDrive }, set: { model.setFollowOneDrive($0) }))
            Text("OneDrive 启动时自动打开选线 App").font(.caption).foregroundStyle(.secondary)
            if !model.followMessage.isEmpty { Text(model.followMessage).font(.caption).foregroundStyle(.red) }
            Divider()
            Text("空闲时测速；检测到其他应用传输便停止本轮，保留原节点。")
            Text("微软公开文件下载 + 临时数据上传。双向综合评分提升超过 20%，复测通过后切换。测速仅供选线参考。")
            Text("不读取或上传你的文件，不修改 Clash 模式、其他分流、DNS 或系统路由。")
            Divider()
            Button("退出 OneDrive 选线") { model.quit() }
        }.font(.system(size: 12)).padding(18).frame(width: 320)
    }
}

@MainActor final class StatusBarController: NSObject, NSApplicationDelegate {
    private let model = PilotModel()
    private var item: NSStatusItem!
    private let panel = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = CloudBoltIcon.image
            button.toolTip = "OneDrive 选线"
            button.setAccessibilityLabel("OneDrive 选线")
            button.target = self; button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        panel.behavior = .transient
        panel.contentViewController = NSHostingController(rootView: PilotView(model: model))
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            panel.performClose(nil)
            item.menu = makeMenu()
            item.button?.performClick(nil)
            item.menu = nil
        } else { togglePanel() }
    }

    @objc private func togglePanel() {
        if panel.isShown { panel.performClose(nil); return }
        guard let button = item.button else { return }
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        panel.contentViewController?.view.window?.makeKey()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector, enabled: Bool = true) -> NSMenuItem {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled; menu.addItem(entry); return entry
        }
        _ = add("打开面板", #selector(togglePanel))
        menu.addItem(.separator())
        _ = add("立即检查", #selector(scanNow), enabled: !model.running)
        if model.running { _ = add("停止本轮检查", #selector(stopScan)) }
        _ = add(model.automatic ? "暂停自动检查" : "恢复自动检查", #selector(toggleAutomatic))
        let intervals = NSMenu(); intervals.autoenablesItems = false
        for minutes in [15, 30, 60, 120] {
            let entry = NSMenuItem(title: "\(minutes) 分钟", action: #selector(setInterval(_:)), keyEquivalent: "")
            entry.target = self; entry.tag = minutes; entry.state = model.minutes == minutes ? .on : .off
            intervals.addItem(entry)
        }
        let interval = NSMenuItem(title: "检查间隔", action: nil, keyEquivalent: "")
        interval.submenu = intervals; menu.addItem(interval)
        let login = add("登录后启动", #selector(toggleLogin)); login.state = model.loginEnabled ? .on : .off
        let follow = add("跟随 OneDrive 启动", #selector(toggleFollow)); follow.state = model.followOneDrive ? .on : .off
        menu.addItem(.separator())
        _ = add("退出 OneDrive 选线", #selector(quit))
        return menu
    }
    @objc private func scanNow() { Task { await model.scan() } }
    @objc private func stopScan() { model.cancel() }
    @objc private func toggleAutomatic() {
        model.automatic.toggle()
        if !model.automatic && model.running { model.cancel() }
    }
    @objc private func setInterval(_ sender: NSMenuItem) { model.minutes = sender.tag }
    @objc private func toggleFollow() { model.setFollowOneDrive(!model.followOneDrive) }
    @objc private func toggleLogin() { model.setLogin(!model.loginEnabled) }
    @objc private func quit() { model.quit() }
}

@main struct OneDrivePilotApp: App {
    @NSApplicationDelegateAdaptor(StatusBarController.self) private var statusBar
    var body: some Scene { Settings { EmptyView() } }
}
