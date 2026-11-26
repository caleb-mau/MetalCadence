import Cocoa
import CoreGraphics

let appID = CommandLine.arguments.dropFirst().first ?? "com.caleb.metalcadence.latencylab"
let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: appID)
    .map { Int($0.processIdentifier) })
guard !pids.isEmpty else {
    fputs("No MetalCadence process found for bundle ID: \(appID)\n", stderr)
    exit(2)
}
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
    as? [[String: Any]] ?? []
for window in windows {
    guard let pid = window[kCGWindowOwnerPID as String] as? Int,
          pids.contains(pid),
          let name = window[kCGWindowName as String] as? String,
          name.contains("Interactive Latency Lab"),
          let number = window[kCGWindowNumber as String] as? Int else {
        continue
    }
    print(number)
    exit(0)
}
fputs("MetalCadence preview window not found or not visible\n", stderr)
exit(3)
