import UIKit

enum RetroKey {
    static let backspace: UInt32 = 8
    static let tab: UInt32 = 9
    static let enter: UInt32 = 13
    static let escape: UInt32 = 27
    static let space: UInt32 = 32
    static let delete: UInt32 = 127
    static let up: UInt32 = 273
    static let down: UInt32 = 274
    static let right: UInt32 = 275
    static let left: UInt32 = 276
    static let insert: UInt32 = 277
    static let home: UInt32 = 278
    static let end: UInt32 = 279
    static let pageUp: UInt32 = 280
    static let pageDown: UInt32 = 281
    static let leftShift: UInt32 = 304
    static let leftControl: UInt32 = 306
    static let leftAlt: UInt32 = 308
}

final class KeyboardCaptureView: UITextField, UITextFieldDelegate {
    var sendKey: ((UInt32, Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        keyboardType = .asciiCapable
        textContentType = .none
        text = " "
        tintColor = .clear
        textColor = .clear
        backgroundColor = .clear
        accessibilityLabel = "Windows keyboard input"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        if shift { sendKey?(RetroKey.leftShift, true) }
        tap(key)
        if shift { sendKey?(RetroKey.leftShift, false) }
    }

    private func tap(_ key: UInt32) {
        sendKey?(key, true)
        sendKey?(key, false)
    }
}

