import SwiftUI

// MARK: - Usage tree

struct UsageNode: Equatable {
    let name: String
    let path: String
    let bytes: Int64
    var children: [UsageNode] = []

    static func build(root: String, entries: [(path: String, bytes: Int64)]) -> UsageNode? {
        var byParent: [String: [(String, Int64)]] = [:]
        var rootBytes: Int64 = 0
        for (p, b) in entries {
            if p == root {
                rootBytes = b
                continue
            }
            var parent = (p as NSString).deletingLastPathComponent
            if parent.isEmpty { parent = "/" }
            byParent[parent, default: []].append((p, b))
        }
        guard rootBytes > 0 else { return nil }

        func node(path: String, bytes: Int64) -> UsageNode {
            let kids = (byParent[path] ?? [])
                .sorted { $0.1 > $1.1 }
                .map { node(path: $0.0, bytes: $0.1) }
            return UsageNode(name: (path as NSString).lastPathComponent, path: path, bytes: bytes, children: kids)
        }
        return node(path: root, bytes: rootBytes)
    }
}

// MARK: - Radial layout

struct SunArc: Equatable {
    let path: String
    let name: String
    let bytes: Int64
    let depth: Int          // 1...maxDepth (ring index)
    let start: Double       // radians, from -π/2
    let end: Double
    let hue: Double
    let fraction: Double    // of the whole tree
}

enum SunburstLayout {
    static let maxDepth = 3
    static let minSpan = 0.015   // rad (~0.85°) — thinner slivers are skipped

    static func arcs(tree: UsageNode, accentHue: Double) -> [SunArc] {
        guard tree.bytes > 0 else { return [] }
        var result: [SunArc] = []
        // Analogous hues around the phone's accent, cycled per top-level wedge.
        let offsets: [Double] = [0, 0.055, -0.055, 0.11, -0.11, 0.165, -0.165, 0.22]

        func recurse(_ node: UsageNode, depth: Int, start: Double, span: Double, hue: Double) {
            guard depth < maxDepth, node.bytes > 0 else { return }
            var cursor = start
            for (i, child) in node.children.enumerated() {
                let childSpan = span * Double(child.bytes) / Double(node.bytes)
                let childHue = depth == 0
                    ? (accentHue + offsets[i % offsets.count]).truncatingRemainder(dividingBy: 1)
                    : hue
                if childSpan >= minSpan {
                    result.append(SunArc(
                        path: child.path, name: child.name, bytes: child.bytes,
                        depth: depth + 1, start: cursor, end: cursor + childSpan,
                        hue: childHue < 0 ? childHue + 1 : childHue,
                        fraction: Double(child.bytes) / Double(tree.bytes)
                    ))
                    recurse(child, depth: depth + 1, start: cursor, span: childSpan, hue: childHue)
                }
                cursor += childSpan
            }
        }
        recurse(tree, depth: 0, start: -.pi / 2, span: 2 * .pi, hue: accentHue)
        return result
    }
}

// MARK: - View

struct SunburstView: View {
    @ObservedObject var model: BrowserViewModel

    @State private var hoveredPath: String?
    @State private var revealStart: Date?
    @State private var isRevealing = false

    var body: some View {
        Group {
            if let tree = model.usageTree {
                chart(tree)
            } else if model.isMeasuring {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Measuring \(model.currentPath)…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Usage Data", systemImage: "chart.pie")
                } actions: {
                    Button("Measure") { model.loadUsage(force: true) }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .task(id: model.currentPath) {
            model.loadUsage()
        }
        .onChange(of: model.usageTree) { _, new in
            if new != nil { startReveal() }
        }
        .onAppear {
            if model.usageTree != nil { startReveal() }
        }
    }

    private func chart(_ tree: UsageNode) -> some View {
        let arcs = SunburstLayout.arcs(tree: tree, accentHue: accentHue)
        return GeometryReader { geo in
            let geom = Geom(size: geo.size)
            ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !isRevealing)) { timeline in
                    Canvas { ctx, size in
                        draw(arcs, in: &ctx, geom: Geom(size: size), reveal: reveal(at: timeline.date))
                    }
                }
                centerLabel(tree, arcs: arcs)
                    .frame(width: geom.holeRadius * 1.9, height: geom.holeRadius * 1.9)
                    .position(geom.center)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                if let arc = hitTest(arcs, point: location, geom: geom) {
                    model.openFromSunburst(arc.path)
                } else if hypot(location.x - geom.center.x, location.y - geom.center.y) < geom.holeRadius {
                    model.goUp()
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoveredPath = hitTest(arcs, point: point, geom: geom)?.path
                case .ended:
                    hoveredPath = nil
                }
            }
        }
        .padding(12)
        .overlay(alignment: .topTrailing) {
            Button {
                model.loadUsage(force: true)
            } label: {
                Label("Measure Again", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .padding(10)
        }
    }

    private func centerLabel(_ tree: UsageNode, arcs: [SunArc]) -> some View {
        let hovered = hoveredPath.flatMap { p in arcs.first(where: { $0.path == p }) }
        return VStack(spacing: 2) {
            Text(hovered?.name ?? ((model.currentPath as NSString).lastPathComponent.isEmpty
                                   ? "/" : (model.currentPath as NSString).lastPathComponent))
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(ByteCountFormatter.string(fromByteCount: hovered?.bytes ?? tree.bytes, countStyle: .file))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let hovered {
                Text("\(Int((hovered.fraction * 100).rounded()))%")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if model.canGoUp {
                Text("click to go up")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: drawing & geometry

    private struct Geom {
        let center: CGPoint
        let holeRadius: CGFloat
        let band: CGFloat

        init(size: CGSize) {
            center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = max(40, min(size.width, size.height) / 2 - 10)
            holeRadius = outer * 0.27
            band = (outer - holeRadius) / CGFloat(SunburstLayout.maxDepth)
        }
    }

    private func draw(_ arcs: [SunArc], in ctx: inout GraphicsContext, geom: Geom, reveal: Double) {
        let sweepEnd = -Double.pi / 2 + 2 * .pi * reveal
        for arc in arcs {
            guard arc.start < sweepEnd else { continue }
            let end = min(arc.end, sweepEnd)
            let isHovered = arc.path == hoveredPath
            let rIn = geom.holeRadius + geom.band * CGFloat(arc.depth - 1) + 1
            var rOut = geom.holeRadius + geom.band * CGFloat(arc.depth) - 1.5
            if isHovered { rOut += 4 }

            var path = Path()
            path.addArc(center: geom.center, radius: rOut,
                        startAngle: .radians(arc.start), endAngle: .radians(end), clockwise: false)
            path.addArc(center: geom.center, radius: rIn,
                        startAngle: .radians(end), endAngle: .radians(arc.start), clockwise: true)
            path.closeSubpath()

            let brightness = 0.92 - 0.13 * Double(arc.depth - 1) + (isHovered ? 0.1 : 0)
            let saturation = 0.62 - 0.07 * Double(arc.depth - 1)
            ctx.fill(path, with: .color(Color(hue: arc.hue, saturation: saturation, brightness: brightness)))
        }
    }

    private func hitTest(_ arcs: [SunArc], point: CGPoint, geom: Geom) -> SunArc? {
        let dx = point.x - geom.center.x
        let dy = point.y - geom.center.y
        let r = hypot(dx, dy)
        guard r >= geom.holeRadius else { return nil }
        let ring = Int((r - geom.holeRadius) / geom.band) + 1
        guard ring <= SunburstLayout.maxDepth else { return nil }
        var angle = Double(atan2(dy, dx))
        if angle < -.pi / 2 { angle += 2 * .pi }
        return arcs.first { $0.depth == ring && angle >= $0.start && angle < $0.end }
    }

    private var accentHue: Double {
        guard let ns = NSColor(model.accent).usingColorSpace(.deviceRGB) else { return 0.6 }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return Double(h)
    }

    private func reveal(at date: Date) -> Double {
        guard let start = revealStart else { return 1 }
        let t = date.timeIntervalSince(start) / 0.9
        return min(1, max(0, t * t * (3 - 2 * t) * 1.2))   // smoothstep, slightly hurried
    }

    private func startReveal() {
        revealStart = Date()
        isRevealing = true
        Task {
            try? await Task.sleep(for: .seconds(1.1))
            isRevealing = false
        }
    }
}
