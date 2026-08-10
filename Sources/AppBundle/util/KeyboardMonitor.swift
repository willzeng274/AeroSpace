@preconcurrency @unsafe import AppKit

struct KeyboardEvent: Sendable {
    let flags: CGEventFlags
    let keyCode: UInt32
}

@MainActor final class KeyboardMonitor {
    nonisolated(unsafe) private var eventTap: CFMachPort?
    nonisolated(unsafe) private var runLoopSource: CFRunLoopSource?
    private let handler: @MainActor (KeyboardEvent) -> Bool

    init(handler: @escaping @MainActor (KeyboardEvent) -> Bool) {
        self.handler = handler
        start()
    }

    private func start() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        unsafe eventTap = unsafe CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon = unsafe refcon else { return unsafe Unmanaged.passUnretained(event) }
                let monitor = unsafe Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let eventTap = unsafe monitor.eventTap {
                            CGEvent.tapEnable(tap: eventTap, enable: true)
                        }
                    }
                    return unsafe Unmanaged.passUnretained(event)
                }

                let keyboardEvent = KeyboardEvent(
                    flags: event.flags,
                    keyCode: UInt32(event.getIntegerValueField(.keyboardEventKeycode)),
                )
                let handled = MainActor.assumeIsolated { monitor.handler(keyboardEvent) }
                return handled ? nil : unsafe Unmanaged.passUnretained(event)
            },
            userInfo: unsafe Unmanaged.passUnretained(self).toOpaque(),
        )

        if let eventTap = unsafe eventTap {
            unsafe runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            unsafe CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }

    deinit {
        if let eventTap = unsafe eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource = unsafe runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
    }
}
