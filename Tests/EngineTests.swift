import Foundation

@main struct EngineTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); checks += 1 }
        let paths = IsolationGuard.paths
        let rules: [[String: Any]] = [
            ["type": "ProcessPath", "payload": paths[0], "proxy": IsolationGuard.group],
            ["type": "ProcessPath", "payload": paths[1], "proxy": IsolationGuard.group],
            ["type": "Match", "proxy": "Original"]]
        let proxies: [String: Any] = [IsolationGuard.group: ["type": "Selector", "now": "A", "all": ["A", "B"]], "GLOBAL": ["now": "Original"]]
        let valid = try IsolationGuard.validate(config: ["mode": "rule"], proxies: proxies, rules: rules)
        check(valid.current == "A", "valid isolation must pass")
        var original = rules
        original.insert(["type": "DomainSuffix", "payload": "qq.com", "proxy": "DIRECT"], at: 2)
        let restored = try IsolationGuard.validate(config: ["mode": "rule"], proxies: proxies, rules: original)
        check(restored.current == "A", "original routing rules must remain supported without an inserted catch-all")
        check(!IsolationGuard.unchanged(valid, restored), "changes to original rules must cancel switching")
        var statsOnly = rules; statsOnly[2]["extra"] = ["hitCount": 999, "disabled": false]
        let same = try IsolationGuard.validate(config: ["mode": "rule"], proxies: proxies, rules: statsOnly)
        check(IsolationGuard.unchanged(valid, same), "live counters must not cancel a safe scan")
        check((try? IsolationGuard.validate(config: ["mode": "global"], proxies: proxies, rules: rules)) == nil, "global mode must never switch")
        var wrong = rules; wrong[0]["payload"] = "/Applications/Other.app/run"
        check((try? IsolationGuard.validate(config: ["mode": "rule"], proxies: proxies, rules: wrong)) == nil, "wrong process must fail closed")
        wrong = rules; wrong[1]["extra"] = ["disabled": true]
        check((try? IsolationGuard.validate(config: ["mode": "rule"], proxies: proxies, rules: wrong)) == nil, "disabled rule must fail")
        wrong = rules; wrong[2]["proxy"] = IsolationGuard.group
        check((try? IsolationGuard.validate(config: ["mode": "rule"], proxies: proxies, rules: wrong)) == nil, "OneDrive fallback must never capture other applications")
        let current = NodeResult(name: "A", latency: 100, download: 1, upload: 1)
        var contender = NodeResult(name: "B", latency: 5, download: 1.15, upload: 1.15)
        check(IsolationGuard.winner([current, contender], current: "A")?.name == "A", "avoid jitter below 20 percent")
        contender.download = 2; contender.upload = 2
        check(IsolationGuard.winner([current, contender], current: "A")?.name == "B", "accept meaningful bidirectional improvement")
        contender.upload = 0.1; contender.download = 20
        check(IsolationGuard.winner([current, contender], current: "A")?.name == "A", "download cannot hide poor upload")
        contender.error = "timeout"
        check(IsolationGuard.winner([contender], current: "A") == nil, "failed test cannot win")
        check(NodeResult.balanced(download: .infinity, upload: 1) == 0, "invalid measurements cannot win")
        check(!ClashAPI.encoded("节点/测试 ?").contains("/"), "node name must remain one API path component")
        let control = ScanControl(); control.cancel()
        check((try? control.check()) == nil, "cancelled scan must not continue")
        let busy = ScanControl(); busy.pauseForTraffic()
        check((try? busy.check()) == nil, "other-app activity must abort switching")
        let started = Date()
        let (terminated, _) = try Command.run("/bin/sleep", ["4"], shouldStop: { true })
        check(terminated != 0 && Date().timeIntervalSince(started) < 3, "a live bandwidth test must stop promptly when another app becomes active")
        print("Passed \(checks) safety and selection checks")
    }
}
