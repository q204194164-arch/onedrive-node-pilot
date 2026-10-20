import AppKit

// A small launchd helper observes application launches without probing the network.
let workspace = NSWorkspace.shared
let oneDriveIDs: Set<String> = ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"]
func openPilot() {
    let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let app = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    workspace.openApplication(at: app, configuration: configuration) { _, _ in }
}
let observer = workspace.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { notification in
    if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
       oneDriveIDs.contains(app.bundleIdentifier ?? "") { openPilot() }
}
if workspace.runningApplications.contains(where: { oneDriveIDs.contains($0.bundleIdentifier ?? "") }) { openPilot() }
RunLoop.main.run()
