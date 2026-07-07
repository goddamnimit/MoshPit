import Metal
import simd
import QuartzCore

// MARK: - Geometry generation (Trace grids + Mass primitives)

enum TracePrimitive: Int, CaseIterable {
    case plane = 0, cube, sphere, torus
    static let names = ["PLANE", "CUBE", "SPHERE", "TORUS"]
}

/// 32-byte interleaved vertex: position, normal, uv.
struct TraceVertex {
    var px: Float, py: Float, pz: Float
    var nx: Float, ny: Float, nz: Float
    var u: Float, v: Float
}

struct TraceGeometry {
    var vertices: [TraceVertex] = []
    var triIndices: [UInt32] = []
    var lineIndices: [UInt32] = []
}

/// Procedural primitives with full UVs so the canvas texture wraps them.
/// All are built from N x N parameter grids (cube: N x N per face), so the
/// point/wire/solid render modes apply uniformly to every primitive.
func makeTraceGeometry(primitive: TracePrimitive, resolution n: Int,
                       planeAspect: Float = 16.0 / 9.0) -> TraceGeometry {
    let N = max(2, n)
    var geo = TraceGeometry()

    func addGrid(point: (Float, Float) -> (SIMD3<Float>, SIMD3<Float>)) {
        let base = UInt32(geo.vertices.count)
        for row in 0..<N {
            for col in 0..<N {
                let u = Float(col) / Float(N - 1)
                let v = Float(row) / Float(N - 1)
                let (p, nrm) = point(u, v)
                geo.vertices.append(TraceVertex(px: p.x, py: p.y, pz: p.z,
                                                nx: nrm.x, ny: nrm.y, nz: nrm.z,
                                                u: u, v: v))
            }
        }
        for row in 0..<(N - 1) {
            for col in 0..<(N - 1) {
                let i = base + UInt32(row * N + col)
                let r = i + 1, d = i + UInt32(N), dr = d + 1
                geo.triIndices += [i, d, r, r, d, dr]
                geo.lineIndices += [i, r, i, d]           // grid wireframe
                if col == N - 2 { geo.lineIndices += [r, dr] }
                if row == N - 2 { geo.lineIndices += [d, dr] }
            }
        }
    }

    switch primitive {
    case .plane:
        // Camera-facing plane matching the canvas aspect (no stretch).
        let ax = planeAspect >= 1 ? planeAspect : 1
        let ay = planeAspect >= 1 ? 1 : 1 / planeAspect
        addGrid { u, v in
            (SIMD3((u - 0.5) * 2 * ax * 0.75, (0.5 - v) * 2 * ay * 0.75, 0),
             SIMD3(0, 0, 1))
        }
    case .cube:
        // 6 face grids, each wrapping the full texture.
        let faces: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, -1, 0)),   // +Z
            (SIMD3(0, 0, -1), SIMD3(-1, 0, 0), SIMD3(0, -1, 0)), // -Z
            (SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, -1, 0)),  // +X
            (SIMD3(-1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)),  // -X
            (SIMD3(0, 1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, 1)),    // +Y
            (SIMD3(0, -1, 0), SIMD3(1, 0, 0), SIMD3(0, 0, -1)),  // -Y
        ]
        for (normal, right, up) in faces {
            addGrid { u, v in
                (normal * 0.6 + right * (u - 0.5) * 1.2 + up * (0.5 - v) * 1.2, normal)
            }
        }
    case .sphere:
        addGrid { u, v in
            let theta = u * 2 * .pi, phi = v * .pi
            let p = SIMD3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
            return (p * 0.9, p)
        }
    case .torus:
        let R: Float = 0.7, r: Float = 0.32
        addGrid { u, v in
            let a = u * 2 * .pi, b = v * 2 * .pi
            let center = SIMD3(cos(a), 0, sin(a)) * R
            let nrm = SIMD3(cos(a) * cos(b), sin(b), sin(a) * cos(b))
            return (center + nrm * r, nrm)
        }
    }
    return geo
}

// MARK: - Matrices

func perspectiveMatrix(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
    let y = 1 / tan(fovY * 0.5)
    let x = y / aspect
    let z = far / (near - far)
    return float4x4(columns: (
        SIMD4(x, 0, 0, 0),
        SIMD4(0, y, 0, 0),
        SIMD4(0, 0, z, -1),
        SIMD4(0, 0, z * near, 0)))
}

func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
    let z = simd_normalize(eye - center)
    let x = simd_normalize(simd_cross(up, z))
    let y = simd_cross(z, x)
    return float4x4(columns: (
        SIMD4(x.x, y.x, z.x, 0),
        SIMD4(x.y, y.y, z.y, 0),
        SIMD4(x.z, y.z, z.z, 0),
        SIMD4(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)))
}

func rotationMatrix(x: Float, y: Float, z: Float) -> float4x4 {
    let cx = cos(x), sx = sin(x), cy = cos(y), sy = sin(y), cz = cos(z), sz = sin(z)
    let rx = float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cx, sx, 0),
                                SIMD4(0, -sx, cx, 0), SIMD4(0, 0, 0, 1)))
    let ry = float4x4(columns: (SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0),
                                SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1)))
    let rz = float4x4(columns: (SIMD4(cz, sz, 0, 0), SIMD4(-sz, cz, 0, 0),
                                SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1)))
    return rz * ry * rx
}

// MARK: - Trace renderer

struct TraceUniformsSwift {
    var mvp: float4x4
    var depthAmount: Float
    var pointSize: Float
    var alpha: Float
    var pad0: Float = 0
}

/// Owns the 3D pipelines, offscreen target, geometry cache, and camera state.
/// Renders the moshed canvas onto geometry; the result replaces the 2D frame
/// for preview AND consumers (what you see is what you record).
final class TraceRenderer {
    private let ctx: MetalContext
    private let params: ParameterStore

    private var pipeline: MTLRenderPipelineState?
    private var pipelineAdditive: MTLRenderPipelineState?
    private var fadePipeline: MTLRenderPipelineState?
    private var depthState: MTLDepthStencilState?
    private var depthStateNoWrite: MTLDepthStencilState?

    private var target: MTLTexture?
    private var depthTex: MTLTexture?
    private var vertexBuffer: MTLBuffer?
    private var triBuffer: MTLBuffer?
    private var lineBuffer: MTLBuffer?
    private var triCount = 0, lineCount = 0, vertCount = 0
    private var cachedKey: String = ""

    // Camera/spin accumulators (auto-rotate and spin advance render-side so
    // the user-facing orbit parameters stay where gestures/automation set them).
    private var autoAzimuth: Float = 0
    private var spin = SIMD3<Float>(repeating: 0)

    init(ctx: MetalContext, params: ParameterStore) {
        self.ctx = ctx
        self.params = params
        buildPipelines()
    }

    private func buildPipelines() {
        let lib = ctx.library
        let desc = MTLRenderPipelineDescriptor()
        desc.label = "trace"
        desc.vertexFunction = lib.makeFunction(name: "traceVertex")
        desc.fragmentFunction = lib.makeFunction(name: "traceFragment")
        desc.colorAttachments[0].pixelFormat = .rgba16Float
        desc.depthAttachmentPixelFormat = .depth32Float
        pipeline = try? ctx.device.makeRenderPipelineState(descriptor: desc)

        desc.label = "trace.additive"
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        pipelineAdditive = try? ctx.device.makeRenderPipelineState(descriptor: desc)

        let fade = MTLRenderPipelineDescriptor()
        fade.label = "trace.fade"
        fade.vertexFunction = lib.makeFunction(name: "traceFadeVertex")
        fade.fragmentFunction = lib.makeFunction(name: "traceFadeFragment")
        fade.colorAttachments[0].pixelFormat = .rgba16Float
        fade.depthAttachmentPixelFormat = .depth32Float
        fade.colorAttachments[0].isBlendingEnabled = true
        fade.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        fade.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        fadePipeline = try? ctx.device.makeRenderPipelineState(descriptor: fade)

        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        depthState = ctx.device.makeDepthStencilState(descriptor: d)
        d.isDepthWriteEnabled = false     // additive points shouldn't occlude
        depthStateNoWrite = ctx.device.makeDepthStencilState(descriptor: d)
    }

    private func ensureResources(width: Int, height: Int) {
        if target == nil || target!.width != width || target!.height != height {
            target = ctx.makeTexture(width: width, height: height,
                                     format: .rgba16Float,
                                     usage: [.shaderRead, .renderTarget],
                                     label: "trace.target")
            let dd = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .depth32Float, width: width, height: height, mipmapped: false)
            dd.usage = .renderTarget
            dd.storageMode = .private
            depthTex = ctx.device.makeTexture(descriptor: dd)
            depthTex?.label = "trace.depth"
        }
        let primitive = TracePrimitive(rawValue: Int(params.get(.tracePrimitive))) ?? .plane
        let res = kTraceGrids[max(0, min(kTraceGrids.count - 1, Int(params.get(.traceGrid))))]
        let aspect = Float(width) / Float(max(1, height))
        let key = "\(primitive.rawValue).\(res).\(Int(aspect * 100))"
        guard key != cachedKey else { return }
        cachedKey = key
        let geo = makeTraceGeometry(primitive: primitive, resolution: res,
                                    planeAspect: aspect)
        vertCount = geo.vertices.count
        triCount = geo.triIndices.count
        lineCount = geo.lineIndices.count
        vertexBuffer = ctx.device.makeBuffer(
            bytes: geo.vertices, length: geo.vertices.count * MemoryLayout<TraceVertex>.stride)
        triBuffer = ctx.device.makeBuffer(
            bytes: geo.triIndices, length: geo.triIndices.count * 4)
        lineBuffer = ctx.device.makeBuffer(
            bytes: geo.lineIndices, length: geo.lineIndices.count * 4)
        vertexBuffer?.label = "trace.verts.\(key)"
    }

    /// Render the canvas onto geometry. Returns the offscreen 3D frame.
    func encode(commandBuffer: MTLCommandBuffer, canvas: MTLTexture,
                dt: Float) -> MTLTexture? {
        // Viewport matches the canvas aspect (long edge bounded for
        // fill-rate sanity).
        let longEdge = min(max(canvas.width, canvas.height), 1280)
        let (w, h) = MoshEngine.canvasDimensions(longEdge: longEdge,
                                                 srcW: canvas.width,
                                                 srcH: canvas.height)
        ensureResources(width: w, height: h)
        guard let target, let depthTex, let pipeline, let pipelineAdditive,
              let fadePipeline, let vertexBuffer else { return nil }

        autoAzimuth += params.get(.traceAutoRotate) * dt
        spin += SIMD3(params.get(.traceSpinX), params.get(.traceSpinY),
                      params.get(.traceSpinZ)) * dt

        let trails = params.bool(.traceTrails)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = trails ? .load : .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        rpd.depthAttachment.texture = depthTex
        rpd.depthAttachment.loadAction = .clear
        rpd.depthAttachment.storeAction = .dontCare
        rpd.depthAttachment.clearDepth = 1

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.label = "trace3D"

        if trails {
            var fade: Float = 0.12
            enc.setRenderPipelineState(fadePipeline)
            enc.setDepthStencilState(depthStateNoWrite)
            enc.setFragmentBytes(&fade, length: 4, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // Camera: orbit around origin (azimuth = gesture/automation + auto).
        let az = params.get(.orbitAzimuth) + autoAzimuth
        let el = params.get(.orbitElevation)
        let dist = params.get(.orbitDistance)
        let eye = SIMD3(cos(el) * sin(az), sin(el), cos(el) * cos(az)) * dist
        let view = lookAtMatrix(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let proj = perspectiveMatrix(fovY: .pi / 3, aspect: Float(w) / Float(h),
                                     near: 0.05, far: 50)
        let model = rotationMatrix(x: spin.x, y: spin.y, z: spin.z)

        let mode = Int(params.get(.traceMode))
        let additive = params.bool(.traceAdditive) && mode == 0
        var u = TraceUniformsSwift(
            mvp: proj * view * model,
            depthAmount: params.get(.traceDepth),
            pointSize: params.get(.tracePointSize),
            alpha: additive ? 0.55 : 1.0)

        enc.setRenderPipelineState(additive ? pipelineAdditive : pipeline)
        enc.setDepthStencilState(additive ? depthStateNoWrite : depthState)
        enc.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        enc.setVertexBytes(&u, length: MemoryLayout<TraceUniformsSwift>.stride, index: 1)
        enc.setFragmentBytes(&u, length: MemoryLayout<TraceUniformsSwift>.stride, index: 1)
        enc.setVertexTexture(canvas, index: 0)
        enc.setFragmentTexture(canvas, index: 0)

        switch mode {
        case 1 where lineCount > 0:
            enc.drawIndexedPrimitives(type: .line, indexCount: lineCount,
                                      indexType: .uint32, indexBuffer: lineBuffer!,
                                      indexBufferOffset: 0)
        case 2 where triCount > 0:
            enc.drawIndexedPrimitives(type: .triangle, indexCount: triCount,
                                      indexType: .uint32, indexBuffer: triBuffer!,
                                      indexBufferOffset: 0)
        default:
            enc.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertCount)
        }
        enc.endEncoding()
        return target
    }
}
