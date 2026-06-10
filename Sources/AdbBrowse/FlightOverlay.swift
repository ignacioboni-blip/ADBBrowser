import SwiftUI

/// A file icon that arcs across the window when a transfer starts —
/// from the browser toward the sidebar phone on pulls, the reverse on pushes.
struct FlightOverlay: View {
    let flights: [Flight]
    let accent: Color

    struct Flight: Identifiable, Equatable {
        let id: Int
        let isUpload: Bool
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(flights) { flight in
                FlightIcon(flight: flight, canvasSize: geo.size, accent: accent)
            }
        }
        .allowsHitTesting(false)
    }
}

private struct FlightIcon: View {
    let flight: FlightOverlay.Flight
    let canvasSize: CGSize
    let accent: Color

    @State private var t: CGFloat = 0
    @State private var faded = false

    var body: some View {
        // Device card sits at the top of the sidebar; browser center to its right.
        let phone = CGPoint(x: 110, y: 95)
        let browser = CGPoint(x: canvasSize.width * 0.58, y: canvasSize.height * 0.45)
        let from = flight.isUpload ? phone : browser
        let to = flight.isUpload ? browser : phone
        let control = CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 110)

        Image(systemName: flight.isUpload ? "arrow.up.doc.fill" : "doc.fill")
            .font(.system(size: 26))
            .foregroundStyle(accent)
            .shadow(color: accent.opacity(0.5), radius: 6)
            .scaleEffect(faded ? 0.35 : 1)
            .opacity(faded ? 0 : 1)
            .modifier(BezierFlightEffect(t: t, from: from, control: control, to: to))
            .onAppear {
                withAnimation(.easeInOut(duration: 0.85)) { t = 1 }
                withAnimation(.easeIn(duration: 0.85)) { faded = true }
            }
    }
}

/// Moves the view along a quadratic Bézier as `t` animates 0 → 1.
private struct BezierFlightEffect: GeometryEffect {
    var t: CGFloat
    let from: CGPoint
    let control: CGPoint
    let to: CGPoint

    var animatableData: CGFloat {
        get { t }
        set { t = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let u = 1 - t
        let x = u * u * from.x + 2 * u * t * control.x + t * t * to.x
        let y = u * u * from.y + 2 * u * t * control.y + t * t * to.y
        return ProjectionTransform(CGAffineTransform(translationX: x - size.width / 2,
                                                     y: y - size.height / 2))
    }
}
