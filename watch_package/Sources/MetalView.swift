import SwiftUI
import MetalKit

struct MetalView: WKInterfaceObjectRepresentable {
    var eyeWeight:   Float
    var mouthWeight: Float

    func makeWKInterfaceObject(context: Context) -> WKInterfaceObject {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.framebufferOnly = false
        view.preferredFramesPerSecond = 60
        return view as! WKInterfaceObject  // bridged in watchOS via WKInterfaceSCNScene fallback
    }

    func updateWKInterfaceObject(_ object: WKInterfaceObject, context: Context) {
        context.coordinator.eyeWeight   = eyeWeight
        context.coordinator.mouthWeight = mouthWeight
    }

    func makeCoordinator() -> Renderer { Renderer() }
}

class Renderer: NSObject, MTKViewDelegate {
    var eyeWeight:   Float = 0.0
    var mouthWeight: Float = 0.0

    private var device: MTLDevice!
    private var pipeline: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var texBase:   MTLTexture!
    private var texDeltaE: MTLTexture!
    private var texDeltaM: MTLTexture!

    override init() {
        super.init()
        device       = MTLCreateSystemDefaultDevice()!
        commandQueue = device.makeCommandQueue()!
        setupPipeline()
        loadTextures()
    }

    private func setupPipeline() {
        let lib = device.makeDefaultLibrary()!
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction   = lib.makeFunction(name: "vertexShader")
        desc.fragmentFunction = lib.makeFunction(name: "fragmentShader")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try! device.makeRenderPipelineState(descriptor: desc)
    }

    private func loadTextures() {
        let loader = MTKTextureLoader(device: device)
        let opts: [MTKTextureLoader.Option: Any] = [.SRGB: false]
        texBase   = try! loader.newTexture(name: "base",        scaleFactor: 1, bundle: nil, options: opts)
        texDeltaE = try! loader.newTexture(name: "delta_eye",   scaleFactor: 1, bundle: nil, options: opts)
        texDeltaM = try! loader.newTexture(name: "delta_mouth", scaleFactor: 1, bundle: nil, options: opts)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        let cmd = commandQueue.makeCommandBuffer()!
        let enc = cmd.makeRenderCommandEncoder(descriptor: descriptor)!
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texBase,   index: 0)
        enc.setFragmentTexture(texDeltaE, index: 1)
        enc.setFragmentTexture(texDeltaM, index: 2)
        var ew = eyeWeight, mw = mouthWeight
        enc.setFragmentBytes(&ew, length: 4, index: 0)
        enc.setFragmentBytes(&mw, length: 4, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }
}
