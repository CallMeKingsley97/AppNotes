import SwiftUI
import AppKit

/// Shared motion. Default spring is critically damped; only interactive motion may bounce, and never past 0.2.
enum Motion {
    static let springResponse = 0.35
    static let springDamping = 1.0
    static let interactiveBounce = 0.2

    static var systemReduced: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    static func standard(reduced: Bool = systemReduced) -> Animation {
        spring(response: springResponse, reduced: reduced)
    }

    static func interactive(reduced: Bool = systemReduced) -> Animation {
        spring(response: springResponse, bounce: interactiveBounce, reduced: reduced)
    }

    /// Tab, app, and loaded-content crossfades. Opacity only.
    static func content(reduced: Bool = systemReduced) -> Animation {
        spring(response: 0.16, reduced: reduced)
    }

    /// Hover and press. Inside the 0.12–0.18s band.
    static func feedback(reduced: Bool = systemReduced) -> Animation {
        spring(response: 0.14, reduced: reduced)
    }

    /// Floating surfaces. Enter and exit use the same 0.24s path.
    static func panel(reduced: Bool = systemReduced) -> Animation {
        spring(response: 0.24, reduced: reduced)
    }

    static var panelSeconds: TimeInterval { systemReduced ? 0 : 0.24 }

    /// Keyboard selection reveal.
    static func scroll(reduced: Bool = systemReduced) -> Animation {
        spring(response: 0.18, reduced: reduced)
    }

    static func spring(response: Double, bounce: Double = 0, reduced: Bool = systemReduced) -> Animation {
        let limitedBounce = min(max(bounce, 0), interactiveBounce)
        let animation: Animation = limitedBounce == 0
            ? .spring(response: response, dampingFraction: springDamping)
            : .spring(duration: response, bounce: limitedBounce)
        return reduced ? .linear(duration: 0) : animation
    }
}

private struct MotionCrossfade<ID: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let id: ID

    func body(content: Content) -> some View {
        content.animation(Motion.content(reduced: reduceMotion), value: id)
    }
}

extension View {
    func motionCrossfade<ID: Equatable>(id: ID) -> some View {
        modifier(MotionCrossfade(id: id))
    }
}
