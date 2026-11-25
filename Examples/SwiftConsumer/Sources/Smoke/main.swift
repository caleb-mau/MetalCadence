import Foundation
import Metal
import QuartzCore
import MetalCadence

if #available(macOS 26.0, *) {
    let configuration = MCVideoConfiguration()
    configuration.inputWidth = 1280
    configuration.inputHeight = 720
    configuration.outputWidth = 1920
    configuration.outputHeight = 1080
    configuration.audioEnabled = false
    configuration.multiplier = 2
    configuration.presentation = .compare
    let layer = CAMetalLayer()
    layer.device = MTLCreateSystemDefaultDevice()
    let engine = try MCVideoEngine(configuration: configuration, layer: layer)
    try engine.start(withRefreshRate: 60)
    print("External Swift consumer started:", engine.running, engine.metrics())
    engine.stop()
} else {
    fatalError("Video engine requires macOS 26 or later")
}
