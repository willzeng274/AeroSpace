@preconcurrency @unsafe import AppKit
import Common
@preconcurrency @unsafe import ScreenCaptureKit

@MainActor
final class OverlayManager {
    static let shared = OverlayManager()
    private var pinnedWindows: [UInt32: PinnedWindow] = [:]

    private init() {}

    var hasPinnedWindows: Bool { !pinnedWindows.isEmpty }

    func isPinned(windowId: UInt32) -> Bool { pinnedWindows[windowId] != nil }

    func pin(windowId: UInt32, frame: NSRect, macWindow: MacWindow) async -> Bool {
        guard !isPinned(windowId: windowId) else { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowId }) else { return false }

            let monitor = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
            let scaleFactor = Int(monitor?.backingScaleFactor ?? 2)
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let streamConfig = makeStreamConfig(frame: frame, scaleFactor: scaleFactor)
            let overlayWindow = OverlayPanel(frame: frame, windowId: windowId)
            let output = OverlayStreamOutput(displayView: overlayWindow.displayView)
            let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)

            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()
            pinnedWindows[windowId] = PinnedWindow(
                stream: stream,
                overlayWindow: overlayWindow,
                macWindow: macWindow,
                streamOutput: output,
            )
            updateOverlayState()
            return true
        } catch {
            return false
        }
    }

    func unpin(windowId: UInt32) async {
        guard let pinned = pinnedWindows.removeValue(forKey: windowId) else { return }
        try? await pinned.stream.stopCapture()
        pinned.overlayWindow.close()
    }

    nonisolated func handleWindowClosed(windowId: UInt32) {
        Task { @MainActor in
            guard let pinned = pinnedWindows.removeValue(forKey: windowId) else { return }
            try? await pinned.stream.stopCapture()
            pinned.overlayWindow.close()
        }
    }

    func updateOverlayState() {
        let focusedWindowId = focus.windowOrNil?.windowId
        for (windowId, pinned) in pinnedWindows {
            if focusedWindowId == windowId {
                pinned.overlayWindow.orderOut(nil)
                Task { await syncOverlayFrame(pinned) }
            } else {
                pinned.overlayWindow.orderFrontRegardless()
                if !pinned.macWindow.isHiddenInCorner {
                    Task { await syncOverlayFrame(pinned) }
                }
            }
        }
    }

    private func syncOverlayFrame(_ pinned: PinnedWindow) async {
        guard let rect = try? await pinned.macWindow.getAxRect(.cancellable) else { return }
        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = mainScreenHeight - rect.topLeftY - rect.height
        let frame = NSRect(x: rect.topLeftX, y: cocoaY, width: rect.width, height: rect.height)
        guard pinned.overlayWindow.frame != frame else { return }

        pinned.overlayWindow.setFrame(frame, display: false)
        let monitor = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        let scaleFactor = Int(monitor?.backingScaleFactor ?? 2)
        try? await pinned.stream.updateConfiguration(makeStreamConfig(frame: frame, scaleFactor: scaleFactor))
    }

    func handleOverlayClicked(windowId: UInt32) {
        guard let pinned = pinnedWindows[windowId], let workspace = pinned.macWindow.nodeWorkspace else { return }
        Task {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.hotkeyBinding, token) {
                _ = workspace.focusWorkspace()
                _ = pinned.macWindow.focusWindow()
                pinned.macWindow.nativeFocus()
            }
        }
    }

    private func makeStreamConfig(frame: NSRect, scaleFactor: Int) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.width = max(1, Int(frame.width) * scaleFactor)
        streamConfig.height = max(1, Int(frame.height) * scaleFactor)
        // Thirty frames per second keeps the overlay responsive without doubling capture work.
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        streamConfig.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 3
        return streamConfig
    }
}

private struct PinnedWindow {
    let stream: SCStream
    let overlayWindow: OverlayPanel
    let macWindow: MacWindow
    // Retain the stream output for the lifetime of the stream.
    let streamOutput: OverlayStreamOutput
}

final class OverlayPanel: NSPanelHud {
    let displayView: OverlayDisplayView
    let pinnedWindowId: UInt32

    init(frame: NSRect, windowId: UInt32) {
        pinnedWindowId = windowId
        displayView = OverlayDisplayView(frame: frame)
        super.init()
        alphaValue = 0.99
        contentView = displayView
        setFrame(frame, display: true)
    }

    override func mouseDown(with _: NSEvent) {
        Task { @MainActor in OverlayManager.shared.handleOverlayClicked(windowId: pinnedWindowId) }
    }
}

final class OverlayDisplayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func updateSurface(_ surface: IOSurface) { layer?.contents = surface }
}

final class OverlayStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    nonisolated(unsafe) private weak var displayView: OverlayDisplayView?

    init(displayView: OverlayDisplayView) { unsafe self.displayView = displayView }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard let surface = unsafe CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let ioSurface = surface as IOSurface
        let displayView = unsafe displayView
        DispatchQueue.main.async { [weak displayView] in displayView?.updateSurface(ioSurface) }
    }
}
