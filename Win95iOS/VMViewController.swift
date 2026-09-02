import AVFoundation
import UniformTypeIdentifiers
import UIKit

final class VMViewController: UIViewController, UIDocumentPickerDelegate {
    private let displayView = MetalDisplayView()
    private let toolbar = UIStackView()
    private let keyboardCapture = KeyboardCaptureView()
    private var bridge: Win95CoreBridge!
    private var audio: AudioOutput!
    private var displayLink: CADisplayLink?
    private var frameGeneration: UInt64 = 0
    private var previousTouch: CGPoint?
    private var pendingImport: ImportKind = .disk
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activeCDURL: URL?

    private enum ImportKind { case disk, cd }

    private lazy var supportDirectory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Win95", isDirectory: true)
    }()
    private var savesDirectory: URL { supportDirectory.appendingPathComponent("Saves", isDirectory: true) }
    private var systemDirectory: URL { supportDirectory.appendingPathComponent("System", isDirectory: true) }
    private var cdDirectory: URL { supportDirectory.appendingPathComponent("CDs", isDirectory: true) }
    private var importedDiskURL: URL? {
        for ext in ["img", "vhd"] {
            let url = supportDirectory.appendingPathComponent("win95-base").appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
    private var suspendURL: URL { supportDirectory.appendingPathComponent("suspend.state") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        createDirectories()
        bridge = Win95CoreBridge(saveDirectory: savesDirectory, systemDirectory: systemDirectory)
        audio = AudioOutput(bridge: bridge)
        bridge.statusHandler = { [weak self] status in
            if status == "Stopped" { self?.audio.stop() }
        }
        keyboardCapture.sendKey = { [weak self] key, pressed in self?.bridge.sendKey(key, pressed: pressed) }
        configureUI()
        startDisplayLink()
        startBundledOrImportedDisk()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    deinit { displayLink?.invalidate(); NotificationCenter.default.removeObserver(self) }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    private func createDirectories() {
        try? FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cdDirectory, withIntermediateDirectories: true)
    }

    private func configureUI() {
        displayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(displayView)

        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.distribution = .fillEqually
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor(white: 0.08, alpha: 0.78)
        toolbar.layer.cornerRadius = 12
        toolbar.clipsToBounds = true
        view.addSubview(toolbar)

        addButton("⌨︎", action: #selector(showKeyboard), hint: "Keyboard")
        addButton("L", action: #selector(leftClick), hint: "Left click")
        addButton("R", action: #selector(rightClick), hint: "Right click")
        addButton("CD", action: #selector(showCDMenu), hint: "CD images")
        addButton("Ⅱ", action: #selector(togglePause), hint: "Pause or resume")
        addButton("↻", action: #selector(resetVM), hint: "Reset")
        addButton("•••", action: #selector(showActions), hint: "More")

        keyboardCapture.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardCapture)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: view.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            toolbar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            keyboardCapture.widthAnchor.constraint(equalToConstant: 1),
            keyboardCapture.heightAnchor.constraint(equalToConstant: 1),
            keyboardCapture.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardCapture.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(trackpadPan(_:)))
        pan.maximumNumberOfTouches = 1
        displayView.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(leftClick))
        displayView.addGestureRecognizer(tap)
        let controlsTap = UITapGestureRecognizer(target: self, action: #selector(toggleControls))
        controlsTap.numberOfTouchesRequired = 2
        displayView.addGestureRecognizer(controlsTap)
    }

    private func addButton(_ title: String, action: Selector, hint: String) {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.accessibilityLabel = hint
        button.addTarget(self, action: action, for: .touchUpInside)
        toolbar.addArrangedSubview(button)
    }

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(refreshDisplay))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func refreshDisplay() {
        if let frame = bridge.latestVideoFrame(afterGeneration: frameGeneration) {
            frameGeneration = frame.generation
            displayView.present(frame)
        }
    }

    private func startBundledOrImportedDisk() {
        if let importedDiskURL { startVM(disk: importedDiskURL); return }
        if let bundled = Bundle.main.url(forResource: "win95-base", withExtension: "img", subdirectory: "BundledContent") { startVM(disk: bundled); return }
        showMissingDisk()
    }

    private func startVM(disk: URL, state: URL? = nil) {
        activeCDURL = nil
        bridge.start(withDiskURL: disk) { [weak self] error in
            guard let self else { return }
            if let error { self.showError(error); return }
            do { try self.audio.start() } catch { self.showError(error) }
            if let state, FileManager.default.fileExists(atPath: state.path) {
                self.bridge.loadState(from: state) { [weak self] error in if let error { self?.showError(error) } }
            }
        }
    }

    private func showMissingDisk() {
        let alert = UIAlertController(
            title: "Windows 95 disk required",
            message: "Select a raw .img or .vhd disk image containing your licensed, already-installed Windows 95 system. The image is copied into the app; changes are stored in a separate sector overlay.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Select Disk", style: .default) { [weak self] _ in self?.importDisk() })
        present(alert, animated: true)
    }

    @objc private func importDisk() {
        pendingImport = .disk
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func importCD() {
        pendingImport = .cd
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.isoImage, .data], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch pendingImport {
        case .disk:
            guard let source = urls.first else { return }
            let ext = source.pathExtension.lowercased()
            guard ext == "img" || ext == "vhd" else { showError(NSError(domain: "Win95UI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select a raw .img or .vhd disk image."])); return }
            do {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size >= 10 * 1024 * 1024, size % 512 == 0 else {
                    throw NSError(domain: "Win95UI", code: 2, userInfo: [NSLocalizedDescriptionKey: "The disk must be at least 10 MB and use a size divisible by 512 bytes."])
                }
                for oldExtension in ["img", "vhd"] {
                    let oldURL = supportDirectory.appendingPathComponent("win95-base").appendingPathExtension(oldExtension)
                    if FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.removeItem(at: oldURL) }
                }
                let destination = supportDirectory.appendingPathComponent("win95-base").appendingPathExtension(ext)
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
                startVM(disk: destination)
            } catch { showError(error) }
        case .cd:
            do {
                var firstMountable: URL?
                for source in urls {
                    let destination = uniqueCDDestination(for: source)
                    try FileManager.default.copyItem(at: source, to: destination)
                    if firstMountable == nil && isMountableCD(destination) { firstMountable = destination }
                }
                if let firstMountable { mountCD(firstMountable) }
            } catch { showError(error) }
        }
    }

    @objc private func showCDMenu() {
        let sheet = UIAlertController(title: "CD-ROM", message: "複数のイメージを保存し、実行中に交換できます。", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "CDイメージを追加…", style: .default) { [weak self] _ in self?.importCD() })
        for url in storedCDImages {
            let prefix = activeCDURL == url ? "✓ " : ""
            sheet.addAction(UIAlertAction(title: prefix + url.lastPathComponent, style: .default) { [weak self] _ in
                self?.mountCD(url)
            })
        }
        if activeCDURL != nil {
            sheet.addAction(UIAlertAction(title: "CDを取り出す", style: .destructive) { [weak self] _ in self?.ejectCD() })
        }
        sheet.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = toolbar
            popover.sourceRect = toolbar.bounds
        }
        present(sheet, animated: true)
    }

    private var storedCDImages: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cdDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter(isMountableCD).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func isMountableCD(_ url: URL) -> Bool {
        ["iso", "cue", "chd", "img"].contains(url.pathExtension.lowercased())
    }

    private func uniqueCDDestination(for source: URL) -> URL {
        let fileManager = FileManager.default
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var destination = cdDirectory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = cdDirectory.appendingPathComponent("\(base)-\(suffix)")
            if !ext.isEmpty { destination.appendPathExtension(ext) }
            suffix += 1
        }
        return destination
    }

    private func mountCD(_ url: URL) {
        bridge.mountCD(at: url) { [weak self] error in
            if let error { self?.showError(error) }
            else { self?.activeCDURL = url }
        }
    }

    private func ejectCD() {
        bridge.ejectCD()
        activeCDURL = nil
    }

    @objc private func showKeyboard() { keyboardCapture.becomeFirstResponder() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPhysicalKeys(presses, pressed: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPhysicalKeys(presses, pressed: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPhysicalKeys(presses, pressed: false) { super.pressesCancelled(presses, with: event) }
    }

    private func forwardPhysicalKeys(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let mapped = RetroKey.fromHIDUsage(key.keyCode.rawValue)
            if let mapped { bridge.sendKey(mapped, pressed: pressed); handled = true }
        }
        return handled
    }

    @objc private func trackpadPan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.translation(in: displayView)
        if let previousTouch {
            bridge.addMouseDeltaX(Int(point.x - previousTouch.x), deltaY: Int(point.y - previousTouch.y))
        }
        previousTouch = recognizer.state == .ended || recognizer.state == .cancelled ? nil : point
    }

    @objc private func leftClick() { click(left: true) }
    @objc private func rightClick() { click(left: false) }
    @objc private func toggleControls() {
        UIView.animate(withDuration: 0.2) { self.toolbar.alpha = self.toolbar.alpha > 0 ? 0 : 1 }
    }

    private func click(left: Bool) {
        if left { bridge.setLeftMouseButton(true) } else { bridge.setRightMouseButton(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            if left { self?.bridge.setLeftMouseButton(false) } else { self?.bridge.setRightMouseButton(false) }
        }
    }

    @objc private func togglePause() { bridge.setEmulationPaused(!bridge.isPaused) }
    @objc private func resetVM() { bridge.reset() }

    @objc private func showActions() {
        let sheet = UIAlertController(title: "Windows 95", message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Save State", style: .default) { [weak self] _ in self?.saveState() })
        sheet.addAction(UIAlertAction(title: "Load State", style: .default) { [weak self] _ in self?.loadState() })
        sheet.addAction(UIAlertAction(title: "CD Images", style: .default) { [weak self] _ in self?.showCDMenu() })
        sheet.addAction(UIAlertAction(title: "Replace Base Disk", style: .default) { [weak self] _ in self?.replaceDisk() })
        sheet.addAction(UIAlertAction(title: "Reset Windows Data", style: .destructive) { [weak self] _ in self?.confirmResetWindows() })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = sheet.popoverPresentationController { popover.sourceView = toolbar; popover.sourceRect = toolbar.bounds }
        present(sheet, animated: true)
    }

    private func saveState() {
        bridge.saveState(to: suspendURL) { [weak self] error in if let error { self?.showError(error) } }
    }

    private func loadState() {
        bridge.loadState(from: suspendURL) { [weak self] error in if let error { self?.showError(error) } }
    }

    private func replaceDisk() {
        audio.stop()
        bridge.stop { [weak self] in self?.importDisk() }
    }

    private func confirmResetWindows() {
        let alert = UIAlertController(title: "Reset Windows?", message: "All changes stored in the writable overlay and the save state will be deleted. The base disk is kept.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Reset", style: .destructive) { [weak self] _ in self?.resetWindowsData() })
        present(alert, animated: true)
    }

    private func resetWindowsData() {
        let disk: URL?
        if let importedDiskURL { disk = importedDiskURL }
        else { disk = Bundle.main.url(forResource: "win95-base", withExtension: "img", subdirectory: "BundledContent") }
        audio.stop()
        bridge.stop { [weak self] in
            guard let self, let disk else { return }
            let names = ["win95-base-CDRIVE.sav", "win95-base.pure.zip", "suspend.state"]
            for name in names { try? FileManager.default.removeItem(at: name == "suspend.state" ? self.suspendURL : self.savesDirectory.appendingPathComponent(name)) }
            self.startVM(disk: disk)
        }
    }

    @objc private func appDidEnterBackground() {
        guard bridge.isRunning else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Windows 95") { [weak self] in
            guard let self else { return }
            if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask) }
            self.backgroundTask = .invalid
        }
        bridge.saveState(to: suspendURL) { [weak self] _ in
            guard let self else { return }
            self.bridge.flushDisk()
            self.bridge.setEmulationPaused(true)
            if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask) }
            self.backgroundTask = .invalid
        }
    }

    @objc private func appWillEnterForeground() { if bridge.isRunning { bridge.setEmulationPaused(false) } }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private extension UTType {
    static var isoImage: UTType { UTType(filenameExtension: "iso") ?? .data }
}
