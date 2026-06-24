import SwiftUI
import MetalKit

/// Renders the album-art domain-warp background using the Metal shader in
/// KaraokeBackgroundShader.metal — the native equivalent of the real
/// extension's Kawarp (WebGL Kawase blur + simplex domain warp).
///
/// Returns nil from init if Metal setup fails for any reason (e.g.
/// simulator without Metal support, shader compile issue) — callers
/// should fall back to the placeholder gradient rather than crash.
final class KaraokeBackgroundRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var albumTexture: MTLTexture?
    private let startTime = CACurrentMediaTime()

    var warpIntensity: Float = 0.8

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        // Theos has no built-in Metal shader compilation step (unlike an
        // Xcode app target's build phases), so the Makefile compiles
        // KaraokeBackgroundShader.metal by hand into a .metallib staged
        // at this fixed path alongside the tweak's own dylib, rather than
        // relying on device.makeDefaultLibrary(bundle:) — which expects
        // Xcode's automatic shader embedding and would not find a
        // manually-built .metallib here. UNTESTED end-to-end: the
        // Makefile step that produces this file could not be verified
        // (no Theos/Metal toolchain available), so if this path doesn't
        // exist or doesn't load, check the Makefile's internal-stage
        // Metal compile step first.
        let metallibPath = "/Library/MobileSubstrate/DynamicLibraries/KaraokeBackgroundShader.metallib"
        guard let library = try? device.makeLibrary(filepath: metallibPath),
              let vertexFn = library.makeFunction(name: "karaoke_bg_vertex"),
              let fragmentFn = library.makeFunction(name: "karaoke_bg_fragment") else {
            writeDebugLog("[Karaoke] Metal shader library not found at \(metallibPath) — falling back to placeholder background")
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFn
        descriptor.fragmentFunction = fragmentFn
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            writeDebugLog("[Karaoke] Metal pipeline state creation failed — falling back to placeholder background")
            return nil
        }
        self.pipelineState = pipeline
        super.init()
    }

    func setAlbumArt(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        let loader = MTKTextureLoader(device: device)
        albumTexture = try? loader.newTexture(cgImage: cgImage, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
        ])
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let albumTexture = albumTexture,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        var params = KaraokeBgParamsMirror(
            time: Float(CACurrentMediaTime() - startTime),
            warpIntensity: warpIntensity,
            blurRadius: 0.012
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(albumTexture, index: 0)
        encoder.setFragmentBytes(&params, length: MemoryLayout<KaraokeBgParamsMirror>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// Mirrors the Metal shader's KaraokeBgParams struct layout exactly — field
/// order and types must match the .metal file's struct for setFragmentBytes
/// to interpret the raw bytes correctly.
private struct KaraokeBgParamsMirror {
    var time: Float
    var warpIntensity: Float
    var blurRadius: Float
}

/// SwiftUI wrapper around the MTKView + renderer.
struct KaraokeMetalBackgroundView: UIViewRepresentable {
    let albumArt: UIImage

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.preferredFramesPerSecond = 30 // matches the lyrics TimelineView's rate; no need to run faster
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        guard let device = MTLCreateSystemDefaultDevice() else {
            writeDebugLog("[Karaoke] Metal not available on this device — placeholder gradient should be used instead")
            return view
        }
        view.device = device

        if let renderer = KaraokeBackgroundRenderer(device: device) {
            renderer.setAlbumArt(albumArt)
            view.delegate = renderer
            context.coordinator.renderer = renderer
        }
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.renderer?.setAlbumArt(albumArt)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var renderer: KaraokeBackgroundRenderer?
    }
}
