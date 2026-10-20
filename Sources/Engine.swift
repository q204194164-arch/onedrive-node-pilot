import Foundation
import SystemConfiguration
import Security
import CryptoKit
import Darwin

enum RouterError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
}

enum Command {
    static func run(_ executable: String, _ arguments: [String], input: Data? = nil, shouldStop: (() -> Bool)? = nil) throws -> (Int32, Data) {
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: executable); p.arguments = arguments
        p.standardOutput = output; p.standardError = output
        var writer: Pipe?
        if input != nil { let pipe = Pipe(); p.standardInput = pipe; writer = pipe }
        try p.run()
        var monitor: DispatchSourceTimer?
        let monitorQueue = DispatchQueue(label: "OneDrivePilot.traffic-watch")
        if let shouldStop {
            let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { if p.isRunning && shouldStop() && p.isRunning { kill(p.processIdentifier, SIGTERM) } }
            timer.resume(); monitor = timer
        }
        defer { if monitor != nil { monitor?.cancel(); monitorQueue.sync {} } }
        if let input { try writer?.fileHandleForWriting.write(contentsOf: input); try writer?.fileHandleForWriting.close() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, data)
    }
}

struct ClashAPI: Sendable {
    let socket: String
    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: Int = 10) throws -> [String: Any] {
        var args = ["-sS", "--max-time", "\(timeout)", "--unix-socket", socket, "-X", method,
                    "-H", "Content-Type: application/json", "-w", "\n%{http_code}", "http://localhost/" + path]
        var data: Data?
        if let body { data = try JSONSerialization.data(withJSONObject: body); args += ["--data-binary", "@-"] }
        let (status, raw) = try Command.run("/usr/bin/curl", args, input: data)
        let text = String(decoding: raw, as: UTF8.self)
        guard let split = text.lastIndex(of: "\n"), status == 0,
              let code = Int(text[text.index(after: split)...]), (200..<300).contains(code) else {
            throw RouterError.message("无法连接 Clash：请确认 Clash Verge 正在运行。")
        }
        let bodyData = Data(text[..<split].utf8)
        if bodyData.isEmpty { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
            throw RouterError.message("Clash 返回了无法识别的数据。")
        }
        return object
    }
    static func encoded(_ name: String) -> String {
        name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
    func select(group: String, node: String) throws {
        _ = try request("proxies/" + Self.encoded(group), method: "PUT", body: ["name": node])
    }
    static func discover() throws -> ClashAPI {
        let uid = getuid()
        let paths = ["/var/run/clash-verge-service/users/\(uid)/verge-mihomo.sock",
                     NSTemporaryDirectory() + "verge-mihomo.sock"]
        for path in paths where FileManager.default.fileExists(atPath: path) {
            let api = ClashAPI(socket: path)
            if (try? api.request("version")) != nil { return api }
        }
        throw RouterError.message("未找到 Clash Verge 控制接口，请先启动 Clash Verge。")
    }
}

struct NodeResult: Codable, Identifiable, Sendable {
    var name: String
    var latency: Int?
    var download: Double = 0
    var upload: Double = 0
    var error: String?
    var id: String { name }
    var score: Double { Self.balanced(download: download, upload: upload) }
    var valid: Bool { error == nil && latency != nil && score > 0 }
    static func balanced(download: Double, upload: Double) -> Double {
        guard download.isFinite, upload.isFinite, download > 0, upload > 0 else { return 0 }
        return 2 / (1 / download + 1 / upload)
    }
}

struct ScanReport: Codable, Sendable {
    var date = Date()
    var previous: String
    var selected: String
    var switched: Bool
    var results: [NodeResult]
    var testedCandidates: Int
    var totalCandidates: Int
    var message: String
}

struct IsolationSnapshot: Sendable {
    let current: String
    let candidates: [String]
    let global: String
    let rulesFingerprint: String
    let settingsFingerprint: String
    let otherSelectorsFingerprint: String
}

enum IsolationGuard {
    static let group = "OneDrive 独立线路"
    static let paths = ["/Applications/OneDrive.app/Contents/MacOS/OneDrive",
                        "/Applications/OneDrive.app/Contents/PlugIns/OneDrive File Provider.appex/Contents/MacOS/OneDrive File Provider"]
    static func validate(config: [String: Any], proxies: [String: Any], rules: [[String: Any]]) throws -> IsolationSnapshot {
        guard config["mode"] as? String == "rule",
              let group = proxies[Self.group] as? [String: Any], group["type"] as? String == "Selector",
              let current = group["now"] as? String, let candidates = group["all"] as? [String], !candidates.isEmpty,
              let global = (proxies["GLOBAL"] as? [String: Any])?["now"] as? String,
              rules.count >= 3 else { throw RouterError.message("OneDrive 独立分流未就绪。为保护其他软件，本轮不切换。") }
        for (index, path) in paths.enumerated() {
            let rule = rules[index]
            guard rule["type"] as? String == "ProcessPath", rule["payload"] as? String == path,
                  rule["proxy"] as? String == Self.group,
                  (rule["extra"] as? [String: Any])?["disabled"] as? Bool != true else {
                throw RouterError.message("OneDrive 进程隔离规则已变化，本轮不切换。")
            }
        }
        let remaining = Array(rules.dropFirst(2))
        guard !remaining.contains(where: { $0["proxy"] as? String == Self.group }) else {
            throw RouterError.message("其他流量引用了 OneDrive 专用组，本轮不切换。")
        }
        for (name, value) in proxies where name != Self.group && name != "GLOBAL" {
            if let choices = (value as? [String: Any])?["all"] as? [String], choices.contains(Self.group) {
                throw RouterError.message("其他策略组引用了 OneDrive 专用组，本轮不切换。")
            }
        }
        let stableRules = remaining.map { r -> [String: Any] in
            ["type": r["type"] ?? "", "payload": r["payload"] ?? "", "proxy": r["proxy"] ?? "",
             "disabled": (r["extra"] as? [String: Any])?["disabled"] ?? false]
        }
        var selectors: [String: String] = [:]
        for (name, value) in proxies where name != Self.group {
            if let g = value as? [String: Any], g["type"] as? String == "Selector", let node = g["now"] as? String {
                selectors[name] = node
            }
        }
        return IsolationSnapshot(current: current, candidates: candidates, global: global,
            rulesFingerprint: try fingerprint(stableRules), settingsFingerprint: try fingerprint(config),
            otherSelectorsFingerprint: try fingerprint(selectors))
    }
    private static func fingerprint(_ value: Any) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }
    static func unchanged(_ a: IsolationSnapshot, _ b: IsolationSnapshot) -> Bool {
        a.global == b.global && a.rulesFingerprint == b.rulesFingerprint && a.settingsFingerprint == b.settingsFingerprint &&
        a.otherSelectorsFingerprint == b.otherSelectorsFingerprint && a.current == b.current && a.candidates == b.candidates
    }
    static func winner(_ results: [NodeResult], current: String) -> NodeResult? {
        let valid = results.filter(\.valid)
        guard let best = valid.max(by: { $0.score < $1.score }) else { return nil }
        if let old = valid.first(where: { $0.name == current }), old.score * 1.2 >= best.score { return old }
        return best
    }
}

final class ScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var reason: String?
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    func pauseForTraffic() { lock.lock(); stopped = true; reason = "其他应用正在传输，已暂停测速；保留原节点，稍后再检查。"; lock.unlock() }
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func check() throws {
        lock.lock(); let stop = stopped, message = reason; lock.unlock()
        if let message { throw RouterError.message(message) }; if stop { throw CancellationError() }
    }
}

final class OtherTrafficWatch: @unchecked Sendable {
    private let api: ClashAPI
    private let control: ScanControl
    private let lock = NSLock()
    private var previous: [String: Int64] = [:]
    private var date = Date()
    init(api: ClashAPI, control: ScanControl) throws {
        self.api = api; self.control = control; previous = try counters()
    }
    private func counters() throws -> [String: Int64] {
        guard let rows = try api.request("connections", timeout: 3)["connections"] as? [[String: Any]] else {
            throw RouterError.message("无法核对其他应用流量，暂停测速。")
        }
        var result: [String: Int64] = [:]
        for x in rows {
            let path = (x["metadata"] as? [String: Any])?["processPath"] as? String ?? ""
            if !path.contains("/OneDrive.app/"), let id = x["id"] as? String {
                result[id] = (x["upload"] as? Int64 ?? 0) + (x["download"] as? Int64 ?? 0)
            }
        }
        return result
    }
    func shouldStop() -> Bool {
        if control.cancelled { return true }
        lock.lock(); defer { lock.unlock() }
        do {
            let now = Date(), current = try counters(), elapsed = max(1, now.timeIntervalSince(date))
            let delta = current.reduce(Int64(0)) { $0 + max(0, $1.value - (previous[$1.key] ?? 0)) }
            previous = current; date = now
            if Double(delta) / elapsed > 32_768 { control.pauseForTraffic(); return true }
        } catch { control.pauseForTraffic(); return true }
        return false
    }
}

final class ProbeHelper: @unchecked Sendable {
    let directory: URL
    let api: ClashAPI
    let port: UInt16
    private let process: Process
    private let log: FileHandle
    private let lock = NSLock()
    private var cleaned = false
    static let group = "OneDrive Probe"
    static let downloadURL = "https://oneclient.sfx.ms/Mac/Installers/25.206.1021.0003/universal/OneDrive.pkg"
    static let uploadURL = "https://speed.cloudflare.com/__up"

    init(source: [String: Any], candidates: [String]) throws {
        let fm = FileManager.default
        directory = URL(fileURLWithPath: "/private/tmp/odp-\(getuid())-\(UUID().uuidString.prefix(12))")
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        api = ClashAPI(socket: directory.appendingPathComponent("api.sock").path)
        // Unix-domain paths have a small fixed limit on macOS.
        if api.socket.utf8.count >= 104 { try? fm.removeItem(at: directory); throw RouterError.message("测速临时路径过长。") }
        port = try Self.freePort()
        let interface = try Self.physicalInterface()
        var groups = source["proxy-groups"] as? [[String: Any]] ?? []
        groups.removeAll { $0["name"] as? String == Self.group }
        groups.append(["name": Self.group, "type": "select", "proxies": candidates])
        let config: [String: Any] = ["mode": "rule", "mixed-port": Int(port), "allow-lan": false,
            "bind-address": "127.0.0.1", "log-level": "warning", "ipv6": true, "interface-name": interface,
            "external-controller-unix": api.socket, "proxies": source["proxies"] ?? [], "proxy-groups": groups,
            "rules": ["MATCH," + Self.group], "tun": ["enable": false], "find-process-mode": "off",
            "dns": ["enable": true, "enhanced-mode": "normal", "default-nameserver": ["223.5.5.5", "119.29.29.29"],
                    "nameserver": ["https://dns.alidns.com/dns-query", "https://doh.pub/dns-query"]]]
        let configURL = directory.appendingPathComponent("config.json")
        try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]).write(to: configURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        let uploadURL = directory.appendingPathComponent("upload.bin")
        // Synthetic bytes only; never read a file from the user's OneDrive.
        var bytes = [UInt8](repeating: 0, count: 1_048_576)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            try? fm.removeItem(at: directory); throw RouterError.message("无法生成临时测速数据。")
        }
        try Data(bytes).write(to: uploadURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: uploadURL.path)
        let logURL = directory.appendingPathComponent("helper.log")
        fm.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        log = try FileHandle(forWritingTo: logURL)
        process = Process(); process.executableURL = URL(fileURLWithPath: "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo")
        process.arguments = ["-d", directory.path, "-f", configURL.path]; process.standardOutput = log; process.standardError = log
        do { try process.run() } catch { try? log.close(); try? fm.removeItem(at: directory); throw error }
    }
    func waitUntilReady(control: ScanControl) async throws {
        for _ in 0..<60 {
            try control.check()
            if !process.isRunning {
                let diagnostic = (try? String(contentsOf: directory.appendingPathComponent("helper.log"), encoding: .utf8)) ?? ""
                throw RouterError.message("独立测速进程启动失败：" + String(diagnostic.suffix(1200)))
            }
            if FileManager.default.fileExists(atPath: api.socket), (try? api.request("version", timeout: 2)) != nil { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw RouterError.message("独立测速进程启动超时。")
    }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        if cleaned { return }; cleaned = true
        if process.isRunning {
            process.terminate()
            for _ in 0..<20 { if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.05) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        try? log.close(); try? FileManager.default.removeItem(at: directory)
    }
    deinit { stop() }
    func latency(_ name: String) -> Int? {
        let query = "proxies/" + ClashAPI.encoded(name) + "/delay?timeout=4000&url=" + ClashAPI.encoded("https://api.onedrive.com/v1.0/drive")
        return (try? api.request(query, timeout: 6))?["delay"] as? Int
    }
    func throughput(_ name: String, latency: Int?, control: ScanControl, shouldStop: (() -> Bool)? = nil) throws -> NodeResult {
        try control.check(); try api.select(group: Self.group, node: name)
        var result = NodeResult(name: name, latency: latency)
        let common = ["-sS", "--proxy", "http://127.0.0.1:\(port)", "--noproxy", "", "--connect-timeout", "5",
                      "--max-time", "12", "-o", "/dev/null", "-w", "%{json}"]
        do {
            let (exit, data) = try Command.run("/usr/bin/curl", common + ["--range", "0-2097151", "--max-filesize", "3145728", Self.downloadURL], shouldStop: shouldStop)
            guard exit == 0, let d = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (d["http_code"] as? Int) == 206, (d["size_download"] as? Double) == 2_097_152,
                  let speed = d["speed_download"] as? Double, speed > 0 else { throw RouterError.message("微软下载测速未完成") }
            result.download = speed / 1_000_000
            try control.check()
            let (upExit, upData) = try Command.run("/usr/bin/curl", common + ["--max-filesize", "65536", "-H", "Expect:",
                "--data-binary", "@" + directory.appendingPathComponent("upload.bin").path, Self.uploadURL], shouldStop: shouldStop)
            guard upExit == 0, let u = try JSONSerialization.jsonObject(with: upData) as? [String: Any],
                  let status = u["http_code"] as? Int, (200..<300).contains(status),
                  (u["size_upload"] as? Double) == 1_048_576,
                  let speedUp = u["speed_upload"] as? Double, speedUp > 0 else { throw RouterError.message("上传带宽测速未完成") }
            result.upload = speedUp / 1_000_000
        } catch is CancellationError { throw CancellationError() }
        catch { result.error = error.localizedDescription }
        return result
    }
    private static func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RouterError.message("无法创建测速端口。") }; defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw RouterError.message("无法分配本机测速端口。") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        return UInt16(bigEndian: addr.sin_port)
    }
    private static func physicalInterface() throws -> String {
        if let state = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
           let name = state["PrimaryInterface"] as? String, name.hasPrefix("en") { return name }
        let (code, data) = try Command.run("/sbin/route", ["-n", "get", "default"])
        if code == 0, let line = String(decoding: data, as: UTF8.self).split(separator: "\n").first(where: { $0.contains("interface:") }),
           let name = line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), name.hasPrefix("en") { return name }
        throw RouterError.message("未找到物理网卡。为避免测速借道其他代理，本轮暂停。")
    }
}

final class PilotEngine: @unchecked Sendable {
    private let helperLock = NSLock()
    private var activeHelper: ProbeHelper?
    func stopHelper() { helperLock.lock(); let h = activeHelper; helperLock.unlock(); h?.stop() }
    private func setHelper(_ h: ProbeHelper?) { helperLock.lock(); activeHelper = h; helperLock.unlock() }
    static let configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/io.github.clash-verge-rev.clash-verge-rev")
    func snapshot(_ api: ClashAPI) throws -> IsolationSnapshot {
        let c = try api.request("configs"), p = try api.request("proxies")
        guard let proxies = p["proxies"] as? [String: Any], let rules = try api.request("rules")["rules"] as? [[String: Any]] else {
            throw RouterError.message("无法读取 OneDrive 分流配置。")
        }
        return try IsolationGuard.validate(config: c, proxies: proxies, rules: rules)
    }
    func scan(rotation: Int, control: ScanControl, progress: @escaping @Sendable (String) -> Void,
              connected: @escaping @Sendable (String) -> Void = { _ in }, apply: Bool = true, candidateLimit: Int? = nil) async throws -> ScanReport {
        let mainAPI = try ClashAPI.discover(), initial = try snapshot(mainAPI)
        connected(initial.current)
        let traffic = try OtherTrafficWatch(api: mainAPI, control: control)
        progress("等待网络空闲，优先保留其他应用带宽…")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        if traffic.shouldStop() { try control.check() }
        let (_, sourceData) = try Command.run("/usr/bin/ruby", ["-r", "yaml", "-r", "json", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", Self.configDirectory.appendingPathComponent("clash-verge.yaml").path])
        guard let source = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any],
              let proxies = source["proxies"] as? [[String: Any]] else { throw RouterError.message("无法读取当前订阅节点。") }
        let concrete = Set(proxies.compactMap { p -> String? in
            guard let name = p["name"] as? String, p["server"] as? String != nil,
                  !["剩余流量", "套餐到期", "距离下次"].contains(where: { name.contains($0) }) else { return nil }; return name
        })
        var candidates = initial.candidates.filter { concrete.contains($0) }
        if let limit = candidateLimit { candidates = Array(([initial.current] + candidates.filter { $0 != initial.current }).prefix(limit)) }
        guard !candidates.isEmpty else { throw RouterError.message("专用线路没有可测速的候选节点。") }
        let helper = try ProbeHelper(source: source, candidates: candidates); setHelper(helper)
        defer { helper.stop(); setHelper(nil) }
        try await helper.waitUntilReady(control: control)
        var delays: [(String, Int)] = []
        // Small batches avoid flooding the network with simultaneous handshakes.
        for offset in stride(from: 0, to: candidates.count, by: 3) {
            try control.check(); progress("检查连接 \(min(offset + 3, candidates.count))/\(candidates.count)…")
            let batch = Array(candidates[offset..<min(offset + 3, candidates.count)])
            let part = await withTaskGroup(of: (String, Int?).self, returning: [(String, Int?)].self) { group in
                for node in batch { group.addTask { (node, helper.latency(node)) } }
                var values: [(String, Int?)] = []; for await value in group { values.append(value) }; return values
            }
            delays += part.compactMap { node, delay in delay.map { (node, $0) } }
        }
        delays.sort { $0.1 < $1.1 }; try control.check()
        guard !delays.isEmpty else { throw RouterError.message("本轮没有节点通过 OneDrive 连接检查，保留原线路。") }
        var shortlist = Array(delays.prefix(3).map(\.0))
        if !shortlist.contains(initial.current) { shortlist.append(initial.current) }
        let remaining = delays.map(\.0).filter { !shortlist.contains($0) }
        if !remaining.isEmpty {
            for i in 0..<min(2, remaining.count) { shortlist.append(remaining[(rotation * 2 + i) % remaining.count]) }
        }
        let delayMap = Dictionary(uniqueKeysWithValues: delays)
        var results: [NodeResult] = []
        for (index, name) in shortlist.enumerated() {
            try control.check(); progress("双向测速 \(index + 1)/\(shortlist.count)：\(name)")
            if traffic.shouldStop() { try control.check() }
            results.append(try helper.throughput(name, latency: delayMap[name], control: control, shouldStop: traffic.shouldStop))
        }
        try control.check()
        guard var winner = IsolationGuard.winner(results, current: initial.current) else { throw RouterError.message("双向测速均未完成，保留原线路。") }
        // Confirm an apparent improvement once more before changing a working connection.
        if winner.name != initial.current {
            progress("复测候选线路，确认稳定性…")
            let check = try helper.throughput(winner.name, latency: winner.latency, control: control, shouldStop: traffic.shouldStop)
            if check.valid {
                if let i = results.firstIndex(where: { $0.name == winner.name }) {
                    results[i].download = min(results[i].download, check.download)
                    results[i].upload = min(results[i].upload, check.upload)
                }
                // Do not switch to a different, unconfirmed runner-up after a noisy retest.
                let confirmedName = winner.name
                let confirmedDecision = results.filter { $0.name == initial.current || $0.name == confirmedName }
                winner = IsolationGuard.winner(confirmedDecision, current: initial.current) ?? winner
            } else { throw RouterError.message("候选节点复测失败，保留当前线路。") }
        }
        let fresh = try snapshot(mainAPI)
        guard IsolationGuard.unchanged(initial, fresh) else { throw RouterError.message("测速期间线路设置发生变化，已取消本次自动切换。") }
        try control.check()
        var switched = false, message = "当前线路表现接近最佳，继续使用。"
        if apply && winner.name != initial.current {
            // The only selector this application is allowed to mutate.
            try mainAPI.select(group: IsolationGuard.group, node: winner.name)
            let after = try snapshot(mainAPI)
            guard after.current == winner.name, after.global == initial.global,
                  after.rulesFingerprint == initial.rulesFingerprint, after.settingsFingerprint == initial.settingsFingerprint,
                  after.otherSelectorsFingerprint == initial.otherSelectorsFingerprint else {
                try? mainAPI.select(group: IsolationGuard.group, node: initial.current)
                throw RouterError.message("切换验证未通过，已尝试恢复 OneDrive 原线路。")
            }
            switched = true; message = "已切换到双向表现更好的节点；正在传输的连接继续完成。"
        } else if !apply { message = "测试模式：仅测速，未切换线路。" }
        return ScanReport(previous: initial.current, selected: switched ? winner.name : initial.current,
                          switched: switched, results: results.sorted { $0.score > $1.score }, testedCandidates: results.count,
                          totalCandidates: candidates.count, message: message)
    }
}
