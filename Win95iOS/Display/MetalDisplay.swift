import MetalKit

final class MetalDisplayView: MTKView, MTKViewDelegate {
    private struct TextureSlot {
        var texture: MTLTexture?
        var aspectRatio: CGFloat = 4.0 / 3.0
        var inFlightCount = 0
    }

    private var pipeline: MTLRenderPipelineState!
    private var commandQueue: MTLCommandQueue!
    private var textureSlots = Array(repeating: TextureSlot(), count: 3)
    private var pendingSlot: Int?
    private var displayedSlot: Int?
    private let textureLock = NSLock()
    private var displayZoom: CGFloat = 1
    private var displayOffset = CGPoint.zero

    private var zoomScale: CGFloat {
        get {
            textureLock.lock()
            defer { textureLock.unlock() }
            return displayZoom
        }
        set {
            textureLock.lock()
            displayZoom = min(4, max(1, newValue))
            if displayZoom == 1 { displayOffset = .zero }
            textureLock.unlock()
            setNeedsDisplay()
        }
    }

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

    func adjustZoom(by factor: CGFloat, around location: CGPoint) {
        guard factor.isFinite, factor > 0, bounds.width > 0, bounds.height > 0 else { return }
        textureLock.lock()
        let oldZoom = displayZoom
        let newZoom = min(4, max(1, oldZoom * factor))
        if newZoom == 1 {
            displayZoom = 1
            displayOffset = .zero
        } else if newZoom != oldZoom {
            let appliedFactor = newZoom / oldZoom
            let anchor = CGPoint(x: location.x / bounds.width, y: location.y / bounds.height)
            let oldCenter = CGPoint(x: 0.5 + displayOffset.x, y: 0.5 + displayOffset.y)
            let newCenter = CGPoint(
                x: anchor.x + (oldCenter.x - anchor.x) * appliedFactor,
                y: anchor.y + (oldCenter.y - anchor.y) * appliedFactor
            )
            displayZoom = newZoom
            displayOffset = CGPoint(x: newCenter.x - 0.5, y: newCenter.y - 0.5)
        }
        textureLock.unlock()
        setNeedsDisplay()
    }

    func panZoom(by translation: CGPoint) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        textureLock.lock()
        if displayZoom > 1 {
            displayOffset.x += translation.x / bounds.width
            displayOffset.y += translation.y / bounds.height
        }
        textureLock.unlock()
        setNeedsDisplay()
    }

    func resetZoom() { zoomScale = 1 }

    func present(_ frame: Win95VideoFrame) {
        guard frame.width > 0, frame.height > 0 else { return }
        textureLock.lock()
        // A texture must not be changed with replace() while a command buffer
        // is still sampling it. Reuse an unsubmitted pending slot, otherwise
        // take a texture whose previous GPU command has completed.
        guard let slotIndex = pendingSlot ?? textureSlots.indices.first(where: { textureSlots[$0].inFlightCount == 0 }) else {
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
        guard let slotIndex = pendingSlot ?? displayedSlot,
              let activeTexture = textureSlots[slotIndex].texture else {
            textureLock.unlock()
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            return
        }
        pendingSlot = nil
        displayedSlot = slotIndex
        textureSlots[slotIndex].inFlightCount += 1
        let activeAspectRatio = textureSlots[slotIndex].aspectRatio
        let zoom = displayZoom
        var offset = displayOffset
        textureLock.unlock()
        encoder.setRenderPipelineState(pipeline)
        let drawableWidth = Double(view.drawableSize.width)
        let drawableHeight = Double(view.drawableSize.height)
        let drawableAspectRatio = drawableHeight > 0 ? drawableWidth / drawableHeight : 1
        let contentAspectRatio = max(0.01, Double(activeAspectRatio))
        var baseWidth = drawableWidth
        var baseHeight = drawableHeight
        if drawableAspectRatio > contentAspectRatio {
            baseWidth = drawableHeight * contentAspectRatio
        } else {
            baseHeight = drawableWidth / contentAspectRatio
        }
        let scaledWidth = baseWidth * Double(zoom)
        let scaledHeight = baseHeight * Double(zoom)
        var centerX = drawableWidth * (0.5 + Double(offset.x))
        var centerY = drawableHeight * (0.5 + Double(offset.y))
        centerX = scaledWidth >= drawableWidth
            ? min(scaledWidth / 2, max(drawableWidth - scaledWidth / 2, centerX))
            : drawableWidth / 2
        centerY = scaledHeight >= drawableHeight
            ? min(scaledHeight / 2, max(drawableHeight - scaledHeight / 2, centerY))
            : drawableHeight / 2
        offset = CGPoint(
            x: centerX / drawableWidth - 0.5,
            y: centerY / drawableHeight - 0.5
        )
        textureLock.lock()
        displayOffset = offset
        textureLock.unlock()
        let viewport = MTLViewport(
            originX: centerX - scaledWidth / 2,
            originY: centerY - scaledHeight / 2,
            width: scaledWidth,
            height: scaledHeight,
            znear: 0,
            zfar: 1
        )
        encoder.setViewport(viewport)
        encoder.setFragmentTexture(activeTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        buffer.addCompletedHandler { [weak self] _ in
            guard let self else { return }
            self.textureLock.lock()
            self.textureSlots[slotIndex].inFlightCount -= 1
            self.textureLock.unlock()
        }
        buffer.present(drawable)
        buffer.commit()
    }
}
