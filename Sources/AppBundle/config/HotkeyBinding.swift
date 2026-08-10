import AppKit
import Common
import Foundation
import HotKey

@MainActor private var keyboardMonitor: KeyboardMonitor?
@MainActor private var activeHotkeys: [ExpandedHotkey: String] = [:]

@MainActor func resetHotKeys() {
    activeHotkeys = [:]
    keyboardMonitor = KeyboardMonitor { event in
        let modifiers = event.flags.intersection(.aeroSpaceModifierMask)
        let hotkey = ExpandedHotkey(modifiers: modifiers, keyCode: event.keyCode)
        guard
            let bindingId = activeHotkeys[hotkey],
            let activeMode,
            let binding = config.modes[activeMode]?.bindings[bindingId]
        else { return false }

        broadcastEvent(.bindingTriggered(
            mode: activeMode,
            binding: binding.descriptionWithKeyNotation,
        ))
        Task.startUnstructured {
            try await runLightSession(.hotkeyBinding, .checkServerIsEnabledOrDie()) { () throws in
                _ = await binding.commands.run(.defaultEnv, .emptyStdin)
            }
        }
        return true
    }
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode_nonCancellable(_ targetMode: String?) async {
    let targetBindings = targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
    activeHotkeys.removeAll(keepingCapacity: true)
    for binding in targetBindings.values {
        for expandedHotkey in binding.expandedHotkeys {
            activeHotkeys[expandedHotkey] = binding.descriptionWithKeyCode
        }
    }

    let oldMode = activeMode
    activeMode = targetMode
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        _ = await config.onModeChanged.run(.defaultEnv, .emptyStdin)
    }
}

extension CGEventFlags {
    static let maskShiftL = CGEventFlags.maskShift.union(CGEventFlags(rawValue: 1 << 1))
    static let maskShiftR = CGEventFlags.maskShift.union(CGEventFlags(rawValue: 1 << 2))
    static let maskControlL = CGEventFlags.maskControl.union(CGEventFlags(rawValue: 1 << 0))
    static let maskControlR = CGEventFlags.maskControl.union(CGEventFlags(rawValue: 1 << 13))
    static let maskAlternateL = CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 1 << 5))
    static let maskAlternateR = CGEventFlags.maskAlternate.union(CGEventFlags(rawValue: 1 << 6))
    static let maskCommandL = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 1 << 3))
    static let maskCommandR = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 1 << 4))

    static let aeroSpaceModifierMask = CGEventFlags([
        .maskShiftL, .maskShiftR,
        .maskControlL, .maskControlR,
        .maskAlternateL, .maskAlternateR,
        .maskCommandL, .maskCommandR,
        .maskSecondaryFn,
    ])

    func expandDirectionalVariants() -> [CGEventFlags] {
        let base = subtracting(CGEventFlags([
            .maskShiftL, .maskShiftR,
            .maskControlL, .maskControlR,
            .maskAlternateL, .maskAlternateR,
            .maskCommandL, .maskCommandR,
        ]))
        var variants = [base]

        func expand(
            _ current: [CGEventFlags],
            left: CGEventFlags,
            right: CGEventFlags,
            generic: CGEventFlags,
        ) -> [CGEventFlags] {
            if contains(left) { return current.map { $0.union(left) } }
            if contains(right) { return current.map { $0.union(right) } }
            if contains(generic) {
                return current.flatMap { [$0.union(left), $0.union(right)] }
            }
            return current
        }

        variants = expand(variants, left: .maskShiftL, right: .maskShiftR, generic: .maskShift)
        variants = expand(variants, left: .maskControlL, right: .maskControlR, generic: .maskControl)
        variants = expand(variants, left: .maskAlternateL, right: .maskAlternateR, generic: .maskAlternate)
        variants = expand(variants, left: .maskCommandL, right: .maskCommandR, generic: .maskCommand)
        return variants
    }

    func aeroSpaceDescription() -> String {
        var result: [String] = []
        if contains(.maskControlL) { result.append("lctrl") }
        else if contains(.maskControlR) { result.append("rctrl") }
        else if contains(.maskControl) { result.append("ctrl") }

        if contains(.maskSecondaryFn) { result.append("fn") }

        if contains(.maskAlternateL) { result.append("lalt") }
        else if contains(.maskAlternateR) { result.append("ralt") }
        else if contains(.maskAlternate) { result.append("alt") }

        if contains(.maskShiftL) { result.append("lshift") }
        else if contains(.maskShiftR) { result.append("rshift") }
        else if contains(.maskShift) { result.append("shift") }

        if contains(.maskCommandL) { result.append("lcmd") }
        else if contains(.maskCommandR) { result.append("rcmd") }
        else if contains(.maskCommand) { result.append("cmd") }
        return result.joined(separator: "-")
    }
}

private let cgModifiersMap: [String: CGEventFlags] = [
    "shift": .maskShift,
    "lshift": .maskShiftL,
    "rshift": .maskShiftR,
    "alt": .maskAlternate,
    "lalt": .maskAlternateL,
    "ralt": .maskAlternateR,
    "ctrl": .maskControl,
    "lctrl": .maskControlL,
    "rctrl": .maskControlR,
    "cmd": .maskCommand,
    "lcmd": .maskCommandL,
    "rcmd": .maskCommandR,
    "fn": .maskSecondaryFn,
]

struct ExpandedHotkey: Hashable, Sendable {
    let modifiers: CGEventFlags
    let keyCode: UInt32

    static func == (lhs: ExpandedHotkey, rhs: ExpandedHotkey) -> Bool {
        lhs.modifiers.rawValue == rhs.modifiers.rawValue && lhs.keyCode == rhs.keyCode
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modifiers.rawValue)
        hasher.combine(keyCode)
    }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: CGEventFlags
    let keyCode: Key
    let commands: Shell<any Command>
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String

    var expandedHotkeys: [ExpandedHotkey] {
        modifiers.expandDirectionalVariants().map {
            ExpandedHotkey(modifiers: $0, keyCode: keyCode.carbonKeyCode)
        }
    }

    init(_ modifiers: CGEventFlags, _ keyCode: Key, _ commands: Shell<any Command>, descriptionWithKeyNotation: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.aeroSpaceDescription() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers.rawValue == rhs.modifiers.rawValue &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.commands.strictEquals(rhs.commands)
    }
}

func parseBindings(_ raw: OrderedJson, _ backtrace: ConfigBacktrace, _ c: inout ConfigParserContext, _ mapping: [String: Key]) -> [String: HotkeyBinding] {
    guard let rawTable = raw.asDictOrNil else {
        c.errors += [expectedActualTypeDiagnostic(expected: .table, actual: raw.tomlType, backtrace)]
        return [:]
    }
    var result: [String: HotkeyBinding] = [:]
    var occupiedHotkeys = Set<ExpandedHotkey>()
    for (bindingNotation, rawCommand): (String, OrderedJson) in rawTable {
        let bindingBacktrace = backtrace + .key(bindingNotation)
        let binding = parseBinding(bindingNotation, bindingBacktrace, mapping)
            .map { modifiers, key -> HotkeyBinding in
                let commands = parseShellOfCommandsForConfig(rawCommand, bindingBacktrace, &c)
                return HotkeyBinding(modifiers, key, commands, descriptionWithKeyNotation: bindingNotation)
            }
            .getOrNil(appendErrorTo: &c.errors)
        if let binding {
            let expanded = Set(binding.expandedHotkeys)
            if !occupiedHotkeys.isDisjoint(with: expanded) {
                c.errors.append(.init(bindingBacktrace, "'\(binding.descriptionWithKeyNotation)' Binding redeclaration"))
            }
            occupiedHotkeys.formUnion(expanded)
            result[binding.descriptionWithKeyCode] = binding
        }
    }
    return result
}

func parseBinding(_ raw: String, _ backtrace: ConfigBacktrace, _ mapping: [String: Key]) -> ResOrConfigParseDiagnostic<(CGEventFlags, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ResOrConfigParseDiagnostic<CGEventFlags> = rawKeys.dropLast()
        .mapAllOrFailure {
            cgModifiersMap[String($0)].toResult(.init(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { CGEventFlags($0) }
    let key: ResOrConfigParseDiagnostic<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .toResult(.init(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers -> ResOrConfigParseDiagnostic<(CGEventFlags, Key)> in
        key.map { (modifiers, $0) }
    }
}
