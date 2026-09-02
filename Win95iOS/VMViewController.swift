import AVFoundation
import UniformTypeIdentifiers
import UIKit

final class VMViewController: UIViewController, UIDocumentPickerDelegate {
    private let displayView = MetalDisplayView()
    private let toolbar = UIStackView()
    private let statusLabel = UILabel()
    private let keyboardCapture = KeyboardCaptureView()
    private var bridge: Win95CoreBridge!
    private var audio: AudioOutput!
    private var displayLink: CADisplayLink?
    private var frameGeneration: UInt64 = 0
    private var previousTouch: CGPoint?
    private var pendingImport: ImportKind = .disk
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    private enum ImportKind { case disk, cd }

    private lazy var supportDirectory: URL = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Win95", isDirectory: true)
    }()
    private var savesDirectory: URL { supportDirectory.appendingPathComponent("Saves", isDirectory: true) }
    private var systemDirectory: URL { supportDirectory.appendingPathComponent("System", isDirectory: true) }
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
            self?.statusLabel.text = status
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
    override var canBecomeFirstResponder: Bool { true }

    private func createDirectories() {
        try? FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
    }

    private func configureUI() {
        displayView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(displayView)

        statusLabel.text = "Stopped"
        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusLabel.textAlignment = .center
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)

        toolbar.axis = .horizontal
        toolbar.alignment = .center
        toolbar.distribution = .fillEqually
        toolbar.spacing = 4
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.backgroundColor = UIColor(white: 0.10, alpha: 0.98)
        view.addSubview(toolbar)

        addButton("⌨︎", action: #selector(showKeyboard), hint: "Keyboard")
        addButton("L", action: #selector(leftClick), hint: "Left click")
        addButton("R", action: #selector(rightClick), hint: "Right click")
        addButton("CD", action: #selector(importCD), hint: "Mount CD image")
        addButton("Ⅱ", action: #selector(togglePause), hint: "Pause or resume")
        addButton("↻", action: #selector(resetVM), hint: "Reset")
        addButton("•••", action: #selector(showActions), hint: "More")

        keyboardCapture.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardCapture)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            keyboardCapture.widthAnchor.constraint(equalToConstant: 1),
            keyboardCapture.heightAnchor.constraint(equalToConstant: 1),
            keyboardCapture.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardCapture.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            statusLabel.centerXAnchor.constraint(equalTo: displayView.centerXAnchor),
            statusLabel.topAnchor.constraint(equalTo: displayView.topAnchor, constant: 8)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(trackpadPan(_:)))
        pan.maximumNumberOfTouches = 1
        displayView.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: self, action: #selector(leftClick))
        displayView.addGestureRecognizer(tap)
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
        statusLabel.text = "Starting…"
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
        present(UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true), animated: true)
    }

    @objc private func importCD() {
        pendingImport = .cd
        present(UIDocumentPickerViewController(forOpeningContentTypes: [.isoImage, .data], asCopy: true), animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let source = urls.first else { return }
        switch pendingImport {
        case .disk:
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
            let destination = supportDirectory.appendingPathComponent("mounted-cd").appendingPathExtension(source.pathExtension)
            do {
                if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                try FileManager.default.copyItem(at: source, to: destination)
                bridge.mountCD(at: destination) { [weak self] error in if let error { self?.showError(error) } }
            } catch { showError(error) }
        }
    }

    @objc private func showKeyboard() { keyboardCapture.becomeFirstResponder() }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPhysicalKeys(presses, pressed: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !forwardPhysicalKeys(presses, pressed: false) { super.pressesEnded(presses, with: event) }
    }

    private func forwardPhysicalKeys(_ presses: Set<UIPress>, pressed: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let mapped: UInt32?
            switch key.keyCode.rawValue {
            case 40: mapped = RetroKey.enter
            case 41: mapped = RetroKey.escape
            case 42: mapped = RetroKey.backspace
            case 43: mapped = RetroKey.tab
            case 44: mapped = RetroKey.space
            case 76: mapped = RetroKey.delete
            case 79: mapped = RetroKey.right
            case 80: mapped = RetroKey.left
            case 81: mapped = RetroKey.down
            case 82: mapped = RetroKey.up
            case 224: mapped = RetroKey.leftControl
            case 225: mapped = RetroKey.leftShift
            case 226: mapped = RetroKey.leftAlt
            default:
                mapped = key.charactersIgnoringModifiers.lowercased().utf8.first.map(UInt32.init)
            }
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
        sheet.addAction(UIAlertAction(title: "Eject CD", style: .default) { [weak self] _ in self?.bridge.ejectCD() })
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
