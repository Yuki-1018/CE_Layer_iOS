import MetalKit

final class MetalDisplayView: MTKView, MTKViewDelegate {
    private var pipeline: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var texture: MTLTexture?
    private var contentAspectRatio: CGFloat = 4.0 / 3.0
    private let textureLock = NSLock()

    init() {
        let device = MTLCreateSystemDefaultDevice()!
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        // The controller's 60 Hz CADisplayLink supplies new emulator frames.
        // Render only when a new texture arrives instead of running a second,
        // competing MTKView timer that iOS may coalesce down to 30 Hz.
        enableSetNeedsDisplay = true
        isPaused = true
        preferredFramesPerSecond = 60
        presentsWithTransaction = false
        clearColor = MTLClearColorMake(0.02, 0.02, 0.02, 1)
        commandQueue = device.makeCommandQueue()

        let library = device.makeDefaultLibrary()!
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "fullscreenVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "displayFragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ frame: Win95VideoFrame) {
        guard frame.width > 0, frame.height > 0 else { return }
        textureLock.lock()
        if texture?.width != frame.width || texture?.height != frame.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            texture = device?.makeTexture(descriptor: descriptor)
        }
        frame.data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            texture?.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: frame.bytesPerRow
            )
        }
        contentAspectRatio = frame.aspectRatio > 0 ? CGFloat(frame.aspectRatio) : CGFloat(frame.width) / CGFloat(frame.height)
        textureLock.unlock()
        setNeedsDisplay()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let buffer = commandQueue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        textureLock.lock()
        let activeTexture = texture
        let activeAspectRatio = contentAspectRatio
        textureLock.unlock()
        encoder.setRenderPipelineState(pipeline)
        if let activeTexture {
            let drawableWidth = Double(view.drawableSize.width)
            let drawableHeight = Double(view.drawableSize.height)
            let drawableAspectRatio = drawableHeight > 0 ? drawableWidth / drawableHeight : 1
            let contentAspectRatio = max(0.01, Double(activeAspectRatio))
            let viewport: MTLViewport
            if drawableAspectRatio > contentAspectRatio {
                let width = drawableHeight * contentAspectRatio
                viewport = MTLViewport(
                    originX: (drawableWidth - width) / 2,
                    originY: 0,
                    width: width,
                    height: drawableHeight,
                    znear: 0,
                    zfar: 1
                )
            } else {
                let height = drawableWidth / contentAspectRatio
                viewport = MTLViewport(
                    originX: 0,
                    originY: (drawableHeight - height) / 2,
                    width: drawableWidth,
                    height: height,
                    znear: 0,
                    zfar: 1
                )
            }
            encoder.setViewport(viewport)
            encoder.setFragmentTexture(activeTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}
