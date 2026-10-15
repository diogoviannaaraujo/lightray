/// Physical keys stay tracked independently of their remote mapping so every release matches its press.
public struct RemoteKeyboard {
    public enum Mapping: String, Codable, Sendable { case physical, commandControl }
    public enum Shortcut: Sendable {
        case altTab, windowsKey, controlEscape

        public var usages: [UInt16] {
            switch self {
            case .altTab: [0xE2, 0x2B]
            case .windowsKey: [0xE3]
            case .controlEscape: [0xE0, 0x29]
            }
        }
    }

    public private(set) var mapping: Mapping
    public private(set) var held = Set<UInt16>()

    public init(mapping: Mapping = .physical) { self.mapping = mapping }

    private func remoteUsage(_ usage: UInt16) -> UInt16 {
        guard mapping == .commandControl else { return usage }
        switch usage {
        case 0xE0: return 0xE3
        case 0xE3: return 0xE0
        case 0xE4: return 0xE7
        case 0xE7: return 0xE4
        default: return usage
        }
    }

    public mutating func key(_ usage: UInt16, down: Bool, isRepeat: Bool = false) -> [InputMessage] {
        if down {
            let inserted = held.insert(usage).inserted
            guard inserted || isRepeat else { return [] }
        } else {
            guard held.remove(usage) != nil else { return [] }
        }
        return [.key(usage: remoteUsage(usage), down: down, isRepeat: down && isRepeat)]
    }

    public mutating func synchronizeModifiers(flags: UInt64) -> [InputMessage] {
        let previous = held.filter { KeyMap.modifier(forUsage: $0) != nil }
        let current = KeyMap.reconciledModifiers(flags: flags, held: previous)
        var messages: [InputMessage] = []
        for usage in previous.subtracting(current).sorted() { messages += key(usage, down: false) }
        for usage in current.subtracting(previous).sorted() { messages += key(usage, down: true) }
        return messages
    }

    public mutating func releaseAll() -> [InputMessage] {
        // Release ordinary keys before their modifiers.
        let keys = held.filter { KeyMap.modifier(forUsage: $0) == nil }.sorted()
        let modifiers = held.filter { KeyMap.modifier(forUsage: $0) != nil }.sorted()
        return (keys + modifiers).flatMap { key($0, down: false) }
    }

    public mutating func setMapping(_ mapping: Mapping) -> [InputMessage] {
        let releases = releaseAll()
        self.mapping = mapping
        return releases
    }

    /// Explicit host shortcuts bypass the user's physical-key mapping and leave nothing held.
    public mutating func shortcut(_ shortcut: Shortcut) -> [InputMessage] {
        releaseAll() + shortcut.usages.map { .key(usage: $0, down: true, isRepeat: false) } + shortcut.usages.reversed().map { .key(usage: $0, down: false, isRepeat: false) }
    }
}

public enum ClientHotkey: Sendable {
    case quit, statistics, releaseInput, fullScreen, altTab, windowsKey, sessionMenu

    public static func match(keyCode: UInt16, flags: UInt64) -> Self? {
        let mask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        let prefix: UInt64 = (1 << 18) | (1 << 19) | (1 << 20)
        guard flags & mask == prefix else { return nil }
        switch keyCode {
        case 0x0C: return .quit
        case 0x2E: return .statistics
        case 0x35: return .releaseInput
        case 0x03: return .fullScreen
        case 0x30: return .altTab
        case 0x0D: return .windowsKey
        case 0x01: return .sessionMenu
        default: return nil
        }
    }
}
