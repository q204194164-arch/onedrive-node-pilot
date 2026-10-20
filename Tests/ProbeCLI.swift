import Foundation

@main struct ProbeCLI {
    static func main() async {
        let engine = PilotEngine()
        do {
            let report = try await engine.scan(rotation: 0, control: ScanControl(), progress: { print($0) }, apply: false, candidateLimit: 3)
            let data = try JSONEncoder().encode(report)
            print(String(decoding: data, as: UTF8.self))
        } catch { fputs("Probe failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }
}
