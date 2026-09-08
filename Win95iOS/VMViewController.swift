import AVFoundation
import CryptoKit
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
    private var sharedServer: SharedFolderServer!
    private lazy var physicalKeyboard = PhysicalKeyboardInput { [weak self] key, pressed in
        self?.bridge.sendKey(key, pressed: pressed)
    }
    private var bridge: Win95CoreBridge!
    private var audio: AudioOutput!
    private var displayLink: CADisplayLink?
    private var frameGeneration: UInt64 = 0
    private var scrollRemainder: CGFloat = 0
    private var displayPinchActive = false
    private var lastDisplayPinchLocation: CGPoint?
    private var touchDragActive = false
    private weak var physicalMouse: GCMouse?
    private var pendingImport: ImportKind = .disk
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var activeCDURLs: [URL?] = Array(repeating: nil, count: 3)
    private var activeDiskURL: URL?
    private var manuallyPaused = false
    private var resumeAfterForeground = false
    private var pauseGeneration = 0
    private var isChangingCD = false
    private var isExportingDisk = false
    private weak var pauseButton: UIButton?
    private weak var cdLibraryController: CDLibraryViewController?
    private weak var sharedFilesController: SharedFilesViewController?
    private var sharedServerStatus = "起動中…"

    private enum ImportKind { case disk, cd, shared }

    private lazy var supportDirectory: URL = {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return root.appendingPathComponent("Win9x", isDirectory: true)
    }()
    private var legacySupportDirectories: [URL] {
        let fileManager = FileManager.default
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return [
            documents.appendingPathComponent("Win95", isDirectory: true),
            applicationSupport.appendingPathComponent("Win9x", isDirectory: true),
            applicationSupport.appendingPathComponent("Win95", isDirectory: true)
        ]
    }
    private var savesDirectory: URL { supportDirectory.appendingPathComponent("Saves", isDirectory: true) }
    private var systemDirectory: URL { supportDirectory.appendingPathComponent("System", isDirectory: true) }
    private var cdDirectory: URL { supportDirectory.appendingPathComponent("CDs", isDirectory: true) }
    private var sharedDirectory: URL { supportDirectory.appendingPathComponent("Shared", isDirectory: true) }
    private var exportsDirectory: URL { supportDirectory.appendingPathComponent("Exports", isDirectory: true) }
    private var suspendStateURL: URL { savesDirectory.appendingPathComponent("automatic-suspend.state") }
    private let selectedCDKey = "SelectedCDImageName"
    private let selectedCDsKey = "SelectedCDImageNamesByDrive"
    private let cdImageOrderKey = "CDImageOrder"
    private let cdMountInProgressKey = "CDMountInProgress"
    private let cdMountStateVersionKey = "CDMountStateVersion"
    private let suspendCompatibilityKey = "SuspendStorageBackendVersion"
    private let suspendCompatibilityVersion = 7
    private let baseDiskIdentityKey = "BaseDiskSampleIdentity"
    private let baseDiskIdentityVersionKey = "BaseDiskSampleIdentityVersion"
    private let baseDiskIdentityVersion = 1
    private let cdDriveCount = 3
    private let cdDriveLetters = ["D", "E", "F"]
    private let baseDiskStem = "win-base"
    private let legacyBaseDiskStem = "win95-base"
    private let baseSaveStem = "win-base-CDRIVE"
    private let legacyBaseSaveStem = "win95-base-CDRIVE"
    private var recoveredFromInterruptedCDMount = false
    private var importedDiskURLs: [URL] {
        var disks: [URL] = []
        for ext in ["img", "vhd"] {
            let url = supportDirectory.appendingPathComponent(baseDiskStem).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) { disks.append(url) }
        }
        return disks
    }
    private var packagedDiskURLs: [URL] {
        for stem in [baseDiskStem, legacyBaseDiskStem] {
            var disks: [URL] = []
            for ext in ["img", "vhd"] {
                if let url = Bundle.main.url(
                    forResource: stem,
                    withExtension: ext,
                    subdirectory: "BundledContent"
                ) {
                    disks.append(url)
                }
            }
            if !disks.isEmpty { return disks }
        }
        return []
    }
    private var packagedDiskURL: URL? {
        let disks = packagedDiskURLs
        return disks.count == 1 ? disks[0] : nil
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.04, alpha: 1)
        createDirectories()
        sharedServer = SharedFolderServer(directory: sharedDirectory)
        sharedServer.onStatusChanged = { [weak self] status in
            self?.sharedServerStatus = status
            self?.refreshSharedFiles(busy: false)
        }
        sharedServer.onFilesChanged = { [weak self] in self?.refreshSharedFiles(busy: false) }
        sharedServer.start()
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
        sharedServer?.stop()
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
           let legacyDirectory = legacySupportDirectories.first(where: {
               fileManager.fileExists(atPath: $0.path)
           }) {
            do { try fileManager.moveItem(at: legacyDirectory, to: supportDirectory) }
            catch { NSLog("Could not migrate Windows 9x data into Documents: %@", error.localizedDescription) }
        }
        try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        migrateLegacyBaseDiskName()
        try? fileManager.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        migrateLegacySaveNames()
        try? FileManager.default.createDirectory(at: systemDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cdDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
        if let unfinished = try? FileManager.default.contentsOfDirectory(
            at: exportsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for url in unfinished where url.pathExtension == "partial" { try? fileManager.removeItem(at: url) }
        }
        try? FileManager.default.removeItem(at: suspendStateURL.appendingPathExtension("partial"))
    }

    private func migrateLegacyBaseDiskName() {
        let fileManager = FileManager.default
        for ext in ["img", "vhd"] {
            let legacy = supportDirectory
                .appendingPathComponent(legacyBaseDiskStem)
                .appendingPathExtension(ext)
            let current = supportDirectory
                .appendingPathComponent(baseDiskStem)
                .appendingPathExtension(ext)
            guard fileManager.fileExists(atPath: legacy.path),
                  !fileManager.fileExists(atPath: current.path) else { continue }
            do { try fileManager.moveItem(at: legacy, to: current) }
            catch { NSLog("Could not rename the legacy base disk: %@", error.localizedDescription) }
        }
    }

    private func migrateLegacySaveNames() {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: savesDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for legacy in files {
            let name = legacy.lastPathComponent
            guard name.hasPrefix(legacyBaseSaveStem), name.contains(".sav"),
                  (try? legacy.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let suffix = name.dropFirst(legacyBaseSaveStem.count)
            let current = savesDirectory.appendingPathComponent(baseSaveStem + suffix)
            guard !fileManager.fileExists(atPath: current.path) else { continue }
            do { try fileManager.moveItem(at: legacy, to: current) }
            catch { NSLog("Could not rename the legacy HDD save: %@", error.localizedDescription) }
        }
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
        toolbar.addButton("CD", target: self, action: #selector(showCDMenu), hint: "CD images")
        toolbar.addButton("共有", target: self, action: #selector(showSharedFiles), hint: "Windowsとのファイル共有")
        let resetZoomButton = toolbar.addButton("", target: self, action: #selector(resetDisplayZoom), hint: "画面を元の拡大率に戻す")
        resetZoomButton.setImage(UIImage(systemName: "arrow.down.right.and.arrow.up.left"), for: .normal)
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

        let toolbarVisibilityTap = UITapGestureRecognizer(target: self, action: #selector(toggleToolbarVisibility(_:)))
        toolbarVisibilityTap.numberOfTouchesRequired = 3
        toolbarVisibilityTap.allowedTouchTypes = directTouchTypes
        toolbarVisibilityTap.delegate = self
        displayView.addGestureRecognizer(toolbarVisibilityTap)

        let displayPinch = UIPinchGestureRecognizer(target: self, action: #selector(zoomDisplay(_:)))
        displayPinch.delegate = self
        displayView.addGestureRecognizer(displayPinch)

        let pausedToolbarVisibilityTap = UITapGestureRecognizer(target: self, action: #selector(toggleToolbarVisibility(_:)))
        pausedToolbarVisibilityTap.numberOfTouchesRequired = 3
        pausedToolbarVisibilityTap.allowedTouchTypes = directTouchTypes
        pausedToolbarVisibilityTap.delegate = self
        pauseOverlay.addGestureRecognizer(pausedToolbarVisibilityTap)

        let pausedDisplayPinch = UIPinchGestureRecognizer(target: self, action: #selector(zoomDisplay(_:)))
        pausedDisplayPinch.delegate = self
        pauseOverlay.addGestureRecognizer(pausedDisplayPinch)

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
        let initialCDs = recoverablePersistedCDURLs
        let importedDisks = importedDiskURLs
        guard importedDisks.count <= 1 else {
            showMissingDisk()
            showBaseDiskConflict(importedDisks)
            return
        }
        if let importedDiskURL = importedDisks.first {
            makeBaseDiskUserEditable(at: importedDiskURL)
            startVM(disk: importedDiskURL, CDs: initialCDs)
            return
        }
        guard packagedDiskURLs.count <= 1 else {
            showMissingDisk()
            showBaseDiskConflict(packagedDiskURLs, isPackaged: true)
            return
        }
        guard let packagedDiskURL else {
            showMissingDisk()
            return
        }

        // An app bundle is signed and read-only. Expand a packaged HDD into
        // Documents once so it appears in Files and can be replaced by the user.
        showMissingDisk()
        diskSetupView.setBusy(true, title: "同梱イメージを準備中…")
        let destination = supportDirectory
            .appendingPathComponent(baseDiskStem)
            .appendingPathExtension(packagedDiskURL.pathExtension.lowercased())
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                try self.installPackagedDisk(from: packagedDiskURL, to: destination)
                DispatchQueue.main.async { [weak self] in
                    self?.startVM(disk: destination, CDs: initialCDs)
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.diskSetupView.setBusy(false)
                    self.showError(error)
                }
            }
        }
    }

    private func showBaseDiskConflict(_ disks: [URL], isPackaged: Bool = false) {
        let names = disks.map(\.lastPathComponent).joined(separator: " / ")
        let recovery = isPackaged
            ? "IPAのBundledContentにはIMGかVHDのどちらか1つだけを入れて、ビルドし直してください。"
            : "ファイルAppで使用しない方を別の場所へ移動してから、アプリを開き直してください。"
        DispatchQueue.main.async { [weak self] in
            self?.showError(NSError(
                domain: "Win95UI",
                code: 14,
                userInfo: [NSLocalizedDescriptionKey: "HDDイメージが複数あります（\(names)）。誤ったHDDで起動しないよう停止しました。\(recovery)"]
            ))
        }
    }

    private func installPackagedDisk(from source: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        // Documents always wins during an app update. Never replace a base HDD
        // that appeared after the startup check (for example through Files).
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        let temporary = supportDirectory.appendingPathComponent("packaged-base.partial")
        if fileManager.fileExists(atPath: temporary.path) {
            try fileManager.removeItem(at: temporary)
        }
        defer { try? fileManager.removeItem(at: temporary) }
        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.path)
        try fileManager.moveItem(at: temporary, to: destination)
    }

    private func makeBaseDiskUserEditable(at url: URL) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } catch {
            NSLog("Could not make the base disk editable in Files: %@", error.localizedDescription)
        }
    }

    private var persistedCDImageNames: [String] {
        let defaults = UserDefaults.standard
        var needsSave = false
        var names: [String]
        if let savedNames = defaults.stringArray(forKey: selectedCDsKey) {
            names = Array((savedNames + Array(repeating: "", count: cdDriveCount)).prefix(cdDriveCount))
            needsSave = savedNames.count != cdDriveCount
        } else {
            names = Array(repeating: "", count: cdDriveCount)
        }
        if defaults.object(forKey: selectedCDsKey) == nil,
           let legacy = defaults.string(forKey: selectedCDKey) {
            names[0] = legacy
            needsSave = true
        }
        var seen = Set<String>()
        for index in names.indices where !names[index].isEmpty {
            if !seen.insert(names[index]).inserted {
                names[index] = ""
                needsSave = true
            }
        }
        if needsSave {
            defaults.set(names, forKey: selectedCDsKey)
            defaults.removeObject(forKey: selectedCDKey)
            defaults.synchronize()
        }
        return names
    }

    private var recoverablePersistedCDURLs: [URL?] {
        let defaults = UserDefaults.standard
        // Retry selections from the old DOS mount backend using the new ATAPI
        // backend. Only an interrupted operation on this backend gets a safe boot.
        if defaults.bool(forKey: cdMountInProgressKey) && defaults.integer(forKey: cdMountStateVersionKey) >= 3 {
            defaults.removeObject(forKey: cdMountInProgressKey)
            defaults.synchronize()
            recoveredFromInterruptedCDMount = true
            return Array(repeating: nil, count: cdDriveCount)
        }
        return persistedCDImageNames.map { name in
            guard !name.isEmpty, !name.contains("/"), !name.contains("\\") else { return nil }
            let url = cdDirectory.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }

    private func startVM(disk: URL, CDs: [URL?], restoreSuspendState: Bool = true) {
        do {
            try preserveIncompatibleSuspendState()
            try prepareStorageForBaseDisk(disk)
            let requestedNames = persistedCDImageNames.filter { !$0.isEmpty }
            if CDs.compactMap({ $0 }).count < requestedNames.count {
                try archiveSuspendState(reason: "media-unavailable")
            }
            let save = savesDirectory.appendingPathComponent(baseSaveStem).appendingPathExtension("sav")
            if FileManager.default.fileExists(atPath: save.path) {
                let handle = try FileHandle(forReadingFrom: save)
                defer { try? handle.close() }
                guard try handle.read(upToCount: 5) == Data([70, 70, 68, 68, 1]) else {
                    throw NSError(domain: "Win95UI", code: 8, userInfo: [NSLocalizedDescriptionKey: "Saves/win-base-CDRIVE.sav のヘッダーが壊れているため起動を中止しました。原本は保持しています。ファイルアプリでバックアップしてから、同じベースイメージに対応する保存データを戻してください。"])
                }
            }
        } catch { diskSetupView.setBusy(false); showError(error); return }
        activeDiskURL = disk
        activeCDURLs = Array(repeating: nil, count: cdDriveCount)
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
            // Restore all ATAPI media before loading a suspend state that can
            // contain requests in flight for D:, E: or F:.
            func restoreCD(at driveIndex: Int) {
                guard driveIndex < self.cdDriveCount else {
                    finishStartup()
                    return
                }
                guard CDs.indices.contains(driveIndex), let CD = CDs[driveIndex] else {
                    restoreCD(at: driveIndex + 1)
                    return
                }
                self.changeCD(to: CD, driveIndex: driveIndex, automatic: true) {
                    restoreCD(at: driveIndex + 1)
                }
            }
            restoreCD(at: 0)
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
        guard defaults.integer(forKey: suspendCompatibilityKey) < suspendCompatibilityVersion else { return }
        // Preserve states created before the corrected VM86 segment-cache or
        // the three-drive IDE topology; both change serialized core state.
        try archiveSuspendState(reason: "previous-core-topology")
        defaults.set(suspendCompatibilityVersion, forKey: suspendCompatibilityKey)
    }

    private func prepareStorageForBaseDisk(_ disk: URL) throws {
        let identity = try sampledIdentity(of: disk)
        let defaults = UserDefaults.standard
        let previousIdentity = defaults.string(forKey: baseDiskIdentityKey)
        let identityIsKnown = defaults.integer(forKey: baseDiskIdentityVersionKey) >= baseDiskIdentityVersion
        let save = savesDirectory.appendingPathComponent(baseSaveStem).appendingPathExtension("sav")

        if !identityIsKnown {
            // This can be an update from a version that predates disk identity
            // metadata. Existing user data takes precedence over an IPA seed.
            if !FileManager.default.fileExists(atPath: save.path),
               let bundledSave = try bundledSaveURL(for: disk, identity: identity) {
                try validateDiskSave(at: bundledSave)
                try installBundledSave(from: bundledSave, to: save)
            }
        } else if previousIdentity != identity {
            let bundledSave = try bundledSaveURL(for: disk, identity: identity)
            if let bundledSave { try validateDiskSave(at: bundledSave) }
            let reason = "previous-base-image"
            if FileManager.default.fileExists(atPath: save.path) {
                let backup = savesDirectory.appendingPathComponent(
                    "\(baseSaveStem).\(reason)-\(UUID().uuidString).sav"
                )
                try FileManager.default.moveItem(at: save, to: backup)
            }
            try archiveSuspendState(reason: reason)
            if let bundledSave { try installBundledSave(from: bundledSave, to: save) }
        }

        defaults.set(identity, forKey: baseDiskIdentityKey)
        defaults.set(baseDiskIdentityVersion, forKey: baseDiskIdentityVersionKey)
    }

    private func bundledSaveURL(for disk: URL, identity: String) throws -> URL? {
        let save = Bundle.main.url(
            forResource: baseSaveStem,
            withExtension: "sav",
            subdirectory: "BundledContent"
        ) ?? Bundle.main.url(
            forResource: legacyBaseSaveStem,
            withExtension: "sav",
            subdirectory: "BundledContent"
        )
        guard let save, let packagedDiskURL else { return nil }

        let selectedDisk = disk.standardizedFileURL.resolvingSymlinksInPath()
        let packagedDisk = packagedDiskURL.standardizedFileURL.resolvingSymlinksInPath()
        if selectedDisk == packagedDisk { return save }

        let expectedCopy = supportDirectory
            .appendingPathComponent(baseDiskStem)
            .appendingPathExtension(packagedDiskURL.pathExtension.lowercased())
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard selectedDisk == expectedCopy else { return nil }

        // Only pair the packaged overlay with an unchanged Documents copy of
        // its base disk. A user-replaced image must start with a fresh overlay.
        guard try sampledIdentity(of: packagedDiskURL) == identity else {
            return nil
        }
        return save
    }

    private func validateDiskSave(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let header = try handle.read(upToCount: 5)
        guard header == Data([70, 70, 68, 68, 1]), size >= 5, (size - 5) % 516 == 0 else {
            throw NSError(
                domain: "Win95UI",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "同梱された win-base-CDRIVE.sav は有効なFFDD v1差分ディスクではありません。ビルド設定のHDDと保存データを確認してください。"]
            )
        }
    }

    private func installBundledSave(from source: URL, to destination: URL) throws {
        // A packaged save is a first-install seed only. Existing user data is
        // never replaced when installing an updated IPA.
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let temporary = savesDirectory.appendingPathComponent("bundled-save-\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private func sampledIdentity(of disk: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: disk)
        defer { try? handle.close() }
        let attributes = try FileManager.default.attributesOfItem(atPath: disk.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        var littleEndianSize = size.littleEndian
        var hasher = SHA256()
        withUnsafeBytes(of: &littleEndianSize) { hasher.update(data: Data($0)) }

        let sampleSize = UInt64(64 * 1024)
        let lastOffset = size > sampleSize ? size - sampleSize : 0
        let offsets = Set([UInt64(0), size / 4, size / 2, (size / 4) * 3, lastOffset]).sorted()
        for offset in offsets {
            var littleEndianOffset = offset.littleEndian
            withUnsafeBytes(of: &littleEndianOffset) { hasher.update(data: Data($0)) }
            try handle.seek(toOffset: offset)
            hasher.update(data: try handle.read(upToCount: Int(sampleSize)) ?? Data())
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
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

    private func presentSharedFilePicker(from presenter: UIViewController) {
        pendingImport = .shared
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data], asCopy: false)
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
                if bridge.isRunning {
                    audio.stop()
                    bridge.stop { [weak self] in self?.replaceBaseDisk(from: source, fileExtension: ext) }
                } else {
                    replaceBaseDisk(from: source, fileExtension: ext)
                }
            } catch {
                diskSetupView.setBusy(false)
                showError(error)
            }
        case .cd:
            importCDImages(urls)
        case .shared:
            importSharedFiles(urls)
        }
    }

    private func replaceBaseDisk(from source: URL, fileExtension ext: String) {
        do {
            for stem in [baseDiskStem, legacyBaseDiskStem] {
                for oldExtension in ["img", "vhd"] {
                    let oldURL = supportDirectory.appendingPathComponent(stem).appendingPathExtension(oldExtension)
                    if FileManager.default.fileExists(atPath: oldURL.path) {
                        try FileManager.default.removeItem(at: oldURL)
                    }
                }
            }
            let destination = supportDirectory.appendingPathComponent(baseDiskStem).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            startVM(disk: destination, CDs: Array(repeating: nil, count: cdDriveCount), restoreSuspendState: false)
        } catch {
            diskSetupView.setBusy(false)
            showError(error)
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
            var importedImages: [URL] = []
            var failures: [String] = []
            for source in sources {
                do {
                    guard self.isMountableCD(source) else {
                        throw NSError(
                            domain: "Win95UI",
                            code: 5,
                            userInfo: [NSLocalizedDescriptionKey: "対応形式は ISO・CUE・CHD・IMG です。"]
                        )
                    }
                    let destination = self.uniqueDestination(for: source, in: destinationDirectory)
                    try self.copyLargeFile(from: source, to: destination)
                    importedImages.append(destination)
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.appendToCDImageOrder(importedImages)
                self.toolbar.showActivity(false)
                self.refreshCDLibrary(busy: false)
                if !failures.isEmpty {
                    let details = failures.prefix(4).joined(separator: "\n")
                    let remaining = failures.count - min(failures.count, 4)
                    let suffix = remaining > 0 ? "\nほか \(remaining) 件" : ""
                    self.showError(NSError(
                        domain: "Win95UI",
                        code: 7,
                        userInfo: [NSLocalizedDescriptionKey: "一部のCDイメージを追加できませんでした。\n\(details)\(suffix)"]
                    ))
                }
            }
        }
    }

    private func importSharedFiles(_ sources: [URL]) {
        guard !sources.isEmpty else { return }
        toolbar.showActivity(true)
        refreshSharedFiles(busy: true)
        let destinationDirectory = sharedDirectory
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var failures: [String] = []
            for source in sources {
                do {
                    let destination = self.uniqueDestination(for: source, in: destinationDirectory)
                    try self.copyLargeFile(from: source, to: destination, validateISOImage: false)
                } catch {
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.toolbar.showActivity(false)
                self.refreshSharedFiles(busy: false)
                if !failures.isEmpty {
                    let details = failures.prefix(4).joined(separator: "\n")
                    let remaining = failures.count - min(failures.count, 4)
                    let suffix = remaining > 0 ? "\nほか \(remaining) 件" : ""
                    self.showError(NSError(
                        domain: "Win95UI",
                        code: 11,
                        userInfo: [NSLocalizedDescriptionKey: "一部の共有ファイルを追加できませんでした。\n\(details)\(suffix)"]
                    ))
                }
            }
        }
    }

    private func copyLargeFile(from source: URL, to destination: URL, validateISOImage: Bool = true) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { coordinatedURL in
            do { try streamCopy(from: coordinatedURL, to: destination, validateISOImage: validateISOImage) }
            catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    private func streamCopy(from source: URL, to destination: URL, validateISOImage: Bool) throws {
        let fileManager = FileManager.default
        let sourceSize = Int64(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let volumeValues = try destination.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = volumeValues.volumeAvailableCapacityForImportantUsage,
           available < sourceSize + 64 * 1024 * 1024 {
            throw NSError(
                domain: "Win95UI",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "ファイルを保存する空き容量が不足しています。"]
            )
        }

        let partial = destination.appendingPathExtension("partial")
        if fileManager.fileExists(atPath: partial.path) { try fileManager.removeItem(at: partial) }
        guard fileManager.createFile(atPath: partial.path, contents: nil) else {
            throw NSError(domain: "Win95UI", code: 4, userInfo: [NSLocalizedDescriptionKey: "ファイルの保存先を作成できません。"])
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
                    userInfo: [NSLocalizedDescriptionKey: "ファイルを最後まで読み込めませんでした。"]
                )
            }
            if validateISOImage && destination.pathExtension.lowercased() == "iso" { try validateISO(at: partial) }
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
            existing.reload(images: storedCDImages, activeURLs: activeCDURLs, busy: false)
            return
        }

        let library = CDLibraryViewController(images: storedCDImages, activeURLs: activeCDURLs)
        library.onAdd = { [weak self, weak library] in
            guard let self, let library else { return }
            self.presentCDPicker(from: library)
        }
        library.onMount = { [weak self] url, driveIndex in self?.mountCD(url, driveIndex: driveIndex) }
        library.onEject = { [weak self] driveIndex in self?.ejectCD(driveIndex: driveIndex) }
        library.onDelete = { [weak self] url in self?.confirmDeleteCD(url) }
        library.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        cdLibraryController = library

        let navigation = UINavigationController(rootViewController: library)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    @objc private func showSharedFiles() {
        sharedServer.start()
        if let existing = sharedFilesController {
            existing.reload(files: storedSharedFiles, serverStatus: sharedServerStatus, busy: false)
            return
        }

        let controller = SharedFilesViewController(files: storedSharedFiles, serverStatus: sharedServerStatus)
        controller.onAdd = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.presentSharedFilePicker(from: controller)
        }
        controller.onOpenInWindows = { [weak self] in
            self?.dismiss(animated: true) { [weak self] in self?.openSharedPageInWindows() }
        }
        controller.onShare = { [weak self] url, source in self?.shareSharedFile(url, source: source) }
        controller.onDelete = { [weak self] url in self?.confirmDeleteSharedFile(url) }
        controller.onExportMergedDisk = { [weak self] in self?.confirmExportMergedDisk() }
        controller.onDismiss = { [weak self] in self?.dismiss(animated: true) }
        sharedFilesController = controller

        let navigation = UINavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .formSheet
        present(navigation, animated: true)
    }

    private func openSharedPageInWindows() {
        guard sharedServerStatus == "使用できます" else {
            showError(NSError(
                domain: "Win95UI",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "共有サーバーの準備ができていません。共有画面の状態を確認してから、もう一度実行してください。"]
            ))
            return
        }
        guard bridge.isRunning, !bridge.isPaused else {
            showError(NSError(
                domain: "Win95UI",
                code: 12,
                userInfo: [NSLocalizedDescriptionKey: "Windowsを起動し、一時停止を解除してから実行してください。"]
            ))
            return
        }
        keyboardCapture.releaseModifiers()
        physicalKeyboard.releaseAll()
        bridge.sendKey(RetroKey.leftSuper, pressed: true)
        bridge.sendKey(114, pressed: true) // R
        bridge.sendKey(114, pressed: false)
        bridge.sendKey(RetroKey.leftSuper, pressed: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.bridge.isRunning, !self.bridge.isPaused else { return }
            self.keyboardCapture.sendASCIIText(SharedFolderServer.guestURL) { [weak self] in
                guard let self, self.bridge.isRunning, !self.bridge.isPaused else { return }
                self.bridge.sendKey(RetroKey.enter, pressed: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    guard let self, self.bridge.isRunning, !self.bridge.isPaused else { return }
                    self.bridge.sendKey(RetroKey.enter, pressed: false)
                }
            }
        }
    }

    private var storedSharedFiles: [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        return ((try? FileManager.default.contentsOfDirectory(
            at: sharedDirectory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        )) ?? []).filter {
            (try? $0.resourceValues(forKeys: Set(keys)).isRegularFile) == true
        }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func refreshSharedFiles(busy: Bool) {
        sharedFilesController?.reload(files: storedSharedFiles, serverStatus: sharedServerStatus, busy: busy || isExportingDisk)
    }

    private func confirmExportMergedDisk() {
        guard let presenter = sharedFilesController, bridge.isRunning, !isChangingCD, !isExportingDisk else {
            showError(NSError(
                domain: "Win95UI",
                code: 15,
                userInfo: [NSLocalizedDescriptionKey: "Windowsが起動してCD交換などの処理が終わってから、もう一度実行してください。"]
            ))
            return
        }
        let alert = UIAlertController(
            title: "現在のHDDを統合しますか？",
            message: "ベースイメージとSaves内の差分を統合した、他の仮想マシンへ移行できるraw IMGを新しく作成します。元のHDDとsavは変更しません。HDD全容量ぶんの空き領域が必要です。完了までアプリを画面に表示したままにしてください。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "統合IMGを作成", style: .default) { [weak self] _ in
            self?.exportMergedDisk()
        })
        presenter.present(alert, animated: true)
    }

    private func exportMergedDisk() {
        guard bridge.isRunning, !isExportingDisk else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let destination = exportsDirectory
            .appendingPathComponent("win-merged-\(formatter.string(from: Date()))")
            .appendingPathExtension("img")
        let temporary = destination.appendingPathExtension("partial")
        do {
            try FileManager.default.createDirectory(at: exportsDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: temporary)
        } catch {
            showError(error)
            return
        }

        let wasPaused = bridge.isPaused
        if !wasPaused {
            keyboardCapture.dismissKeyboard()
            keyboardCapture.releaseModifiers()
            physicalKeyboard.releaseAll()
            touchDragActive = false
            bridge.setLeftMouseButton(false)
            bridge.setRightMouseButton(false)
            audio.stop()
            bridge.setEmulationPaused(true)
        }
        isExportingDisk = true
        sharedFilesController?.isModalInPresentation = true
        sharedFilesController?.navigationController?.isModalInPresentation = true
        refreshSharedFiles(busy: true)
        bridge.exportMergedDisk(to: temporary) { [weak self] error in
            guard let self else { return }
            var finalError: Error? = error
            if finalError == nil {
                do {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                } catch {
                    finalError = error
                }
            }
            if finalError != nil { try? FileManager.default.removeItem(at: temporary) }

            self.isExportingDisk = false
            self.sharedFilesController?.isModalInPresentation = false
            self.sharedFilesController?.navigationController?.isModalInPresentation = false
            self.refreshSharedFiles(busy: false)
            if !wasPaused {
                if UIApplication.shared.applicationState == .active {
                    self.resumeAfterForeground = false
                    self.bridge.setEmulationPaused(false)
                    self.startAudioIfNeeded()
                } else {
                    self.resumeAfterForeground = true
                }
            }
            self.updatePausedAppearance(saving: false)

            if let finalError {
                self.showError(finalError)
            } else {
                self.shareSharedFile(destination, source: nil)
            }
        }
    }

    private func shareSharedFile(_ url: URL, source: UIView?) {
        guard FileManager.default.fileExists(atPath: url.path), let presenter = sharedFilesController else { return }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = source ?? presenter.view
            popover.sourceRect = source?.bounds ?? CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        presenter.present(activity, animated: true)
    }

    private func confirmDeleteSharedFile(_ url: URL) {
        guard let presenter = sharedFilesController else { return }
        let alert = UIAlertController(
            title: "共有ファイルを削除しますか？",
            message: url.lastPathComponent,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "削除", style: .destructive) { [weak self] _ in
            do {
                try FileManager.default.removeItem(at: url)
                self?.refreshSharedFiles(busy: false)
            } catch {
                self?.showError(error)
            }
        })
        presenter.present(alert, animated: true)
    }

    private func refreshCDLibrary(busy: Bool) {
        let images = storedCDImages
        persistCDImageOrder(images)
        cdLibraryController?.reload(images: images, activeURLs: activeCDURLs, busy: busy)
    }

    private var storedCDImages: [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: cdDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let mountable = urls.filter(isMountableCD)
        let byName = Dictionary(uniqueKeysWithValues: mountable.map { ($0.lastPathComponent, $0) })
        let savedOrder = UserDefaults.standard.stringArray(forKey: cdImageOrderKey) ?? []
        let ordered = savedOrder.compactMap { byName[$0] }
        let orderedNames = Set(ordered.map(\.lastPathComponent))
        let unlisted = mountable.filter { !orderedNames.contains($0.lastPathComponent) }.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        return ordered + unlisted
    }

    private func persistCDImageOrder(_ images: [URL]) {
        UserDefaults.standard.set(images.map(\.lastPathComponent), forKey: cdImageOrderKey)
    }

    private func appendToCDImageOrder(_ images: [URL]) {
        guard !images.isEmpty else { return }
        let importedNames = Set(images.map(\.lastPathComponent))
        var ordered = storedCDImages.filter { !importedNames.contains($0.lastPathComponent) }
        ordered.append(contentsOf: images)
        persistCDImageOrder(ordered)
    }

    private func isMountableCD(_ url: URL) -> Bool {
        ["iso", "cue", "chd", "img"].contains(url.pathExtension.lowercased())
    }

    private func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let fileManager = FileManager.default
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

    private func mountCD(_ url: URL, driveIndex: Int) {
        guard activeCDURLs.indices.contains(driveIndex) else { return }
        if let mountedDrive = activeCDURLs.indices.first(where: {
            $0 != driveIndex && activeCDURLs[$0] == url
        }) {
            showError(NSError(
                domain: "Win95UI",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "このCDはすでに\(cdDriveLetters[mountedDrive]):ドライブに挿入されています。別のドライブへ挿入する場合は、先に\(cdDriveLetters[mountedDrive]):ドライブから取り出してください。"]
            ))
            return
        }
        if url.pathExtension.lowercased() == "iso" {
            do { try validateISO(at: url) }
            catch { showError(error); return }
        }
        changeCD(to: url, driveIndex: driveIndex)
    }

    private func ejectCD(driveIndex: Int) {
        guard activeCDURLs.indices.contains(driveIndex) else { return }
        changeCD(to: nil, driveIndex: driveIndex)
    }

    private func changeCD(to CD: URL?, driveIndex: Int, automatic: Bool = false, afterChange: (() -> Void)? = nil) {
        guard activeCDURLs.indices.contains(driveIndex) else { return }
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
            var continueAfterChange = false
            if let error {
                if automatic {
                    // Preserve the library selection so a temporary file error
                    // does not silently forget the user's CD on the next launch.
                    do { try self.archiveSuspendState(reason: "media-unavailable") }
                    catch { self.showError(error) }
                    continueAfterChange = true
                }
                self.showError(error)
            } else {
                self.activeCDURLs[driveIndex] = CD
                if !automatic {
                    let names = self.activeCDURLs.map { $0?.lastPathComponent ?? "" }
                    defaults.set(names, forKey: self.selectedCDsKey)
                    defaults.removeObject(forKey: self.selectedCDKey)
                }
                defaults.set(3, forKey: self.cdMountStateVersionKey)
                defaults.synchronize()
                continueAfterChange = true
            }
            self.refreshCDLibrary(busy: false)
            if continueAfterChange { afterChange?() }
        }
        let bridgeDriveIndex = UInt(driveIndex)
        if let CD { bridge.mountCD(at: CD, driveIndex: bridgeDriveIndex, completion: completion) }
        else { bridge.ejectCD(at: bridgeDriveIndex, completion: completion) }
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
            do {
                try FileManager.default.removeItem(at: url)
                self.persistCDImageOrder(self.storedCDImages.filter { $0 != url })
                let defaults = UserDefaults.standard
                let names = self.persistedCDImageNames.map { $0 == url.lastPathComponent ? "" : $0 }
                defaults.set(names, forKey: self.selectedCDsKey)
                defaults.synchronize()
            }
            catch { self.showError(error) }
            self.refreshCDLibrary(busy: false)
        }
        let mountedDriveIndices = activeCDURLs.indices.filter { activeCDURLs[$0] == url }
        ejectCDs(at: mountedDriveIndices[...], completion: removeFile)
    }

    private func ejectCDs(at driveIndices: ArraySlice<Int>, completion: @escaping () -> Void) {
        guard let driveIndex = driveIndices.first else {
            completion()
            return
        }
        changeCD(to: nil, driveIndex: driveIndex) { [weak self] in
            self?.ejectCDs(at: driveIndices.dropFirst(), completion: completion)
        }
    }

    @objc private func showKeyboard() {
        if keyboardCapture.isFirstResponder { keyboardCapture.dismissKeyboard() }
        else { keyboardCapture.becomeFirstResponder() }
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

    @objc private func toggleToolbarVisibility(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let shouldShow = toolbar.isHidden
        if shouldShow {
            toolbar.isHidden = false
            toolbar.alpha = 0
            toolbar.transform = CGAffineTransform(scaleX: 0.86, y: 0.86)
        }
        UIView.animate(
            withDuration: 0.18,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseInOut],
            animations: {
                self.toolbar.alpha = shouldShow ? 1 : 0
                self.toolbar.transform = shouldShow ? .identity : CGAffineTransform(scaleX: 0.86, y: 0.86)
            },
            completion: { _ in
                self.toolbar.isHidden = !shouldShow
                if !shouldShow { self.toolbar.transform = .identity }
            }
        )
        UISelectionFeedbackGenerator().selectionChanged()
    }

    @objc private func scrollMouse(_ recognizer: UIPanGestureRecognizer) {
        if displayPinchActive {
            recognizer.setTranslation(.zero, in: displayView)
            scrollRemainder = 0
            return
        }
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
        if pair.contains(where: { $0 is UIPinchGestureRecognizer }) &&
            pair.contains(where: { $0 is UIPanGestureRecognizer && ($0 as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 2 }) {
            return true
        }
        return pair.contains { $0 is UILongPressGestureRecognizer } &&
            pair.contains { $0 is UIPanGestureRecognizer && ($0 as? UIPanGestureRecognizer)?.maximumNumberOfTouches == 1 }
    }

    @objc private func zoomDisplay(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: displayView)
        switch recognizer.state {
        case .began:
            displayPinchActive = true
            lastDisplayPinchLocation = location
            displayView.adjustZoom(by: recognizer.scale, around: location)
            recognizer.scale = 1
        case .changed:
            displayPinchActive = true
            displayView.adjustZoom(by: recognizer.scale, around: location)
            if let previous = lastDisplayPinchLocation {
                displayView.panZoom(by: CGPoint(x: location.x - previous.x, y: location.y - previous.y))
            }
            lastDisplayPinchLocation = location
            recognizer.scale = 1
        case .ended, .cancelled, .failed:
            displayPinchActive = false
            lastDisplayPinchLocation = nil
            scrollRemainder = 0
        default:
            break
        }
    }

    @objc private func resetDisplayZoom() {
        displayView.resetZoom()
        UISelectionFeedbackGenerator().selectionChanged()
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
        guard bridge.isRunning, !isChangingCD, presentedViewController == nil else { return }
        let alert = UIAlertController(
            title: "Windowsを強制再起動しますか？",
            message: "保存していないWindows上の作業は失われる可能性があります。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        alert.addAction(UIAlertAction(title: "再起動", style: .destructive) { [weak self] _ in
            self?.performResetVM()
        })
        present(alert, animated: true)
    }

    private func performResetVM() {
        guard bridge.isRunning, !isChangingCD else { return }
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
        if isExportingDisk {
            resumeAfterForeground = true
            return
        }
        if resumeAfterForeground {
            resumeAfterForeground = false
            bridge.setEmulationPaused(false)
            updatePausedAppearance(saving: false)
            startAudioIfNeeded()
        } else {
            updatePausedAppearance(saving: false)
        }
    }
    @objc private func appDidBecomeActive() {
        becomeFirstResponder()
        refreshSharedFiles(busy: false)
    }

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
        let alert = UIAlertController(title: "エラー", message: error.localizedDescription, preferredStyle: .alert)
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
        titleLabel.text = "Windows 9x イメージを選択"
        titleLabel.textColor = .white
        titleLabel.font = .systemFont(ofSize: 27, weight: .bold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let descriptionLabel = UILabel()
        descriptionLabel.text = "セットアップ済みの Windows 95 / 98 / Me が入ったディスクイメージを選択してください。"
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
        selectButton.accessibilityLabel = "Windows 9x ディスクイメージを選択"

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

    func setBusy(_ busy: Bool, title: String? = nil) {
        selectButton.isEnabled = !busy
        var configuration = selectButton.configuration
        configuration?.title = busy ? (title ?? "イメージを読み込み中…") : "イメージを選択"
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
    var onMount: ((URL, Int) -> Void)?
    var onEject: ((Int) -> Void)?
    var onDelete: ((URL) -> Void)?
    var onDismiss: (() -> Void)?

    private var images: [URL]
    private var activeURLs: [URL?]
    private var busy = false
    private let driveLetters = ["D", "E", "F"]
    private let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    init(images: [URL], activeURLs: [URL?]) {
        self.images = images
        self.activeURLs = activeURLs
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "CD/DVDドライブ"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(dismissLibrary)
        )
        tableView.allowsSelection = true
    }

    func reload(images: [URL], activeURLs: [URL?], busy: Bool) {
        self.images = images
        self.activeURLs = activeURLs
        self.busy = busy
        tableView.isUserInteractionEnabled = !busy
        tableView.alpha = busy ? 0.6 : 1
        if busy {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            navigationItem.titleView = spinner
        } else {
            navigationItem.titleView = nil
            title = "CD/DVDドライブ"
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 { return activeURLs.count }
        return images.count + 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "仮想CD/DVDドライブ" : "保存済みCDイメージ"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return "D:・E:・F:へ異なるCDを最大3枚同時に挿入できます。ドライブをタップすると、そのドライブのCDを変更または取り出せます。"
        }
        return "Filesで選んだだけではドライブに挿入されません。追加したイメージをタップし、挿入先を選んでください。"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.numberOfLines = 1

        if indexPath.section == 0 {
            let letter = driveLetters[indexPath.row]
            let activeURL = activeURLs[indexPath.row]
            cell.textLabel?.text = "CD/DVDドライブ (\(letter):)"
            cell.detailTextLabel?.text = activeURL?.lastPathComponent ?? "何も挿入されていません"
            cell.imageView?.image = UIImage(systemName: activeURL == nil ? "externaldrive" : "externaldrive.fill")
            cell.accessoryType = .disclosureIndicator
            cell.accessibilityHint = "ダブルタップして、このドライブのCDを設定します"
            return cell
        }

        if indexPath.row == 0 {
            cell.textLabel?.text = "ライブラリへCDイメージを追加…"
            cell.detailTextLabel?.text = "追加後にドライブを選んで挿入します"
            cell.textLabel?.textColor = view.tintColor
            cell.imageView?.image = UIImage(systemName: "doc.badge.plus")
            return cell
        }

        let imageURL = images[indexPath.row - 1]
        cell.textLabel?.text = imageURL.lastPathComponent
        let mountedLetters = activeURLs.enumerated().compactMap { index, mountedURL in
            mountedURL == imageURL ? "\(driveLetters[index]):" : nil
        }
        if let size = try? imageURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            let sizeText = byteFormatter.string(fromByteCount: Int64(size))
            cell.detailTextLabel?.text = mountedLetters.isEmpty
                ? "\(sizeText) — タップして挿入先を選択"
                : "\(sizeText) — \(mountedLetters.joined(separator: ", ")) に挿入中"
        } else {
            cell.detailTextLabel?.text = mountedLetters.isEmpty
                ? "タップして挿入先を選択"
                : "\(mountedLetters.joined(separator: ", ")) に挿入中"
        }
        cell.imageView?.image = UIImage(systemName: mountedLetters.isEmpty ? "opticaldisc" : "opticaldisc.fill")
        cell.accessoryType = mountedLetters.isEmpty ? .disclosureIndicator : .checkmark
        cell.accessibilityHint = mountedLetters.isEmpty
            ? "ダブルタップして挿入先のドライブを選びます"
            : "ダブルタップして挿入中のドライブを確認します"
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy else { return }
        if indexPath.section == 0 {
            presentDriveMenu(driveIndex: indexPath.row, source: tableView.cellForRow(at: indexPath))
        } else if indexPath.row == 0 {
            onAdd?()
        } else {
            let image = images[indexPath.row - 1]
            if let mountedDrive = activeURLs.firstIndex(of: image) {
                presentMountedImageMenu(image, driveIndex: mountedDrive, source: tableView.cellForRow(at: indexPath))
            } else {
                presentDestinationMenu(for: image, source: tableView.cellForRow(at: indexPath))
            }
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
        guard editingStyle == .delete, indexPath.section == 1, images.indices.contains(indexPath.row - 1) else { return }
        onDelete?(images[indexPath.row - 1])
    }

    @objc private func dismissLibrary() { onDismiss?() }

    private func presentDriveMenu(driveIndex: Int, source: UIView?) {
        guard activeURLs.indices.contains(driveIndex) else { return }
        let letter = driveLetters[driveIndex]
        let alert = UIAlertController(
            title: "CD/DVDドライブ (\(letter):)",
            message: activeURLs[driveIndex]?.lastPathComponent ?? "何も挿入されていません",
            preferredStyle: .actionSheet
        )
        for image in images {
            let mountedDrive = activeURLs.firstIndex(of: image)
            let mountedSuffix = mountedDrive.map { "（\(driveLetters[$0]):に挿入中）" } ?? ""
            let action = UIAlertAction(title: "\(image.lastPathComponent)\(mountedSuffix)", style: .default) { [weak self] _ in
                self?.onMount?(image, driveIndex)
            }
            action.isEnabled = mountedDrive == nil
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "ライブラリへCDイメージを追加…", style: .default) { [weak self] _ in
            self?.onAdd?()
        })
        if activeURLs[driveIndex] != nil {
            alert.addAction(UIAlertAction(title: "このドライブから取り出す", style: .destructive) { [weak self] _ in
                self?.onEject?(driveIndex)
            })
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        configurePopover(for: alert, source: source)
        present(alert, animated: true)
    }

    private func presentDestinationMenu(for image: URL, source: UIView?) {
        if let mountedDrive = activeURLs.firstIndex(of: image) {
            presentMountedImageMenu(image, driveIndex: mountedDrive, source: source)
            return
        }
        let alert = UIAlertController(
            title: "挿入先を選択",
            message: image.lastPathComponent,
            preferredStyle: .actionSheet
        )
        for driveIndex in activeURLs.indices {
            let destinationDescription: String
            if let currentName = activeURLs[driveIndex]?.lastPathComponent {
                destinationDescription = "\(currentName) と交換"
            } else {
                destinationDescription = "空 — ここへ挿入"
            }
            let action = UIAlertAction(
                title: "\(driveLetters[driveIndex]):（\(destinationDescription)）",
                style: .default
            ) { [weak self] _ in
                self?.onMount?(image, driveIndex)
            }
            action.isEnabled = activeURLs[driveIndex] != image
            alert.addAction(action)
        }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel))
        configurePopover(for: alert, source: source)
        present(alert, animated: true)
    }

    private func presentMountedImageMenu(_ image: URL, driveIndex: Int, source: UIView?) {
        let letter = driveLetters[driveIndex]
        let alert = UIAlertController(
            title: "\(letter):ドライブに挿入中",
            message: "同じCDイメージを複数のドライブへ同時に挿入することはできません。\n\(image.lastPathComponent)",
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "\(letter):ドライブから取り出す", style: .destructive) { [weak self] _ in
            self?.onEject?(driveIndex)
        })
        alert.addAction(UIAlertAction(title: "閉じる", style: .cancel))
        configurePopover(for: alert, source: source)
        present(alert, animated: true)
    }

    private func configurePopover(for alert: UIAlertController, source: UIView?) {
        guard let popover = alert.popoverPresentationController else { return }
        popover.sourceView = source ?? view
        popover.sourceRect = source?.bounds ?? CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    }
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
            setWidthPreservingHandle(targetWidth)
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
            self.setWidthPreservingHandle(width)
            if let superview = self.superview { self.clampToVisibleArea(in: superview) }
            self.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.savePosition()
        }
    }

    @objc private func moveMenu(_ recognizer: UIPanGestureRecognizer) {
        guard let superview else { return }
        let delta = recognizer.translation(in: superview)
        center = CGPoint(x: center.x + delta.x, y: center.y + delta.y)
        recognizer.setTranslation(.zero, in: superview)
        clampToVisibleArea(in: superview)
        if recognizer.state == .ended || recognizer.state == .cancelled {
            savePosition()
        }
    }

    private func setWidthPreservingHandle(_ width: CGFloat) {
        let widthChange = width - bounds.width
        guard widthChange != 0 else { return }
        bounds.size.width = width
        // Keep the drag handle fixed on screen. Growing a left-opening menu
        // moves its center left; a right-opening menu moves its center right.
        center.x += (opensToLeft ? -widthChange : widthChange) / 2
    }

    private func savePosition() {
        guard let superview else { return }
        layoutIfNeeded()
        let handleCenter = convert(
            CGPoint(x: handleButton.frame.midX, y: handleButton.frame.midY),
            to: superview
        )
        UserDefaults.standard.set(handleCenter.x / max(1, superview.bounds.width), forKey: "FloatingMenuX")
        UserDefaults.standard.set(handleCenter.y / max(1, superview.bounds.height), forKey: "FloatingMenuY")
    }

    private func clampToVisibleArea(in superview: UIView) {
        let safe = superview.bounds.inset(by: superview.safeAreaInsets).insetBy(dx: 6, dy: 6)
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2
        center.x = min(max(center.x, safe.minX + halfWidth), safe.maxX - halfWidth)
        center.y = min(max(center.y, safe.minY + halfHeight), safe.maxY - halfHeight)
    }
}
