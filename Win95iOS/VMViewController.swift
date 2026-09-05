import AVFoundation
import Darwin
import GameController
import UniformTypeIdentifiers
import UIKit

final class VMViewController: UIViewController, UIDocumentPickerDelegate, UIGestureRecognizerDelegate, UIPointerInteractionDelegate {
    private let displayView = MetalDisplayView()
    private let pauseOverlay = PauseOverlayView()
    private let toolbar = FloatingMenuView()
    private let keyboardCapture = KeyboardCaptureView()
    private let diskSetupView = DiskSetupView()
    private lazy var physicalKeyboard = PhysicalKeyboardInput { [weak self] key, pressed in
        self?.bridge.sendKey(key, pressed: pressed)
    }
    private var bridge: Win95CoreBridge!
    private var audio: AudioOutput!
    private var displayLink: CADisplayLink?
    private var frameGeneration: UInt64 = 0
    private var scrollRemainder: CGFloat = 0
    private var touchDragActive = false
    private weak var physicalMouse: GCMouse?
    private var pendingImport: ImportKind = .disk
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activeCDURL: URL?
    private var activeDiskURL: URL?
    private var manuallyPaused = false
    private var resumeAfterForeground = false
    private var pauseGeneration = 0
    private var isChangingCD = false
    private weak var pauseButton: UIButton?
    private weak var cdLibraryController: CDLibraryViewController?

    private enum ImportKind { case disk, cd }

    private lazy var supportDirectory: URL = {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Win95", isDirectory: true)
    }()
    private var legacySupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Win95", isDirectory: true)
    }
    private var savesDirectory: URL { supportDirectory.appendingPathComponent("Saves", isDirectory: true) }
    private var systemDirectory: URL { supportDirectory.appendingPathComponent("System", isDirectory: true) }
    private var cdDirectory: URL { supportDirectory.appendingPathComponent("CDs", isDirectory: true) }
    private var suspendStateURL: URL { savesDirectory.appendingPathComponent("automatic-suspend.state") }
    private let selectedCDKey = "SelectedCDImageName"
    private let cdMountInProgressKey = "CDMountInProgress"
    private let cdMountStateVersionKey = "CDMountStateVersion"
    private var recoveredFromInterruptedCDMount = false
    private var importedDiskURL: URL? {
        for ext in ["img", "vhd"] {
            let url = supportDirectory.appendingPathComponent("win95-base").appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        createDirectories()
        bridge = Win95CoreBridge(saveDirectory: savesDirectory, systemDirectory: systemDirectory)
        audio = AudioOutput(bridge: bridge)
        bridge.statusHandler = { [weak self] status in self?.handleCoreStatus(status) }
        keyboardCapture.sendKey = { [weak self] key, pressed in self?.bridge.sendKey(key, pressed: pressed) }
        keyboardCapture.keyboardDidHide = { [weak self] in self?.becomeFirstResponder() }
        _ = physicalKeyboard
        configureUI()
        startPhysicalMouseSupport()
        startDisplayLink()
        startBundledOrImportedDisk()

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit {
        physicalKeyboard.releaseAll()
        detachPhysicalMouse()
        displayLink?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        toolbar.place(in: view.bounds, safeAreaInsets: view.safeAreaInsets)
    }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    private func createDirectories() {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: supportDirectory.path),
           fileManager.fileExists(atPath: legacySupportDirectory.path) {
            do { try fileManager.moveItem(at: legacySupportDirectory, to: supportDirectory) }
            catch { NSLog("Could not migrate Windows 95 data into Documents: %@", error.localizedDescription) }
        }
        try? FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cdDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: suspendStateURL.appendingPathExtension("partial"))
    }

    private func configureUI() {
        displayView.translatesAutoresizingMaskIntoConstraints = false
        displayView.isMultipleTouchEnabled = true
        view.addSubview(displayView)

        pauseOverlay.translatesAutoresizingMaskIntoConstraints = false
        pauseOverlay.isHidden = true
        view.addSubview(pauseOverlay)

        view.addSubview(toolbar)

        let keyboardButton = toolbar.addButton("", target: self, action: #selector(showKeyboard), hint: "Keyboard")
        let keyboardSymbol = UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        keyboardButton.setImage(UIImage(systemName: "keyboard", withConfiguration: keyboardSymbol), for: .normal)
        toolbar.addButton("DOS", target: self, action: #selector(toggleDOSFullScreen), hint: "DOS full screen (Alt+Enter)")
        toolbar.addButton("CD", target: self, action: #selector(showCDMenu), hint: "CD images")
        pauseButton = toolbar.addButton("", target: self, action: #selector(togglePause), hint: "Pause")
        updatePauseButton()
        toolbar.addButton("↻", target: self, action: #selector(resetVM), hint: "Reset")

        keyboardCapture.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardCapture)

        diskSetupView.translatesAutoresizingMaskIntoConstraints = false
        diskSetupView.isHidden = true
        diskSetupView.onSelectImage = { [weak self] in self?.importDisk() }
        view.addSubview(diskSetupView)
        NSLayoutConstraint.activate([
            displayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            displayView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            displayView.topAnchor.constraint(equalTo: view.topAnchor),
            displayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pauseOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pauseOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pauseOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            pauseOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            keyboardCapture.widthAnchor.constraint(equalToConstant: 1),
            keyboardCapture.heightAnchor.constraint(equalToConstant: 1),
            keyboardCapture.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardCapture.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            diskSetupView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            diskSetupView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            diskSetupView.topAnchor.constraint(equalTo: view.topAnchor),
            diskSetupView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(trackpadPan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = directTouchTypes
        pan.delegate = self
        pan.cancelsTouchesInView = false
        displayView.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(leftClick))
        tap.allowedTouchTypes = directTouchTypes
        tap.delegate = self
        displayView.addGestureRecognizer(tap)

        let drag = UILongPressGestureRecognizer(target: self, action: #selector(dragMouse(_:)))
        drag.numberOfTouchesRequired = 1
        drag.allowedTouchTypes = directTouchTypes
        drag.delegate = self
        drag.cancelsTouchesInView = false
        displayView.addGestureRecognizer(drag)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerRightClick(_:)))
        rightTap.numberOfTouchesRequired = 2
        rightTap.allowedTouchTypes = directTouchTypes
        rightTap.delegate = self
        displayView.addGestureRecognizer(rightTap)
        tap.require(toFail: rightTap)

        let touchScroll = UIPanGestureRecognizer(target: self, action: #selector(scrollMouse(_:)))
        touchScroll.minimumNumberOfTouches = 2
        touchScroll.maximumNumberOfTouches = 2
        touchScroll.allowedTouchTypes = directTouchTypes
        touchScroll.delegate = self
        displayView.addGestureRecognizer(touchScroll)

        let pointerScroll = UIPanGestureRecognizer(target: self, action: #selector(scrollMouse(_:)))
        pointerScroll.minimumNumberOfTouches = 0
        pointerScroll.maximumNumberOfTouches = 0
        pointerScroll.allowedScrollTypesMask = .all
        displayView.addGestureRecognizer(pointerScroll)
        displayView.addInteraction(UIPointerInteraction(delegate: self))
    }

    private var directTouchTypes: [NSNumber] {
        [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }

    private func startDisplayLink() {
        let link = CADisplayLink(target: self, selector: #selector(refreshDisplay))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        } else {
            link.preferredFramesPerSecond = 60
        }
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
        let initialCD = recoverablePersistedCDURL
        if let importedDiskURL { startVM(disk: importedDiskURL, CD: initialCD); return }
        if let bundled = Bundle.main.url(forResource: "win95-base", withExtension: "img", subdirectory: "BundledContent") { startVM(disk: bundled, CD: initialCD); return }
        showMissingDisk()
    }

    private var recoverablePersistedCDURL: URL? {
        let defaults = UserDefaults.standard
        // Retry selections from the old DOS mount backend using the new ATAPI
        // backend. Only an interrupted operation on this backend gets a safe boot.
        if defaults.bool(forKey: cdMountInProgressKey) && defaults.integer(forKey: cdMountStateVersionKey) >= 3 {
            defaults.removeObject(forKey: cdMountInProgressKey)
            defaults.synchronize()
            recoveredFromInterruptedCDMount = true
            return nil
        }
        guard let name = defaults.string(forKey: selectedCDKey),
              !name.contains("/"), !name.contains("\\") else { return nil }
        let url = cdDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func startVM(disk: URL, CD: URL?, restoreSuspendState: Bool = true) {
        do {
            try preserveIncompatibleSuspendState()
            if CD == nil, UserDefaults.standard.string(forKey: selectedCDKey) != nil {
                try archiveSuspendState(reason: "media-unavailable")
            }
            let save = savesDirectory.appendingPathComponent("win95-base-CDRIVE.sav")
            if FileManager.default.fileExists(atPath: save.path) {
                let handle = try FileHandle(forReadingFrom: save)
                defer { try? handle.close() }
                guard try handle.read(upToCount: 5) == Data([70, 70, 68, 68, 1]) else {
                    throw NSError(domain: "Win95UI", code: 8, userInfo: [NSLocalizedDescriptionKey: "Saves/win95-base-CDRIVE.sav のヘッダーが壊れているため起動を中止しました。原本は保持しています。ファイルアプリでバックアップしてから、同じベースイメージに対応する保存データを戻してください。"])
                }
            }
        } catch { diskSetupView.setBusy(false); showError(error); return }
        activeDiskURL = disk
        activeCDURL = nil
        bridge.start(diskURL: disk) { [weak self] error in
            guard let self else { return }
            self.toolbar.showActivity(false)
            self.refreshCDLibrary(busy: false)
            if let error {
                self.diskSetupView.setBusy(false)
                self.showError(error)
                return
            }
            self.hideMissingDisk()
            let finishStartup = {
                if restoreSuspendState, !self.recoveredFromInterruptedCDMount,
                   FileManager.default.fileExists(atPath: self.suspendStateURL.path) {
                    self.restoreAutomaticSuspendState()
                } else {
                    self.startAudioIfNeeded()
                }
            }
            if let CD {
                // Restore ATAPI state only after its media has been attached.
                self.changeCD(to: CD, automatic: true, afterChange: finishStartup)
                return
            }
            finishStartup()
            if self.recoveredFromInterruptedCDMount {
                self.recoveredFromInterruptedCDMount = false
                self.showError(NSError(
                    domain: "Win95UI",
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "以前のCDマウント状態を安全に復旧するため、CDを取り出した状態で起動しました。CDイメージを確認してから再度マウントしてください。"]
                ))
            }
        }
    }

    private func preserveIncompatibleSuspendState() throws {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: "SuspendStorageBackendVersion") < 3 else { return }
        try archiveSuspendState(reason: "previous-core")
        defaults.set(3, forKey: "SuspendStorageBackendVersion")
    }

    private func archiveSuspendState(reason: String) throws {
        guard FileManager.default.fileExists(atPath: suspendStateURL.path) else { return }
        let backup = savesDirectory.appendingPathComponent("automatic-suspend.\(reason)-\(UUID().uuidString).state")
        try FileManager.default.moveItem(at: suspendStateURL, to: backup)
    }

    private func startAudioIfNeeded() {
        guard !bridge.isPaused else { return }
        do { try audio.start() } catch { showError(error) }
    }

    private func restoreAutomaticSuspendState() {
        bridge.loadSuspendState(from: suspendStateURL) { [weak self] error in
            guard let self else { return }
            if let error {
                try? FileManager.default.removeItem(at: self.suspendStateURL)
                self.showError(error)
                self.bridge.setEmulationPaused(false)
                self.startAudioIfNeeded()
                return
            }
            self.manuallyPaused = true
            self.bridge.setEmulationPaused(true)
            self.updatePausedAppearance(saving: false)
        }
    }

    private func showMissingDisk() {
        keyboardCapture.dismissKeyboard()
        pauseOverlay.isHidden = true
        toolbar.isHidden = true
        diskSetupView.setBusy(false)
        diskSetupView.isHidden = false
        view.bringSubviewToFront(diskSetupView)
    }

    private func hideMissingDisk() {
        diskSetupView.setBusy(false)
        diskSetupView.isHidden = true
        toolbar.isHidden = false
    }

    @objc private func importDisk() {
        pendingImport = .disk
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentCDPicker(from presenter: UIViewController) {
        pendingImport = .cd
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.isoImage, .data], asCopy: false)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        switch pendingImport {
        case .disk:
            guard let source = urls.first else { return }
            let ext = source.pathExtension.lowercased()
            guard ext == "img" || ext == "vhd" else {
                diskSetupView.setBusy(false)
                showError(NSError(domain: "Win95UI", code: 1, userInfo: [NSLocalizedDescriptionKey: "raw形式の .img または .vhd ディスクイメージを選択してください。"]))
                return
            }
            diskSetupView.setBusy(true)
            do {
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size >= 10 * 1024 * 1024, size % 512 == 0 else {
                    throw NSError(domain: "Win95UI", code: 2, userInfo: [NSLocalizedDescriptionKey: "ディスクイメージは10 MB以上で、ファイルサイズが512バイトの倍数である必要があります。"])
                }
                for oldExtension in ["img", "vhd"] {
                    let oldURL = supportDirectory.appendingPathComponent("win95-base").appendingPathExtension(oldExtension)
                    if FileManager.default.fileExists(atPath: oldURL.path) { try FileManager.default.removeItem(at: oldURL) }
                }
                let destination = supportDirectory.appendingPathComponent("win95-base").appendingPathExtension(ext)
                try FileManager.default.copyItem(at: source, to: destination)
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
                discardAutomaticSuspendState()
                if bridge.isRunning {
                    audio.stop()
                    bridge.stop { [weak self] in self?.startVM(disk: destination, CD: nil, restoreSuspendState: false) }
                } else {
                    startVM(disk: destination, CD: nil, restoreSuspendState: false)
                }
            } catch {
                diskSetupView.setBusy(false)
                showError(error)
            }
        case .cd:
            importCDImages(urls)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if pendingImport == .disk { diskSetupView.setBusy(false) }
    }

    private func importCDImages(_ sources: [URL]) {
        guard !sources.isEmpty else { return }
        toolbar.showActivity(true)
        refreshCDLibrary(busy: true)
        let destinationDirectory = cdDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                var firstMountable: URL?
                for source in sources {
                    let destination = self.uniqueCDDestination(for: source, in: destinationDirectory)
                    try self.copyLargeFile(from: source, to: destination)
                    if firstMountable == nil && self.isMountableCD(destination) { firstMountable = destination }
                }
                DispatchQueue.main.async {
                    self.toolbar.showActivity(false)
                    self.refreshCDLibrary(busy: false)
                    if self.activeCDURL == nil, let firstMountable { self.mountCD(firstMountable) }
                }
            } catch {
                DispatchQueue.main.async {
                    self.toolbar.showActivity(false)
                    self.refreshCDLibrary(busy: false)
                    self.showError(error)
                }
            }
        }
    }

    private func copyLargeFile(from source: URL, to destination: URL) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do { try streamCopy(from: coordinatedURL, to: destination) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private func streamCopy(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        let sourceSize = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let volumeValues = try cdDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volumeValues.volumeAvailableCapacityForImportantUsage,
           available < sourceSize + 64 * 1024 * 1024 {
            throw NSError(
                domain: "Win95UI",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "CDイメージを保存する空き容量が不足しています。"]
            )
        }

        let partial = destination.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw NSError(domain: "Win95UI", code: 4, userInfo: [NSLocalizedDescriptionKey: "CDイメージの保存先を作成できません。"])
        }

        do {
            let input = try FileHandle(forReadingFrom: source)
            let output = try FileHandle(forWritingTo: partial)
            var copiedBytes: Int64 = 0
            defer { try? input.close(); try? output.close() }
            while try autoreleasepool(invoking: {
                let data = try input.read(upToCount: 4 * 1024 * 1024) ?? Data()
                guard !data.isEmpty else { return false }
                try output.write(contentsOf: data)
                copiedBytes += Int64(data.count)
                return true
            }) {}
            try output.synchronize()
            guard sourceSize == 0 || copiedBytes == sourceSize else {
                throw NSError(
                    domain: "Win95UI",
                    code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "CDイメージを最後まで読み込めませんでした。"]
                )
            }
            if destination.pathExtension.lowercased() == "iso" { try validateISO(at: partial) }
            try fileManager.moveItem(at: partial, to: destination)
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var storedURL = destination
            try? storedURL.setResourceValues(resourceValues)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }

    private func validateISO(at url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let signatures: [[UInt8]] = [
            [1, 67, 68, 48, 48, 49, 1], // ISO 9660: \u{1}CD001\u{1}
            [1, 67, 68, 82, 79, 77, 1]  // High Sierra: \u{1}CDROM\u{1}
        ]
        for offset in [32_768, 32_776, 37_400, 37_408, 37_648, 37_656, 37_664] {
            try handle.seek(toOffset: UInt64(offset))
            let bytes = Array((try handle.read(upToCount: 7) ?? Data()).prefix(7))
            if signatures.contains(bytes) { return }
        }
        throw NSError(
            domain: "Win95UI",
            code: 6,
            userInfo: [NSLocalizedDescriptionKey: "有効なISO 9660 CDイメージではありません。ファイルが破損していないか確認してください。"]
        )
    }

    @objc private func showCDMenu() {
        if let existing = cdLibraryController {
            existing.reload(images: storedCDImages, activeURL: activeCDURL, busy: false)
            return
        }

        let library = CDLibraryViewController(images: storedCDImages, activeURL: activeCDURL)
        library.onAdd = { [weak self, weak library] in
            guard let self, let library else { return }
            self.presentCDPicker(from: library)
        }
        library.onMount = { [weak self] url in self?.mountCD(url) }
        library.onEject = { [weak self] in self?.ejectCD() }
        library.onDelete = { [weak self] url in self?.confirmDeleteCD(url) }
        library.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        cdLibraryController = library

        let navigation = UINavigationController(rootViewController: library)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func refreshCDLibrary(busy: Bool) {
        cdLibraryController?.reload(images: storedCDImages, activeURL: activeCDURL, busy: busy)
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

    private func uniqueCDDestination(for source: URL, in directory: URL? = nil) -> URL {
        let fileManager = FileManager.default
        let directory = directory ?? cdDirectory
        let ext = source.pathExtension
        let base = source.deletingPathExtension().lastPathComponent
        var destination = directory.appendingPathComponent(source.lastPathComponent)
        var suffix = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("\(base)-\(suffix)")
            if !ext.isEmpty { destination.appendPathExtension(ext) }
            suffix += 1
        }
        return destination
    }

    private func mountCD(_ url: URL) {
        if url.pathExtension.lowercased() == "iso" {
            do { try validateISO(at: url) }
            catch { showError(error); return }
        }
        changeCD(to: url)
    }

    private func ejectCD() {
        changeCD(to: nil)
    }

    private func changeCD(to CD: URL?, automatic: Bool = false, afterChange: (() -> Void)? = nil) {
        guard !isChangingCD, bridge.isRunning else { return }
        isChangingCD = true
        refreshCDLibrary(busy: true)
        toolbar.showActivity(true)
        let defaults = UserDefaults.standard
        defaults.set(3, forKey: cdMountStateVersionKey)
        defaults.set(true, forKey: cdMountInProgressKey)
        defaults.synchronize()

        let completion: (Error?) -> Void = { [weak self] error in
            guard let self else { return }
            defaults.removeObject(forKey: self.cdMountInProgressKey)
            defaults.synchronize()
            self.isChangingCD = false
            self.toolbar.showActivity(false)
            if let error {
                if automatic {
                    // Preserve the library selection so a temporary file error
                    // does not silently forget the user's CD on the next launch.
                    do { try self.archiveSuspendState(reason: "media-unavailable") }
                    catch { self.showError(error) }
                    self.startAudioIfNeeded()
                }
                self.showError(error)
            } else {
                self.activeCDURL = CD
                if let CD {
                    defaults.set(CD.lastPathComponent, forKey: self.selectedCDKey)
                    defaults.set(3, forKey: self.cdMountStateVersionKey)
                }
                else { defaults.removeObject(forKey: self.selectedCDKey) }
                defaults.synchronize()
                afterChange?()
            }
            self.refreshCDLibrary(busy: false)
        }
        if let CD { bridge.mountCD(at: CD, completion: completion) }
        else { bridge.ejectCD(completion: completion) }
    }

    private func confirmDeleteCD(_ url: URL) {
        let alert = UIAlertController(
            title: "CDイメージを削除しますか？",
            message: url.lastPathComponent,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            self?.deleteCD(url)
        })
        let presenter: UIViewController = cdLibraryController ?? self
        presenter.present(alert, animated: true)
    }

    private func deleteCD(_ url: URL) {
        refreshCDLibrary(busy: true)
        let removeFile = { [weak self] in
            guard let self else { return }
            do { try FileManager.default.removeItem(at: url) }
            catch { self.showError(error) }
            self.refreshCDLibrary(busy: false)
        }
        guard activeCDURL == url else { removeFile(); return }
        changeCD(to: nil, afterChange: removeFile)
    }

    @objc private func showKeyboard() {
        if keyboardCapture.isFirstResponder { keyboardCapture.dismissKeyboard() }
        else { keyboardCapture.becomeFirstResponder() }
    }

    // Localized Windows 95 OSR2 builds can fail to repaint a windowed DOS VM.
    // Full-screen DOS uses a different VGA path and avoids that guest/core bug.
    @objc private func toggleDOSFullScreen() {
        guard bridge.isRunning, !bridge.isPaused else { return }
        bridge.sendKey(RetroKey.leftAlt, pressed: true)
        bridge.sendKey(RetroKey.enter, pressed: true)
        bridge.sendKey(RetroKey.enter, pressed: false)
        bridge.sendKey(RetroKey.leftAlt, pressed: false)
    }

    @objc private func trackpadPan(_ recognizer: UIPanGestureRecognizer) {
        let delta = recognizer.translation(in: displayView)
        if delta != .zero {
            bridge.addMouseDeltaX(Int(delta.x.rounded()), deltaY: Int(delta.y.rounded()))
            recognizer.setTranslation(.zero, in: displayView)
        }
    }

    @objc private func dragMouse(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began:
            touchDragActive = true
            bridge.setLeftMouseButton(true)
            UISelectionFeedbackGenerator().selectionChanged()
        case .ended, .cancelled, .failed:
            if touchDragActive { bridge.setLeftMouseButton(false) }
            touchDragActive = false
        default:
            break
        }
    }

    @objc private func twoFingerRightClick(_ recognizer: UITapGestureRecognizer) {
        if recognizer.state == .ended { rightClick() }
    }

    @objc private func scrollMouse(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: displayView)
        recognizer.setTranslation(.zero, in: displayView)
        scrollRemainder += translation.y
        let pointsPerStep: CGFloat = 18
        let steps = Int(scrollRemainder / pointsPerStep)
        if steps != 0 {
            bridge.addMouseWheelDelta(steps)
            scrollRemainder -= CGFloat(steps) * pointsPerStep
        }
        if recognizer.state == .ended || recognizer.state == .cancelled { scrollRemainder = 0 }
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        let pair = [gestureRecognizer, otherGestureRecognizer]
        return pair.contains { $0 is UILongPressGestureRecognizer } &&
            pair.contains { $0 is UIPanGestureRecognizer && ($0 as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1 }
    }

    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }

    @objc private func leftClick() { click(left: true) }
    @objc private func rightClick() { click(left: false) }
    private func click(left: Bool) {
        if left { bridge.setLeftMouseButton(true) } else { bridge.setRightMouseButton(true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            if left { self?.bridge.setLeftMouseButton(false) } else { self?.bridge.setRightMouseButton(false) }
        }
    }

    @objc private func togglePause() {
        guard bridge.isRunning, !isChangingCD else { return }
        if bridge.isPaused {
            manuallyPaused = false
            resumeAfterForeground = false
            discardAutomaticSuspendState()
            bridge.setEmulationPaused(false)
            updatePausedAppearance(saving: false)
            startAudioIfNeeded()
        } else {
            keyboardCapture.dismissKeyboard()
            touchDragActive = false
            bridge.setLeftMouseButton(false)
            bridge.setRightMouseButton(false)
            audio.stop()
            manuallyPaused = true
            pauseGeneration += 1
            bridge.setEmulationPaused(true)
            updatePausedAppearance(saving: true)
            saveAutomaticSuspendState(generation: pauseGeneration)
        }
    }

    private func updatePauseButton() {
        let paused = bridge?.isPaused ?? false
        pauseButton?.setImage(UIImage(systemName: paused ? "play.fill" : "pause.fill"), for: .normal)
        pauseButton?.accessibilityLabel = paused ? "Resume" : "Pause"
    }

    private func updatePausedAppearance(saving: Bool) {
        let paused = bridge?.isPaused == true && manuallyPaused
        pauseOverlay.isHidden = !paused
        pauseOverlay.setSaving(saving && paused)
        updatePauseButton()
    }

    private func saveAutomaticSuspendState(generation: Int, completion: (() -> Void)? = nil) {
        bridge.saveSuspendState(to: suspendStateURL) { [weak self] error in
            guard let self else { return }
            if self.pauseGeneration != generation || !self.manuallyPaused {
                try? FileManager.default.removeItem(at: self.suspendStateURL)
            } else if let error {
                self.showError(error)
            } else {
                var stateURL = self.suspendStateURL
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? stateURL.setResourceValues(values)
            }
            self.updatePausedAppearance(saving: false)
            completion?()
        }
    }

    private func discardAutomaticSuspendState() {
        pauseGeneration += 1
        try? FileManager.default.removeItem(at: suspendStateURL)
        try? FileManager.default.removeItem(at: suspendStateURL.appendingPathExtension("partial"))
    }

    @objc private func resetVM() {
        guard bridge.isRunning else { return }
        manuallyPaused = false
        resumeAfterForeground = false
        discardAutomaticSuspendState()
        bridge.setEmulationPaused(false)
        updatePausedAppearance(saving: false)
        bridge.reset()
        startAudioIfNeeded()
    }

    @objc private func appDidEnterBackground() {
        guard bridge.isRunning else { return }
        touchDragActive = false
        physicalKeyboard.releaseAll()
        keyboardCapture.releaseModifiers()
        bridge.setLeftMouseButton(false)
        bridge.setRightMouseButton(false)
        audio.stop()
        finishBackgroundTask()
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save Windows 95") { [weak self] in
            self?.finishBackgroundTask()
        }
        if manuallyPaused {
            updatePausedAppearance(saving: true)
            saveAutomaticSuspendState(generation: pauseGeneration) { [weak self] in self?.finishBackgroundTask() }
        } else {
            resumeAfterForeground = true
            bridge.setEmulationPaused(true)
            bridge.flushDisk { [weak self] _ in self?.finishBackgroundTask() }
        }
    }

    private func finishBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    @objc private func appWillEnterForeground() {
        guard bridge.isRunning else { return }
        if resumeAfterForeground {
            resumeAfterForeground = false
            bridge.setEmulationPaused(false)
            updatePausedAppearance(saving: false)
            startAudioIfNeeded()
        } else {
            updatePausedAppearance(saving: false)
        }
    }
    @objc private func appDidBecomeActive() { becomeFirstResponder() }

    private func handleCoreStatus(_ status: String) {
        if status == "Running" || status == "Paused" { updatePauseButton() }
        if status == "Stopped" || status == "Shutdown" { audio.stop() }
        guard status == "Shutdown" else { return }
        discardAutomaticSuspendState()
        displayLink?.invalidate()
        displayView.isHidden = true
        toolbar.isHidden = true
        view.backgroundColor = .black
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { exit(EXIT_SUCCESS) }
    }

    private func startPhysicalMouseSupport() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidBecomeCurrent(_:)),
            name: .GCMouseDidBecomeCurrent,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(mouseDidStopBeingCurrent(_:)),
            name: .GCMouseDidStopBeingCurrent,
            object: nil
        )
        if let mouse = GCMouse.current { attachPhysicalMouse(mouse) }
    }

    @objc private func mouseDidBecomeCurrent(_ notification: Notification) {
        if let mouse = notification.object as? GCMouse { attachPhysicalMouse(mouse) }
    }

    @objc private func mouseDidStopBeingCurrent(_ notification: Notification) {
        guard let mouse = notification.object as? GCMouse, mouse === physicalMouse else { return }
        detachPhysicalMouse()
    }

    private func attachPhysicalMouse(_ mouse: GCMouse) {
        detachPhysicalMouse()
        guard let input = mouse.mouseInput else { return }
        physicalMouse = mouse
        input.mouseMovedHandler = { [weak self] _, deltaX, deltaY in
            self?.bridge.addMouseDeltaX(Int(deltaX.rounded()), deltaY: Int((-deltaY).rounded()))
        }
        input.leftButton.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.bridge.setLeftMouseButton(pressed)
        }
        input.rightButton?.pressedChangedHandler = { [weak self] _, _, pressed in
            self?.bridge.setRightMouseButton(pressed)
        }
    }

    private func detachPhysicalMouse() {
        physicalMouse?.mouseInput?.mouseMovedHandler = nil
        physicalMouse?.mouseInput?.leftButton.pressedChangedHandler = nil
        physicalMouse?.mouseInput?.rightButton?.pressedChangedHandler = nil
        physicalMouse = nil
        bridge?.setLeftMouseButton(false)
        bridge?.setRightMouseButton(false)
    }

    private func showError(_ error: Error) {
        let alert = UIAlertController(title: "Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
            presenter = presented
        }
        presenter.present(alert, animated: true)
    }
}

private final class DiskSetupView: UIView {
    var onSelectImage: (() -> Void)?

    private let selectButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(red: 0.035, green: 0.045, blue: 0.065, alpha: 1)
        isUserInteractionEnabled = true

        let symbol = UIImageView(image: UIImage(systemName: "externaldrive.badge.plus"))
        symbol.tintColor = .systemBlue
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .medium)
        symbol.contentMode = .scaleAspectFit

        let titleLabel = UILabel()
        titleLabel.text = "Windows 95 イメージを選択"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 27, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let descriptionLabel = UILabel()
        descriptionLabel.text = "セットアップ済みの Windows 95 が入ったディスクイメージを選択してください。"
        descriptionLabel.textColor = UIColor.white.withAlphaComponent(0.82)
        descriptionLabel.font = .systemFont(ofSize: 16, weight: .regular)
        descriptionLabel.adjustsFontForContentSizeCategory = true
        descriptionLabel.textAlignment = .center
        descriptionLabel.numberOfLines = 0

        let formatLabel = UILabel()
        formatLabel.text = "対応形式: raw IMG / VHD  •  10 MB以上"
        formatLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        formatLabel.font = .systemFont(ofSize: 13, weight: .medium)
        formatLabel.adjustsFontForContentSizeCategory = true
        formatLabel.textAlignment = .center
        formatLabel.numberOfLines = 0

        var buttonConfiguration = UIButton.Configuration.filled()
        buttonConfiguration.title = "イメージを選択"
        buttonConfiguration.image = UIImage(systemName: "folder")
        buttonConfiguration.imagePadding = 9
        buttonConfiguration.cornerStyle = .large
        buttonConfiguration.baseBackgroundColor = .systemBlue
        buttonConfiguration.baseForegroundColor = .white
        buttonConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 22, bottom: 14, trailing: 22)
        selectButton.configuration = buttonConfiguration
        selectButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        selectButton.addTarget(self, action: #selector(selectImage), for: .touchUpInside)
        selectButton.accessibilityLabel = "Windows 95 ディスクイメージを選択"

        let storageLabel = UILabel()
        storageLabel.text = "選択したイメージはアプリ内へコピーされます。Windowsによる変更内容は別の保存データへ記録されるため、ベースイメージは変更されません。"
        storageLabel.textColor = UIColor.white.withAlphaComponent(0.52)
        storageLabel.font = .systemFont(ofSize: 12, weight: .regular)
        storageLabel.adjustsFontForContentSizeCategory = true
        storageLabel.textAlignment = .center
        storageLabel.numberOfLines = 0

        let stack = UIStackView(arrangedSubviews: [symbol, titleLabel, descriptionLabel, formatLabel, selectButton, storageLabel])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 14
        stack.setCustomSpacing(20, after: symbol)
        stack.setCustomSpacing(22, after: formatLabel)
        stack.setCustomSpacing(18, after: selectButton)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = UIColor(white: 0.10, alpha: 0.94)
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let scrollView = UIScrollView()
        scrollView.alwaysBounceVertical = false
        scrollView.showsVerticalScrollIndicator = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)
        contentView.addSubview(card)

        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 520)
        preferredWidth.priority = .defaultHigh
        let verticalCenter = card.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        verticalCenter.priority = .defaultHigh
        let fillHeight = contentView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        fillHeight.priority = .defaultLow
        NSLayoutConstraint.activate([
            symbol.heightAnchor.constraint(equalToConstant: 54),
            selectButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 50),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            scrollView.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            fillHeight,
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            verticalCenter,
            preferredWidth,
            card.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 20),
            card.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -20),
            card.topAnchor.constraint(greaterThanOrEqualTo: contentView.topAnchor, constant: 16),
            card.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func selectImage() {
        onSelectImage?()
    }

    func setBusy(_ busy: Bool) {
        selectButton.isEnabled = !busy
        var configuration = selectButton.configuration
        configuration?.title = busy ? "イメージを読み込み中…" : "イメージを選択"
        configuration?.image = busy ? nil : UIImage(systemName: "folder")
        configuration?.showsActivityIndicator = busy
        selectButton.configuration = configuration
    }
}

private final class PauseOverlayView: UIView {
    private let statusLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.42)
        isUserInteractionEnabled = true

        let symbol = UIImageView(image: UIImage(systemName: "pause.circle.fill"))
        symbol.tintColor = .white
        symbol.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .medium)

        statusLabel.text = "一時停止中"
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        statusLabel.textAlignment = .center

        detailLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        detailLabel.font = .systemFont(ofSize: 13, weight: .medium)
        detailLabel.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [symbol, statusLabel, detailLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.isLayoutMarginsRelativeArrangement = true
        stack.layoutMargins = UIEdgeInsets(top: 18, left: 28, bottom: 18, right: 28)
        stack.backgroundColor = UIColor(white: 0.08, alpha: 0.86)
        stack.layer.cornerRadius = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            symbol.widthAnchor.constraint(equalToConstant: 48),
            symbol.heightAnchor.constraint(equalToConstant: 48),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setSaving(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSaving(_ saving: Bool) {
        detailLabel.text = saving ? "状態を保存中…" : "▶ を押すと再開します"
    }
}

private final class CDLibraryViewController: UITableViewController {
    var onAdd: (() -> Void)?
    var onMount: ((URL) -> Void)?
    var onEject: (() -> Void)?
    var onDelete: ((URL) -> Void)?
    var onDismiss: (() -> Void)?

    private var images: [URL]
    private var activeURL: URL?
    private var busy = false
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(images: [URL], activeURL: URL?) {
        self.images = images
        self.activeURL = activeURL
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CD-ROM"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addImage)
        )
        navigationItem.leftBarButtonItem?.accessibilityLabel = "CDイメージを追加"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissLibrary)
        )
        tableView.allowsSelection = true
    }

    func reload(images: [URL], activeURL: URL?, busy: Bool) {
        self.images = images
        self.activeURL = activeURL
        self.busy = busy
        navigationItem.leftBarButtonItem?.isEnabled = !busy
        tableView.isUserInteractionEnabled = !busy
        tableView.alpha = busy ? 0.6 : 1
        if busy {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.titleView = spinner
        } else {
            navigationItem.titleView = nil
            title = "CD-ROM"
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return activeURL == nil ? 1 : 2 }
        return images.count + 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "現在のCD-ROM" : "保存済みイメージ"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        return "Windowsを動かしたままCDを挿入・交換・取り出しできます。左へスワイプすると削除できます。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 1

        if indexPath.section == 0 {
            if indexPath.row == 0 {
                if let activeURL {
                    cell.textLabel?.text = activeURL.lastPathComponent
                    cell.detailTextLabel?.text = "D: にマウント中"
                    cell.imageView?.image = UIImage(systemName: "opticaldisc.fill")
                } else {
                    cell.textLabel?.text = "ディスクなし"
                    cell.detailTextLabel?.text = "保存済みイメージを選択してください"
                    cell.imageView?.image = UIImage(systemName: "opticaldisc")
                }
                cell.selectionStyle = .none
            } else {
                cell.textLabel?.text = "CDを取り出す"
                cell.textLabel?.textColor = .systemRed
                cell.imageView?.image = UIImage(systemName: "eject.fill")
            }
            return cell
        }

        if indexPath.row == 0 {
            cell.textLabel?.text = "CDイメージを追加…"
            cell.textLabel?.textColor = view.tintColor
            cell.imageView?.image = UIImage(systemName: "plus.circle.fill")
            return cell
        }

        let imageURL = images[indexPath.row - 1]
        cell.textLabel?.text = imageURL.lastPathComponent
        if let size = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            cell.detailTextLabel?.text = byteFormatter.string(fromByteCount: Int64(size))
        }
        cell.imageView?.image = UIImage(systemName: "opticaldisc")
        cell.accessoryType = imageURL == activeURL ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        if indexPath.section == 0 {
            if indexPath.row == 1 { onEject?() }
        } else if indexPath.row == 0 {
            onAdd?()
        } else {
            let url = images[indexPath.row - 1]
            if url != activeURL { onMount?(url) }
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        !busy && indexPath.section == 1 && indexPath.row > 0
    }

    override func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, indexPath.section == 1, indexPath.row > 0 else { return }
        onDelete?(images[indexPath.row - 1])
    }

    @objc private func addImage() { if !busy { onAdd?() } }
    @objc private func dismissLibrary() { onDismiss?() }
}

private extension UTType {
    static var isoImage: UTType { UTType(filenameExtension: "iso") ?? .data }
}

private final class FloatingMenuView: UIView {
    private let handleButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let buttonStack = UIStackView()
    private let activity = UIActivityIndicatorView(style: .medium)
    private var isCollapsed = true
    private var opensToLeft = false
    private var hasInitialPosition = false
    private var expandedWidth: CGFloat = 360
    private let menuHeight: CGFloat = 48
    private let controlWidth: CGFloat = 43

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: menuHeight, height: menuHeight))
        backgroundColor = UIColor(white: 0.06, alpha: 0.88)
        layer.cornerRadius = menuHeight / 2
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.white.withAlphaComponent(0.28).cgColor
        clipsToBounds = true
        accessibilityLabel = "VM controls"

        handleButton.setImage(UIImage(systemName: "line.3.horizontal"), for: .normal)
        handleButton.tintColor = .white
        handleButton.accessibilityLabel = "Open controls"
        handleButton.addTarget(self, action: #selector(toggleCollapsed), for: .touchUpInside)
        addSubview(handleButton)

        let moveGesture = UIPanGestureRecognizer(target: self, action: #selector(moveMenu(_:)))
        handleButton.addGestureRecognizer(moveGesture)

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        addSubview(scrollView)

        buttonStack.axis = .horizontal
        buttonStack.alignment = .fill
        buttonStack.spacing = 2
        buttonStack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(buttonStack)
        NSLayoutConstraint.activate([
            buttonStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            buttonStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            buttonStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            buttonStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            buttonStack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])

        activity.color = .white
        activity.hidesWhenStopped = true
        activity.isUserInteractionEnabled = false
        addSubview(activity)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    func addButton(_ title: String, target: Any?, action: Selector, hint: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.tintColor = .white
        button.titleLabel?.font = .systemFont(ofSize: title.count > 2 ? 13 : 17, weight: .semibold)
        button.accessibilityLabel = hint
        button.addTarget(target, action: action, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: controlWidth).isActive = true
        buttonStack.addArrangedSubview(button)
        return button
    }

    func showActivity(_ visible: Bool) {
        if visible { activity.startAnimating() } else { activity.stopAnimating() }
    }

    func place(in containerBounds: CGRect, safeAreaInsets: UIEdgeInsets) {
        guard let superview else { return }
        let buttonCount = CGFloat(buttonStack.arrangedSubviews.count)
        let controlsWidth = buttonCount * controlWidth + max(0, buttonCount - 1) * buttonStack.spacing
        let availableWidth = containerBounds.width - safeAreaInsets.left - safeAreaInsets.right - 16
        expandedWidth = max(menuHeight, min(availableWidth, menuHeight + controlsWidth))
        let targetWidth = isCollapsed ? menuHeight : expandedWidth
        if bounds.size != CGSize(width: targetWidth, height: menuHeight) {
            bounds.size = CGSize(width: targetWidth, height: menuHeight)
        }
        if !hasInitialPosition {
            let savedX = UserDefaults.standard.double(forKey: "FloatingMenuX")
            let savedY = UserDefaults.standard.double(forKey: "FloatingMenuY")
            if savedX > 0, savedY > 0 {
                center = CGPoint(x: containerBounds.width * savedX, y: containerBounds.height * savedY)
            } else {
                center = CGPoint(
                    x: containerBounds.maxX - safeAreaInsets.right - menuHeight / 2 - 8,
                    y: containerBounds.minY + safeAreaInsets.top + menuHeight / 2 + 8
                )
            }
            hasInitialPosition = true
        }
        clampToVisibleArea(in: superview)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let handleX = opensToLeft ? bounds.width - menuHeight : 0
        handleButton.frame = CGRect(x: handleX, y: 0, width: menuHeight, height: menuHeight)
        scrollView.frame = CGRect(
            x: opensToLeft ? 0 : menuHeight,
            y: 0,
            width: max(0, bounds.width - menuHeight),
            height: menuHeight
        )
        activity.center = CGPoint(x: handleButton.frame.midX, y: menuHeight / 2)
    }

    @objc private func toggleCollapsed() {
        if isCollapsed, let superview { opensToLeft = center.x > superview.bounds.midX }
        isCollapsed.toggle()
        let width = isCollapsed ? menuHeight : expandedWidth
        handleButton.setImage(UIImage(systemName: isCollapsed ? "line.3.horizontal" : "chevron.left"), for: .normal)
        handleButton.accessibilityLabel = isCollapsed ? "Open controls" : "Collapse controls"
        UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .curveEaseInOut]) {
            self.bounds.size.width = width
            if let superview = self.superview { self.clampToVisibleArea(in: superview) }
            self.layoutIfNeeded()
        }
    }

    @objc private func moveMenu(_ recognizer: UIPanGestureRecognizer) {
        guard let superview else { return }
        let delta = recognizer.translation(in: superview)
        center = CGPoint(x: center.x + delta.x, y: center.y + delta.y)
        recognizer.setTranslation(.zero, in: superview)
        clampToVisibleArea(in: superview)
        if recognizer.state == .ended || recognizer.state == .cancelled {
            UserDefaults.standard.set(center.x / max(1, superview.bounds.width), forKey: "FloatingMenuX")
            UserDefaults.standard.set(center.y / max(1, superview.bounds.height), forKey: "FloatingMenuY")
        }
    }

    private func clampToVisibleArea(in superview: UIView) {
        let safe = superview.bounds.inset(by: superview.safeAreaInsets).insetBy(dx: 6, dy: 6)
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        center.x = min(max(center.x, safe.minX + halfWidth), safe.maxX - halfWidth)
        center.y = min(max(center.y, safe.minY + halfHeight), safe.maxY - halfHeight)
    }
}
