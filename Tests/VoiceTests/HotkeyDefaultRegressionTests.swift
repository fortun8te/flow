import Testing
import AppKit
@testable import Voice

@Suite("Default hotkey behavior")
struct HotkeyDefaultRegressionTests {
    @Test("Default push to talk uses standalone Fn and its event tap")
    func defaultFn() {
        let bindings = HotkeyRole.pushToTalk.defaultBindings
        #expect(bindings.count == 1)
        #expect(bindings[0].keyCode == nil)
        #expect(bindings[0].modifiersRaw == 0x800000)
        #expect(HotkeyService.usesStandaloneFnTap(bindings))
        #expect(!HotkeyService.usesStandaloneFnTap([CapturedHotkey(keyCode: 49, modifiersRaw: 0x800000)]))
    }

    @Test("Only our actual Fn release is consumed")
    func fnRelease() {
        #expect(FnKeyTap.consumesFnRelease(keyCode: 63, fnIsDown: true, fnFlag: false, otherModifiers: false))
        #expect(!FnKeyTap.consumesFnRelease(keyCode: 56, fnIsDown: false, fnFlag: false, otherModifiers: false))
        #expect(!FnKeyTap.consumesFnRelease(keyCode: 63, fnIsDown: false, fnFlag: false, otherModifiers: false))
        #expect(!FnKeyTap.consumesFnRelease(keyCode: 63, fnIsDown: true, fnFlag: false, otherModifiers: true))
    }

    @Test("A held key combination ends on its own key release")
    func comboRelease() {
        func key(_ type: NSEvent.EventType, _ code: UInt16, _ flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: code)!
        }
        let optionOne = CapturedHotkey(keyCode: 18, modifiersRaw: 0x20)
        // Device-dependent left Option bit, as recorded by the capturer.
        let leftOption = NSEvent.ModifierFlags(rawValue: 0x20)
        #expect(optionOne.matches(key(.keyDown, 18, leftOption), hotkeyIsDown: false))
        #expect(optionOne.matches(key(.keyUp, 19, leftOption), hotkeyIsDown: true))
        #expect(!optionOne.matches(key(.keyUp, 18, leftOption), hotkeyIsDown: true))
        let plain = CapturedHotkey(keyCode: 18, modifiersRaw: 0)
        #expect(plain.matches(key(.keyUp, 19, []), hotkeyIsDown: true))
        #expect(!plain.matches(key(.keyUp, 18, []), hotkeyIsDown: true))
    }
}
