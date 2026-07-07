import Metal
import MetalKit

/// Shared Metal objects + pipeline cache. All pipelines are built once at
/// startup; the render loop never creates GPU objects.
final class MetalContext {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    private(set) var pipelines: [String: MTLComputePipelineState] = [:]
    let previewPipeline: MTLRenderPipelineState

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        self.device = device
        self.queue = queue
        self.library = library
        queue.label = "moshpit.queue"

        for name in ["blockMatch", "moshCanvas", "resetCanvas", "motionStats",
                     "echoEffect", "echoStore", "slitscanEffect", "weaverEffect",
                     "pixelSortEffect", "procAmpEffect", "blitScale",
                     "struktPass", "mixWipe", "finisherPass", "watermarkBlit"] {
            guard let fn = library.makeFunction(name: name),
                  let ps = try? device.makeComputePipelineState(function: fn) else { return nil }
            pipelines[name] = ps
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.label = "preview"
        desc.vertexFunction = library.makeFunction(name: "previewVertex")
        desc.fragmentFunction = library.makeFunction(name: "previewFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pp = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        previewPipeline = pp
    }

    func pipeline(_ name: String) -> MTLComputePipelineState { pipelines[name]! }

    /// Dispatch helper covering a texture with 16x16 threadgroups.
    func dispatch(_ encoder: MTLComputeCommandEncoder, _ name: String,
                  width: Int, height: Int) {
        let ps = pipeline(name)
        encoder.setComputePipelineState(ps)
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(width: (width + 15) / 16, height: (height + 15) / 16, depth: 1)
        encoder.dispatchThreadgroups(grid, threadsPerThreadgroup: tg)
    }

    func makeTexture(width: Int, height: Int, format: MTLPixelFormat,
                     usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
                     label: String) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = usage
        d.storageMode = .private
        let t = device.makeTexture(descriptor: d)
        t?.label = label
        return t
    }
}
