import Foundation
import Metal
import QuartzCore
import CoreVideo

/// Zero-copy Metal rendering pipeline for IOSurface-backed NV12 `CVPixelBuffer` display on `CAMetalLayer`.
public final class MetalRenderPipeline: @unchecked Sendable {
    public let device: MTLDevice
    public let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var pipelineState: MTLRenderPipelineState?
    private var samplerState: MTLSamplerState?
    public weak var metalLayer: CAMetalLayer?
    private let renderLock = NSLock()
    private var frameCounter: UInt64 = 0

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut mirrorVertexShader(uint vid [[vertex_id]]) {
        const float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };
        const float2 texCoords[4] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 0.0)
        };
        VertexOut out;
        out.position = float4(positions[vid], 0.0, 1.0);
        out.texCoord = texCoords[vid];
        return out;
    }

    fragment float4 mirrorFragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> lumaTex [[texture(0)]],
        texture2d<float> chromaTex [[texture(1)]],
        sampler linearSampler [[sampler(0)]]
    ) {
        float y = lumaTex.sample(linearSampler, in.texCoord).r;
        float2 cbcr = chromaTex.sample(linearSampler, in.texCoord).rg;

        // BT.709 video-range YCbCr -> sRGB
        float yAdj = (y - (16.0 / 255.0)) * (255.0 / 219.0);
        float cb = (cbcr.r - 0.5) * (255.0 / 224.0);
        float cr = (cbcr.g - 0.5) * (255.0 / 224.0);

        float r = yAdj + 1.5748 * cr;
        float g = yAdj - 0.1873 * cb - 0.4681 * cr;
        float b = yAdj + 1.8556 * cb;
        return float4(clamp(float3(r, g, b), 0.0, 1.0), 1.0);
    }
    """

    public init?(metalLayer: CAMetalLayer) {
        guard let device = metalLayer.device ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.device = device
        self.commandQueue = queue
        self.metalLayer = metalLayer
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true

        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &cache
        )
        guard status == kCVReturnSuccess, let validCache = cache else {
            return nil
        }
        self.textureCache = validCache

        guard Self.buildPipeline(device: device, pipelineOut: &self.pipelineState, samplerOut: &self.samplerState) else {
            return nil
        }
    }

    private static func buildPipeline(
        device: MTLDevice,
        pipelineOut: inout MTLRenderPipelineState?,
        samplerOut: inout MTLSamplerState?
    ) -> Bool {
        guard let library = try? device.makeLibrary(source: shaderSource, options: nil),
              let vertFn = library.makeFunction(name: "mirrorVertexShader"),
              let fragFn = library.makeFunction(name: "mirrorFragmentShader") else {
            return false
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vertFn
        desc.fragmentFunction = fragFn
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm

        guard let state = try? device.makeRenderPipelineState(descriptor: desc) else {
            return false
        }
        pipelineOut = state

        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter = .linear
        samplerDesc.magFilter = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        samplerOut = device.makeSamplerState(descriptor: samplerDesc)
        return samplerOut != nil
    }

    /// Creates Metal textures directly mapped to the CVPixelBuffer's zero-copy IOSurface planes.
    public func createTextures(from pixelBuffer: CVPixelBuffer) -> (luma: MTLTexture, chroma: MTLTexture)? {
        guard let cache = textureCache else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var lumaTextureRef: CVMetalTexture?
        let lumaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .r8Unorm,
            width,
            height,
            0,
            &lumaTextureRef
        )

        var chromaTextureRef: CVMetalTexture?
        let chromaStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            cache,
            pixelBuffer,
            nil,
            .rg8Unorm,
            max(1, width / 2),
            max(1, height / 2),
            1,
            &chromaTextureRef
        )

        guard lumaStatus == kCVReturnSuccess,
              chromaStatus == kCVReturnSuccess,
              let lumaRef = lumaTextureRef,
              let chromaRef = chromaTextureRef,
              let lumaTex = CVMetalTextureGetTexture(lumaRef),
              let chromaTex = CVMetalTextureGetTexture(chromaRef) else {
            return nil
        }

        return (luma: lumaTex, chroma: chromaTex)
    }

    /// Renders a decoded `CVPixelBuffer` onto the configured `CAMetalLayer` using zero-copy GPU textures.
    @discardableResult
    public func render(pixelBuffer: CVPixelBuffer) -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }

        guard let layer = metalLayer,
              let pipelineState = pipelineState,
              let samplerState = samplerState else {
            return false
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if width > 0 && height > 0 {
            let targetSize = CGSize(width: width, height: height)
            if layer.drawableSize != targetSize {
                layer.drawableSize = targetSize
            }
        }

        guard let textures = createTextures(from: pixelBuffer),
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else {
            return false
        }

        let passDesc = MTLRenderPassDescriptor()
        passDesc.colorAttachments[0].texture = drawable.texture
        passDesc.colorAttachments[0].loadAction = .clear
        passDesc.colorAttachments[0].storeAction = .store
        passDesc.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDesc) else {
            return false
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(textures.luma, index: 0)
        encoder.setFragmentTexture(textures.chroma, index: 1)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()

        frameCounter &+= 1
        if frameCounter % 30 == 0 {
            flushTextureCache()
        }
        return true
    }

    /// Flushes texture cache periodically to prevent stale IOSurface handles.
    public func flushTextureCache() {
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
        }
    }
}
