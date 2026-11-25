import CoreGraphics
import Foundation
let id = CGMainDisplayID()
let modes = CGDisplayCopyAllDisplayModes(id, nil) as? [CGDisplayMode] ?? []
let current = CGDisplayCopyDisplayMode(id)!
print("current",current.width,current.height,current.pixelWidth,current.refreshRate)
for m in modes where m.width == current.width && m.height == current.height { print(m.width,m.height,m.pixelWidth,m.refreshRate,m.ioDisplayModeID) }
let requested: Double? = CommandLine.arguments.contains("--120") ? 120 : CommandLine.arguments.contains("--165") ? 165 : nil
if let hz=requested, let mode = modes.first(where: { $0.width == current.width && $0.height == current.height && $0.pixelWidth == current.pixelWidth && abs($0.refreshRate-hz)<0.5 }) {
 var config: CGDisplayConfigRef?
 let begin = CGBeginDisplayConfiguration(&config)
 if begin == .success, let config = config {
  let set=CGConfigureDisplayWithDisplayMode(config,id,mode,nil)
  if set == .success { print("complete",CGCompleteDisplayConfiguration(config,.forSession).rawValue) } else { CGCancelDisplayConfiguration(config); print("configure failed",set.rawValue) }
 }
 print("current", CGDisplayCopyDisplayMode(id)!.refreshRate)
}
