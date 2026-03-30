import AppKit
import Common
import ScreenCaptureKit

@MainActor
final class OverlayManager {
    static let shared = OverlayManager()
    private var pinnedWindows: [UInt32: PinnedWindow] = [:]

    private init() {}

    var hasPinnedWindows: Bool { !pinnedWindows.isEmpty }

    func isPinned(windowId: UInt32) -> Bool {
        pinnedWindows[windowId] != nil
    }

    func pin(windowId: UInt32, frame: NSRect, macWindow: MacWindow) async -> Bool {
        guard !isPinned(windowId: windowId) else { return true }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowId }) else { return false }

            let monitor = monitorForFrame(frame)
            let scaleFactor = Int(monitor?.backingScaleFactor ?? 2)

            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(frame.width) * scaleFactor
            config.height = Int(frame.height) * scaleFactor
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false

            let overlayWindow = OverlayPanel(frame: frame, windowId: windowId)
            let output = OverlayStreamOutput(displayView: overlayWindow.displayView)
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)

            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
            try await stream.startCapture()

            pinnedWindows[windowId] = PinnedWindow(
                stream: stream,
                overlayWindow: overlayWindow,
                macWindow: macWindow,
                streamOutput: output,
                lastFrame: frame,
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

    /// Called from MacWindow.garbageCollect when a pinned window is destroyed.
    nonisolated func handleWindowClosed(windowId: UInt32) {
        Task { @MainActor in
            guard let pinned = pinnedWindows.removeValue(forKey: windowId) else { return }
            try? await pinned.stream.stopCapture()
            pinned.overlayWindow.close()
        }
    }

    /// Update overlay visibility and position on every focus change.
    func updateOverlayState() {
        let focusedWindowId = focus.windowOrNil?.windowId
        for (windowId, pinned) in pinnedWindows {
            if focusedWindowId == windowId {
                pinned.overlayWindow.orderOut(nil)
            } else {
                Task { await syncOverlayFrame(windowId: windowId) }
            }
        }
    }

    /// Sync overlay frame and stream resolution to match the real window's current position/monitor.
    private func syncOverlayFrame(windowId: UInt32) async {
        guard let pinned = pinnedWindows[windowId] else { return }
        guard let rect = try? await pinned.macWindow.getAxRect() else { return }

        let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = mainScreenHeight - rect.topLeftY - rect.height
        let frame = NSRect(x: rect.topLeftX, y: cocoaY, width: rect.width, height: rect.height)

        if frame != pinned.lastFrame {
            pinnedWindows[windowId]?.lastFrame = frame
            pinned.overlayWindow.setFrame(frame, display: false)

            let monitor = monitorForFrame(frame)
            let scaleFactor = Int(monitor?.backingScaleFactor ?? 2)
            let config = SCStreamConfiguration()
            config.width = Int(frame.width) * scaleFactor
            config.height = Int(frame.height) * scaleFactor
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.showsCursor = false
            try? await pinned.stream.updateConfiguration(config)
        }

        pinned.overlayWindow.orderFrontRegardless()
    }

    /// Called when an overlay is clicked — navigate to the pinned window's workspace and focus it.
    func handleOverlayClicked(windowId: UInt32) {
        guard let pinned = pinnedWindows[windowId] else { return }
        guard let workspace = pinned.macWindow.nodeWorkspace else { return }
        Task {
            guard let token: RunSessionGuard = .isServerEnabled else { return }
            try await runLightSession(.hotkeyBinding, token) {
                workspace.focusWorkspace()
                _ = pinned.macWindow.focusWindow()
                pinned.macWindow.nativeFocus()
            }
        }
    }

    /// Find which NSScreen contains the given Cocoa frame.
    private func monitorForFrame(_ frame: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
    }
}

private struct PinnedWindow {
    let stream: SCStream
    let overlayWindow: OverlayPanel
    let macWindow: MacWindow
    let streamOutput: OverlayStreamOutput
    var lastFrame: NSRect
}

final class OverlayPanel: NSPanelHud {
    let displayView: OverlayDisplayView
    let pinnedWindowId: UInt32

    init(frame: NSRect, windowId: UInt32) {
        self.pinnedWindowId = windowId
        self.displayView = OverlayDisplayView(frame: frame)
        super.init()
        self.contentView = displayView
        self.setFrame(frame, display: true)
    }

    override func mouseDown(with event: NSEvent) {
        Task { @MainActor in
            OverlayManager.shared.handleOverlayClicked(windowId: pinnedWindowId)
        }
    }
}

final class OverlayDisplayView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        self.wantsLayer = true
        self.layer?.contentsGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    func updateSurface(_ surface: IOSurface) {
        self.layer?.contents = surface
    }
}

final class OverlayStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private weak var displayView: OverlayDisplayView?

    init(displayView: OverlayDisplayView) {
        self.displayView = displayView
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue() else { return }
        let ioSurface = surface as IOSurface
        DispatchQueue.main.async { [weak displayView] in
            displayView?.updateSurface(ioSurface)
        }
    }
}
