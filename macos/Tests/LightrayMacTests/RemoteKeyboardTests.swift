import Testing
@testable import LightrayCore
@testable import LightrayMac

private func key(_ usage: UInt16, _ down: Bool, repeat isRepeat: Bool = false) -> InputMessage {
    .key(usage: usage, down: down, isRepeat: isRepeat)
}

@Test func commandCopyAndPasteBecomeWindowsControlShortcuts() {
    for letter: UInt16 in [0x06, 0x19] {
        var keyboard = RemoteKeyboard(mapping: .commandControl)
        #expect(keyboard.synchronizeModifiers(flags: KeyMap.flag(.leftCommand)) == [key(0xE0, true)])
        #expect(keyboard.key(letter, down: true) == [key(letter, true)])
        #expect(keyboard.key(letter, down: false) == [key(letter, false)])
        #expect(keyboard.synchronizeModifiers(flags: 0) == [key(0xE0, false)])
        #expect(keyboard.held.isEmpty)
    }
}

@Test func keyboardSwapPreservesBothSidesAndLeavesAltGrUnchanged() {
    var keyboard = RemoteKeyboard(mapping: .commandControl)
    for (physical, remote): (UInt16, UInt16) in [(0xE0,0xE3),(0xE3,0xE0),(0xE4,0xE7),(0xE7,0xE4),(0xE6,0xE6)] {
        #expect(keyboard.key(physical, down: true) == [key(remote, true)])
        #expect(keyboard.key(physical, down: false) == [key(remote, false)])
    }
}

@Test func changingMappingReleasesUsingThePreviousMapping() {
    var keyboard = RemoteKeyboard(mapping: .commandControl)
    _ = keyboard.key(0xE3, down: true)
    _ = keyboard.key(0x06, down: true)
    #expect(keyboard.setMapping(.physical) == [key(0x06, false), key(0xE0, false)])
    #expect(keyboard.key(0x06, down: false).isEmpty)
    #expect(keyboard.key(0xE3, down: true) == [key(0xE3, true)])
}

@Test func focusReleaseIsIdempotentAndSupportsSimultaneousKeys() {
    var keyboard = RemoteKeyboard()
    for usage: UInt16 in [0xE1,0x04,0x07] { _ = keyboard.key(usage, down: true) }
    #expect(keyboard.releaseAll() == [key(0x04, false),key(0x07, false),key(0xE1, false)])
    #expect(keyboard.releaseAll().isEmpty)
    #expect(keyboard.key(0x04, down: false).isEmpty)
}

@Test func repeatedKeysDoNotProduceDuplicateNonRepeatPresses() {
    var keyboard = RemoteKeyboard()
    #expect(keyboard.key(0x04, down: true) == [key(0x04, true)])
    #expect(keyboard.key(0x04, down: true).isEmpty)
    #expect(keyboard.key(0x04, down: true, isRepeat: true) == [key(0x04, true, repeat: true)])
    #expect(keyboard.releaseAll() == [key(0x04, false)])
}

@Test func explicitHostShortcutsBypassMappingAndReleaseTheirKeys() {
    var keyboard = RemoteKeyboard(mapping: .commandControl)
    _ = keyboard.key(0xE3, down: true)
    #expect(keyboard.shortcut(.altTab) == [key(0xE0, false),key(0xE2, true),key(0x2B, true),key(0x2B, false),key(0xE2, false)])
    #expect(keyboard.shortcut(.windowsKey) == [key(0xE3, true),key(0xE3, false)])
    #expect(keyboard.shortcut(.controlEscape) == [key(0xE0, true),key(0x29, true),key(0x29, false),key(0xE0, false)])
    #expect(keyboard.held.isEmpty)
}

@Test func clientHotkeysRequireTheReservedLocalPrefix() {
    let prefix = KeyMap.flag(.leftControl) | KeyMap.flag(.leftOption) | KeyMap.flag(.leftCommand)
    #expect(ClientHotkey.match(keyCode: 0x2E, flags: prefix) == .statistics)
    #expect(ClientHotkey.match(keyCode: 0x30, flags: prefix) == .altTab)
    #expect(ClientHotkey.match(keyCode: 0x0D, flags: prefix) == .windowsKey)
    #expect(ClientHotkey.match(keyCode: 0x35, flags: prefix) == .releaseInput)
    #expect(ClientHotkey.match(keyCode: 0x01, flags: prefix) == .sessionMenu)
    #expect(ClientHotkey.match(keyCode: 0x08, flags: KeyMap.flag(.leftCommand)) == nil)
    #expect(ClientHotkey.match(keyCode: 0x30, flags: KeyMap.flag(.leftOption)) == nil)
    #expect(ClientHotkey.match(keyCode: 0x2E, flags: prefix | KeyMap.flag(.leftShift)) == nil)
}

@Test func isoApplicationAndExtendedFunctionKeysKeepPhysicalIdentity() {
    let pairs: [(UInt16, UInt16)] = [(0x0A,0x64),(0x6E,0x65),(0x69,0x68),(0x6B,0x69),(0x71,0x6A),(0x6A,0x6B),(0x40,0x6C),(0x4F,0x6D),(0x50,0x6E),(0x5A,0x6F)]
    for mapping in [RemoteKeyboard.Mapping.physical, .commandControl] {
        var keyboard = RemoteKeyboard(mapping: mapping)
        for (code, usage) in pairs {
            #expect(KeyMap.usage(forKeyCode: code) == usage)
            #expect(keyboard.key(usage, down: true) == [key(usage, true)])
            #expect(keyboard.releaseAll() == [key(usage, false)])
        }
    }
}
