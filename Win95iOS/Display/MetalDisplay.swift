import MetalKit

final class MetalDisplayView: MTKView, MTKViewDelegate {
    private struct TextureSlot {
        var texture: MTLTexture?
        var aspectRatio: CGFloat = 4.0 / 3.0
        var inFlight = false
    }

    private var pipeline: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var textureSlots = Array(repeating: TextureSlot(), count: 3)
    private var pendingSlot: Int?
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
        // A texture must not be changed with replace() while a command buffer
        // is still sampling it. Reuse an unsubmitted pending slot, otherwise
        // take a texture whose previous GPU command has completed.
        guard let slotIndex = pendingSlot ?? textureSlots.indices.first(where: { !textureSlots[$0].inFlight }) else {
            textureLock.unlock()
            return // GPU is behind; dropping one emulator frame is preferable to corrupting it.
        }
        if textureSlots[slotIndex].texture?.width != frame.width ||
            textureSlots[slotIndex].texture?.height != frame.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            textureSlots[slotIndex].texture = device?.makeTexture(descriptor: descriptor)
        }
        frame.data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            textureSlots[slotIndex].texture?.replace(
                region: MTLRegionMake2D(0, 0, frame.width, frame.height),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: frame.bytesPerRow
            )
        }
        textureSlots[slotIndex].aspectRatio = frame.aspectRatio > 0
            ? CGFloat(frame.aspectRatio)
            : CGFloat(frame.width) / CGFloat(frame.height)
        pendingSlot = slotIndex
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
        guard let slotIndex = pendingSlot,
              let activeTexture = textureSlots[slotIndex].texture else {
            textureLock.unlock()
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            return
        }
        pendingSlot = nil
        textureSlots[slotIndex].inFlight = true
        let activeAspectRatio = textureSlots[slotIndex].aspectRatio
        textureLock.unlock()
        encoder.setRenderPipelineState(pipeline)
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
        encoder.endEncoding()
        buffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.textureLock.lock()
            self.textureSlots[slotIndex].inFlight = false
            self.textureLock.unlock()
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
