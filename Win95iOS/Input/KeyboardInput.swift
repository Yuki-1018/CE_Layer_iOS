import UIKit

enum RetroKey {
    static let backspace: UInt32 = 8
    static let tab: UInt32 = 9
    static let enter: UInt32 = 13
    static let pause: UInt32 = 19
    static let escape: UInt32 = 27
    static let space: UInt32 = 32
    static let quote: UInt32 = 39
    static let comma: UInt32 = 44
    static let minus: UInt32 = 45
    static let period: UInt32 = 46
    static let slash: UInt32 = 47
    static let equals: UInt32 = 61
    static let leftBracket: UInt32 = 91
    static let backslash: UInt32 = 92
    static let rightBracket: UInt32 = 93
    static let backquote: UInt32 = 96
    static let delete: UInt32 = 127
    static let keypad0: UInt32 = 256
    static let keypad1: UInt32 = 257
    static let keypadPeriod: UInt32 = 266
    static let keypadDivide: UInt32 = 267
    static let keypadMultiply: UInt32 = 268
    static let keypadMinus: UInt32 = 269
    static let keypadPlus: UInt32 = 270
    static let keypadEnter: UInt32 = 271
    static let keypadEquals: UInt32 = 272
    static let up: UInt32 = 273
    static let down: UInt32 = 274
    static let right: UInt32 = 275
    static let left: UInt32 = 276
    static let insert: UInt32 = 277
    static let home: UInt32 = 278
    static let end: UInt32 = 279
    static let pageUp: UInt32 = 280
    static let pageDown: UInt32 = 281
    static let f1: UInt32 = 282
    static let f12: UInt32 = 293
    static let numLock: UInt32 = 300
    static let capsLock: UInt32 = 301
    static let scrollLock: UInt32 = 302
    static let rightShift: UInt32 = 303
    static let leftShift: UInt32 = 304
    static let rightControl: UInt32 = 305
    static let leftControl: UInt32 = 306
    static let rightAlt: UInt32 = 307
    static let leftAlt: UInt32 = 308
    static let leftSuper: UInt32 = 311
    static let rightSuper: UInt32 = 312
    static let printScreen: UInt32 = 316
    static let menu: UInt32 = 319
    static let power: UInt32 = 320

    static func isModifier(_ key: UInt32) -> Bool {
        switch key {
        case leftShift, rightShift, leftControl, rightControl, leftAlt, rightAlt, leftSuper, rightSuper:
            return true
        default:
            return false
        }
    }

    static func orderedKeyCodes(from presses: Set<UIPress>, pressed: Bool) -> [UInt32] {
        presses.compactMap { press in
            guard let key = press.key else { return nil }
            return fromHIDUsage(key.keyCode.rawValue)
        }.sorted { left, right in
            let leftIsModifier = isModifier(left)
            let rightIsModifier = isModifier(right)
            if leftIsModifier != rightIsModifier {
                return pressed ? leftIsModifier : !leftIsModifier
            }
            return left < right
        }
    }

    static func fromHIDUsage(_ usage: Int) -> UInt32? {
        if (4...29).contains(usage) { return UInt32(usage - 4 + 97) }
        if (30...38).contains(usage) { return UInt32(usage - 30 + 49) }
        if (58...69).contains(usage) { return UInt32(usage - 58) + f1 }
        if (89...97).contains(usage) { return UInt32(usage - 89) + keypad1 }
        if (104...106).contains(usage) { return UInt32(usage - 104) + f12 + 1 }

        switch usage {
        case 39: return 48
        case 40: return enter
        case 41: return escape
        case 42: return backspace
        case 43: return tab
        case 44: return space
        case 45: return minus
        case 46: return equals
        case 47: return leftBracket
        case 48: return rightBracket
        case 49, 50: return backslash
        case 51: return 59
        case 52: return quote
        case 53: return backquote
        case 54: return comma
        case 55: return period
        case 56: return slash
        case 57: return capsLock
        case 70: return printScreen
        case 71: return scrollLock
        case 72: return pause
        case 73: return insert
        case 74: return home
        case 75: return pageUp
        case 76: return delete
        case 77: return end
        case 78: return pageDown
        case 79: return right
        case 80: return left
        case 81: return down
        case 82: return up
        case 83: return numLock
        case 84: return keypadDivide
        case 85: return keypadMultiply
        case 86: return keypadMinus
        case 87: return keypadPlus
        case 88: return keypadEnter
        case 98: return keypad0
        case 99: return keypadPeriod
        case 103: return keypadEquals
        case 101: return menu
        case 102: return power
        case 224: return leftControl
        case 225: return leftShift
        case 226: return leftAlt
        case 227: return leftSuper
        case 228: return rightControl
        case 229: return rightShift
        case 230: return rightAlt
        case 231: return rightSuper
        default: return nil
        }
    }
}

final class KeyboardCaptureView: UITextField, UITextFieldDelegate {
    var sendKey: ((UInt32, Bool) -> Void)? {
        didSet { accessory.sendKey = sendKey }
    }
    var keyboardDidHide: (() -> Void)?

    private lazy var accessory: SpecialKeyAccessoryView = {
        let view = SpecialKeyAccessoryView()
        view.sendKey = sendKey
        view.hideKeyboard = { [weak self] in
            self?.dismissKeyboard()
        }
        view.pasteText = { [weak self] in
            guard let text = UIPasteboard.general.string else { return }
            self?.insertText(text)
        }
        return view
    }()

    init() {
        super.init(frame: .zero)
        inputAccessoryView = accessory
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        keyboardType = .asciiCapable
        textContentType = .none
        text = " "
        tintColor = .clear
        textColor = .clear
        backgroundColor = .clear
        accessibilityLabel = "Windows keyboard input"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        let keys = RetroKey.orderedKeyCodes(from: presses, pressed: pressed)
        keys.forEach { sendKey?($0, pressed) }
        return !keys.isEmpty
    }

    func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
        if string.isEmpty {
            tap(RetroKey.backspace)
        } else {
            for scalar in string.unicodeScalars {
                let value = scalar.value
                if value == 10 { tap(RetroKey.enter) }
                else if value < 128 { sendASCII(UInt8(value)) }
            }
        }
        accessory.releaseModifiers()
        text = " "
        return false
    }

    private func sendASCII(_ ascii: UInt8) {
        var key = UInt32(ascii)
        var shift = false
        if ascii >= 65 && ascii <= 90 { key = UInt32(ascii + 32); shift = true }
        let shifted = "!@#$%^&*()_+{}|:\"<>?~"
        let unshifted = "1234567890-=[]\\;',./`"
        if let index = shifted.utf8.firstIndex(of: ascii) {
            let offset = shifted.utf8.distance(from: shifted.utf8.startIndex, to: index)
            key = UInt32(Array(unshifted.utf8)[offset])
            shift = true
        }
        let synthesizeShift = shift && !accessory.isModifierActive(RetroKey.leftShift) && !accessory.isModifierActive(RetroKey.rightShift)
        if synthesizeShift { sendKey?(RetroKey.leftShift, true) }
        tap(key)
        if synthesizeShift { sendKey?(RetroKey.leftShift, false) }
    }

    private func tap(_ key: UInt32) {
        sendKey?(key, true)
        sendKey?(key, false)
    }

    func dismissKeyboard() {
        accessory.releaseModifiers()
        resignFirstResponder()
        keyboardDidHide?()
    }
}

private final class SpecialKeyButton: UIButton {
    let keyCode: UInt32
    let isModifier: Bool

    init(title: String, keyCode: UInt32, isModifier: Bool = false) {
        self.keyCode = keyCode
        self.isModifier = isModifier
        super.init(frame: .zero)
        setTitle(title, for: .normal)
        setTitleColor(.label, for: .normal)
        setTitleColor(.white, for: .selected)
        titleLabel?.font = .systemFont(ofSize: title.count > 3 ? 11 : 16, weight: .medium)
        layer.cornerRadius = 6
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        backgroundColor = .tertiarySystemBackground
        accessibilityLabel = title
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 3 ? 48 : 38).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateAppearance() {
        backgroundColor = isSelected ? .systemBlue : .tertiarySystemBackground
    }
}

private final class SpecialKeyAccessoryView: UIView {
    var sendKey: ((UInt32, Bool) -> Void)?
    var hideKeyboard: (() -> Void)?
    var pasteText: (() -> Void)?
    private var modifierButtons: [UInt32: SpecialKeyButton] = [:]

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 600, height: 54))
        backgroundColor = .secondarySystemBackground
        autoresizingMask = .flexibleWidth

        let root = UIStackView()
        root.axis = .horizontal
        root.alignment = .fill
        root.spacing = 6
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        let modifiers = UIStackView()
        modifiers.axis = .horizontal
        modifiers.spacing = 4
        for spec in [("Ctrl", RetroKey.leftControl), ("Alt", RetroKey.leftAlt), ("Win", RetroKey.leftSuper), ("⇧", RetroKey.leftShift)] {
            modifiers.addArrangedSubview(makeButton(title: spec.0, key: spec.1, modifier: true))
        }
        root.addArrangedSubview(modifiers)

        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let keys = UIStackView()
        keys.axis = .horizontal
        keys.spacing = 4
        keys.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(keys)
        root.addArrangedSubview(scroll)

        let navigation: [(String, UInt32)] = [
            ("Esc", RetroKey.escape), ("Tab", RetroKey.tab), ("↵", RetroKey.enter),
            ("←", RetroKey.left), ("↑", RetroKey.up), ("↓", RetroKey.down), ("→", RetroKey.right),
            ("Ins", RetroKey.insert), ("Del", RetroKey.delete), ("Home", RetroKey.home),
            ("End", RetroKey.end), ("Pg Up", RetroKey.pageUp), ("Pg Dn", RetroKey.pageDown),
            ("PrtSc", RetroKey.printScreen), ("Pause", RetroKey.pause),
            ("Menu", RetroKey.menu), ("Caps", RetroKey.capsLock), ("Num", RetroKey.numLock), ("Scroll", RetroKey.scrollLock)
        ]
        navigation.forEach { keys.addArrangedSubview(makeButton(title: $0.0, key: $0.1)) }
        for offset in 0...11 {
            keys.addArrangedSubview(makeButton(title: "F\(offset + 1)", key: RetroKey.f1 + UInt32(offset)))
        }

        let paste = UIButton(type: .system)
        paste.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        paste.accessibilityLabel = "Paste"
        paste.addTarget(self, action: #selector(pastePressed), for: .touchUpInside)
        paste.widthAnchor.constraint(equalToConstant: 36).isActive = true
        root.addArrangedSubview(paste)

        let hide = UIButton(type: .system)
        hide.setImage(UIImage(systemName: "keyboard.chevron.compact.down"), for: .normal)
        hide.accessibilityLabel = "Hide keyboard"
        hide.addTarget(self, action: #selector(hidePressed), for: .touchUpInside)
        hide.widthAnchor.constraint(equalToConstant: 36).isActive = true
        root.addArrangedSubview(hide)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 54),
            root.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            keys.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            keys.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            keys.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            keys.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            keys.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeButton(title: String, key: UInt32, modifier: Bool = false) -> SpecialKeyButton {
        let button = SpecialKeyButton(title: title, keyCode: key, isModifier: modifier)
        if modifier {
            modifierButtons[key] = button
            button.addTarget(self, action: #selector(toggleModifier(_:)), for: .touchUpInside)
        } else {
            button.addTarget(self, action: #selector(keyDown(_:)), for: .touchDown)
            button.addTarget(self, action: #selector(keyUp(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        }
        return button
    }

    @objc private func toggleModifier(_ sender: SpecialKeyButton) {
        sender.isSelected.toggle()
        sender.updateAppearance()
        sendKey?(sender.keyCode, sender.isSelected)
    }

    @objc private func keyDown(_ sender: SpecialKeyButton) { sendKey?(sender.keyCode, true) }

    @objc private func keyUp(_ sender: SpecialKeyButton) {
        sendKey?(sender.keyCode, false)
        releaseModifiers()
    }

    func releaseModifiers() {
        for (key, button) in modifierButtons where button.isSelected {
            sendKey?(key, false)
            button.isSelected = false
            button.updateAppearance()
        }
    }

    func isModifierActive(_ key: UInt32) -> Bool {
        modifierButtons[key]?.isSelected == true
    }

    @objc private func pastePressed() { pasteText?() }
    @objc private func hidePressed() { releaseModifiers(); hideKeyboard?() }
}
