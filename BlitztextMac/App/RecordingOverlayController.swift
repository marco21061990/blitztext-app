import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingOverlayController {
    fileprivate static let panelSize = NSSize(width: 178, height: 42)

    private let model = RecordingOverlayModel()
    private let stateProvider: () -> RecordingOverlayState
    private var panel: RecordingOverlayPanel?
    private var meteringTimer: Timer?
    private var isShown = false

    init(stateProvider: @escaping () -> RecordingOverlayState) {
        self.stateProvider = stateProvider
    }

    func update(with state: RecordingOverlayState) {
        apply(state)

        if state.isVisible {
            showPanel(for: state)
            startMetering()
        } else {
            hidePanel()
            stopMetering()
        }
    }

    func hide() {
        update(with: .hidden)
    }

    private func apply(_ state: RecordingOverlayState) {
        model.isVisible = state.isVisible
        model.audioLevel = state.audioLevel
    }

    private func startMetering() {
        guard meteringTimer == nil else { return }

        meteringTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let state = self.stateProvider()
                self.apply(state)
                if !state.isVisible {
                    self.hidePanel()
                    self.stopMetering()
                }
            }
        }
    }

    private func stopMetering() {
        meteringTimer?.invalidate()
        meteringTimer = nil
    }

    private func showPanel(for state: RecordingOverlayState) {
        let panel = ensurePanel()
        position(panel, for: state)

        if isShown {
            panel.orderFrontRegardless()
            return
        }

        isShown = true

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        guard isShown else {
            panel.orderOut(nil)
            return
        }

        isShown = false

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            guard self.isShown == false else { return }
            panel?.orderOut(nil)
        }
    }

    private func ensurePanel() -> RecordingOverlayPanel {
        if let panel {
            return panel
        }

        let panel = RecordingOverlayPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.contentViewController = NSHostingController(rootView: RecordingOverlayView(model: model))

        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, for state: RecordingOverlayState) {
        guard let screen = targetScreen(for: state) else { return }

        let visibleFrame = screen.visibleFrame
        let origin = NSPoint(
            x: visibleFrame.midX - Self.panelSize.width / 2,
            y: visibleFrame.maxY - Self.panelSize.height
        )

        panel.setFrame(NSRect(origin: origin, size: Self.panelSize), display: true)
    }

    private func targetScreen(for state: RecordingOverlayState) -> NSScreen? {
        if let targetScreenFrame = state.targetScreenFrame,
           let screen = NSScreen.screens.first(where: { $0.frame.equalTo(targetScreenFrame) }) {
            return screen
        }

        let mouseLocation = NSEvent.mouseLocation

        return NSScreen.screens.first { screen in
            NSMouseInRect(mouseLocation, screen.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
    }
}

private final class RecordingOverlayModel: ObservableObject {
    @Published var isVisible = false
    @Published var audioLevel: Float = 0
}

private final class RecordingOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct RecordingOverlayView: View {
    @ObservedObject var model: RecordingOverlayModel
    private let waveColor = Color(red: 0.21, green: 0.89, blue: 0.53)

    var body: some View {
        ZStack {
            WaveformView(
                audioLevel: model.audioLevel,
                isRecording: model.isVisible,
                accentColor: waveColor,
                barCount: 12,
                maxBarHeight: 22,
                barWidth: 3
            )
            .frame(width: 106, height: 24)
            .accessibilityHidden(true)
        }
        .frame(width: RecordingOverlayController.panelSize.width, height: RecordingOverlayController.panelSize.height)
        .background(
            RecordingOverlayNotchShape(radius: 23)
                .fill(Color.black.opacity(0.92))
        )
        .overlay {
            RecordingOverlayNotchShape(radius: 23)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.08), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .overlay {
            RecordingOverlayNotchShape(radius: 23)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.34), radius: 21, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Blitztext Aufnahme läuft")
    }
}

private struct RecordingOverlayNotchShape: InsettableShape {
    var radius: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let resolvedRadius = min(radius, rect.width / 2, rect.height)

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - resolvedRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - resolvedRadius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + resolvedRadius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - resolvedRadius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> RecordingOverlayNotchShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}
