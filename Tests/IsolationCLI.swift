import Foundation

@main struct IsolationCLI {
    static func main() throws {
        let api = try ClashAPI.discover(), engine = PilotEngine()
        let before = try engine.snapshot(api)
        guard let alternate = before.candidates.first(where: { $0 != before.current }) else { throw RouterError.message("No alternate node") }
        defer { try? api.select(group: IsolationGuard.group, node: before.current) }
        try api.select(group: IsolationGuard.group, node: alternate)
        let after = try engine.snapshot(api)
        precondition(after.current == alternate)
        precondition(after.global == before.global)
        precondition(after.settingsFingerprint == before.settingsFingerprint)
        precondition(after.rulesFingerprint == before.rulesFingerprint)
        precondition(after.otherSelectorsFingerprint == before.otherSelectorsFingerprint)
        try api.select(group: IsolationGuard.group, node: before.current)
        let restored = try engine.snapshot(api)
        precondition(restored.current == before.current)
        print("PASS: only OneDrive selector changed; mode, original rules, settings and other selectors unchanged; previous OneDrive node restored.")
    }
}
