import AppKit
import Common

struct AlwaysOnTopCommand: Command {
    let args: AlwaysOnTopCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let macWindow = window.asMacWindow()
        if OverlayManager.shared.isPinned(windowId: window.windowId) {
            await OverlayManager.shared.unpin(windowId: window.windowId)
        } else {
            guard let rect = try await macWindow.getAxRect() else {
                return io.err("Failed to get window rect")
            }
            let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
            let cocoaY = mainScreenHeight - rect.topLeftY - rect.height
            let frame = NSRect(x: rect.topLeftX, y: cocoaY, width: rect.width, height: rect.height)
            if await !OverlayManager.shared.pin(windowId: window.windowId, frame: frame, macWindow: macWindow) {
                return io.err("Failed to create overlay. Screen Recording permission may be required.")
            }
        }
        return true
    }
}
