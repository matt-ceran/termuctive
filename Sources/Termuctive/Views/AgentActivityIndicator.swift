import AppKit
import QuartzCore
import SwiftUI

struct AgentActivityStatusSlot: View {
    @ObservedObject private var signal: AgentActivitySignal

    let isPresented: Bool
    let isVisible: Bool
    let selected: Bool
    let reduceMotionOverride: Bool?

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @MainActor
    init(
        registry: AgentActivityRegistry,
        scope: AgentActivityScope,
        isPresented: Bool,
        isVisible: Bool,
        selected: Bool,
        reduceMotionOverride: Bool? = nil
    ) {
        _signal = ObservedObject(wrappedValue: registry.signal(for: scope))
        self.isPresented = isPresented
        self.isVisible = isVisible
        self.selected = selected
        self.reduceMotionOverride = reduceMotionOverride
    }

    var body: some View {
        let summary = isPresented ? signal.summary : .absent
        AgentActivityGlyph(
            summary: summary,
            selected: selected,
            animates: isVisible && isPresented,
            reduceMotion: reduceMotionOverride ?? reduceMotion,
            increasedContrast: colorSchemeContrast == .increased
        )
        .frame(width: 14, height: 14)
        .help(summary.helpText)
        .accessibilityHidden(true)
    }
}

struct AgentActivityAccessibleRow<Content: View>: View {
    @ObservedObject private var signal: AgentActivitySignal

    let isPresented: Bool
    private let content: Content

    @MainActor
    init(
        registry: AgentActivityRegistry,
        scope: AgentActivityScope,
        isPresented: Bool,
        @ViewBuilder content: () -> Content
    ) {
        _signal = ObservedObject(wrappedValue: registry.signal(for: scope))
        self.isPresented = isPresented
        self.content = content()
    }

    var body: some View {
        content.accessibilityValue(isPresented ? signal.summary.accessibilityValue : "")
    }
}

private struct AgentActivityGlyph: NSViewRepresentable {
    let summary: AgentActivitySummary
    let selected: Bool
    let animates: Bool
    let reduceMotion: Bool
    let increasedContrast: Bool

    func makeNSView(context: Context) -> AgentActivityGlyphView {
        AgentActivityGlyphView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    }

    func updateNSView(_ view: AgentActivityGlyphView, context: Context) {
        view.configure(
            summary: summary,
            selected: selected,
            animates: animates,
            reduceMotion: reduceMotion,
            increasedContrast: increasedContrast
        )
    }
}

private final class AgentActivityGlyphView: NSView {
    private struct Configuration: Equatable {
        let summary: AgentActivitySummary
        let selected: Bool
        let animates: Bool
        let reduceMotion: Bool
        let increasedContrast: Bool
    }

    private let outlineLayer = CAShapeLayer()
    private let dotLayers = (0..<3).map { _ in CAShapeLayer() }
    private var configuration: Configuration?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false
        outlineLayer.fillColor = NSColor.clear.cgColor
        layer?.addSublayer(outlineLayer)
        for dotLayer in dotLayers {
            layer?.addSublayer(dotLayer)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let outlineRect = bounds.insetBy(dx: 1, dy: 1)
        outlineLayer.path = CGPath(
            roundedRect: outlineRect,
            cornerWidth: 2.5,
            cornerHeight: 2.5,
            transform: nil
        )
        let dotCenters: [CGFloat] = [3.5, 7, 10.5]
        for (dotLayer, centerX) in zip(dotLayers, dotCenters) {
            dotLayer.path = CGPath(
                ellipseIn: CGRect(x: centerX - 1, y: 6, width: 2, height: 2),
                transform: nil
            )
        }
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard let configuration else {
            return
        }
        self.configuration = nil
        apply(configuration)
    }

    func configure(
        summary: AgentActivitySummary,
        selected: Bool,
        animates: Bool,
        reduceMotion: Bool,
        increasedContrast: Bool
    ) {
        let configuration = Configuration(
            summary: summary,
            selected: selected,
            animates: animates,
            reduceMotion: reduceMotion,
            increasedContrast: increasedContrast
        )
        guard self.configuration != configuration else {
            return
        }
        apply(configuration)
    }

    private func apply(_ configuration: Configuration) {
        self.configuration = configuration
        let summary = configuration.summary
        let color: NSColor
        switch summary.phase {
        case .absent:
            color = .secondaryLabelColor
        case .active:
            color = configuration.selected ? .labelColor : .controlAccentColor
        }

        effectiveAppearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.12)
            outlineLayer.strokeColor = color.cgColor
            outlineLayer.lineWidth = configuration.increasedContrast ? 1.35 : 1
            outlineLayer.opacity = outlineOpacity(for: summary.phase)
            for dotLayer in dotLayers {
                dotLayer.fillColor = color.cgColor
            }
            CATransaction.commit()
        }

        stopDotAnimation()
        switch summary.phase {
        case .absent:
            setDotOpacities([0, 0, 0])
        case .active:
            setDotOpacities([1, 0.46, 0.16])
            if configuration.animates && !configuration.reduceMotion {
                startDotAnimation()
            }
        }
    }

    private func outlineOpacity(for phase: TerminalAgentActivityPhase) -> Float {
        switch phase {
        case .absent:
            0
        case .active:
            0.85
        }
    }

    private func setDotOpacities(_ opacities: [Float]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (dotLayer, opacity) in zip(dotLayers, opacities) {
            dotLayer.opacity = opacity
        }
        CATransaction.commit()
    }

    private func startDotAnimation() {
        let values: [[NSNumber]] = [
            [1, 0.46, 0.16, 1],
            [0.16, 1, 0.46, 0.16],
            [0.46, 0.16, 1, 0.46],
        ]
        for (dotLayer, dotValues) in zip(dotLayers, values) {
            let animation = CAKeyframeAnimation(keyPath: "opacity")
            animation.values = dotValues
            animation.keyTimes = [0, 0.333, 0.667, 1]
            animation.duration = 0.9
            animation.repeatCount = .infinity
            animation.calculationMode = .linear
            dotLayer.add(animation, forKey: "termuctive-dot-tail")
        }
    }

    private func stopDotAnimation() {
        for dotLayer in dotLayers {
            dotLayer.removeAnimation(forKey: "termuctive-dot-tail")
        }
    }
}
