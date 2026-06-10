import SwiftUI

struct DeviceSidebarView: View {
    @ObservedObject var model: BrowserViewModel

    var body: some View {
        List {
            Section {
                deviceCard
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }
            Section("Places") {
                ForEach(BrowserViewModel.places, id: \.path) { place in
                    let isCurrent = model.currentPath == place.path
                    Button {
                        model.navigate(to: place.path)
                    } label: {
                        Label {
                            Text(place.name)
                                .fontWeight(isCurrent ? .semibold : .regular)
                        } icon: {
                            Image(systemName: place.icon)
                                .foregroundStyle(isCurrent ? model.accent : Color.secondary)
                        }
                        .foregroundStyle(isCurrent ? model.accent : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isCurrent ? model.accent.opacity(0.22) : Color.clear)
                            .padding(.horizontal, 6)
                    )
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Live device card

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: "iphone.gen3")
                    .foregroundStyle(model.accent)
                if let device = model.devices.first(where: { $0.serial == model.selectedSerial }) {
                    Text(device.model.replacingOccurrences(of: "_", with: " "))
                        .font(.headline)
                }
                Spacer()
                if let level = model.deviceStatus.batteryLevel {
                    HStack(spacing: 3) {
                        if model.deviceStatus.isCharging {
                            Image(systemName: "bolt.fill").font(.caption2)
                        }
                        Image(systemName: model.deviceStatus.batteryIcon)
                        Text("\(level)%")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .foregroundStyle(model.deviceStatus.isCharging ? model.accent : .secondary)
                }
            }

            if let used = model.deviceStatus.usedFraction, let text = model.deviceStatus.storageText {
                VStack(alignment: .leading, spacing: 3) {
                    ProgressView(value: used)
                        .tint(model.accent)
                        .controlSize(.small)
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let theme = model.theme {
                HStack(spacing: 6) {
                    ForEach(Array(theme.stops.enumerated()), id: \.offset) { _, stop in
                        RoundedRectangle(cornerRadius: 4.5)
                            .fill(stop)
                            .frame(width: 16, height: 16)
                            .overlay(RoundedRectangle(cornerRadius: 4.5).strokeBorder(.quaternary, lineWidth: 0.5))
                    }
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.4))
        )
    }
}

// MARK: - Breadcrumb path bar

struct BreadcrumbBar: View {
    @ObservedObject var model: BrowserViewModel
    @FocusState private var pathFocused: Bool

    var body: some View {
        if model.isEditingPath {
            TextField("Path", text: $model.pathFieldText)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 280, idealWidth: 420)
                .focused($pathFocused)
                .onSubmit { model.navigate(to: model.pathFieldText) }
                .onExitCommand {
                    model.pathFieldText = model.currentPath
                    model.isEditingPath = false
                }
                .onAppear { pathFocused = true }
        } else {
            HStack(spacing: 0) {
                let segments = model.pathSegments
                let visible = segments.count > 4 ? Array(segments.suffix(4)) : segments

                if segments.count > 4 {
                    Menu {
                        ForEach(segments.dropLast(4)) { seg in
                            Button(seg.name == "/" ? "Device root /" : seg.name) {
                                model.navigate(to: seg.path)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    chevron
                }

                ForEach(Array(visible.enumerated()), id: \.element.id) { i, seg in
                    if i > 0 { chevron }
                    crumb(seg, isLast: seg.path == model.currentPath)
                }

                Button {
                    model.pathFieldText = model.currentPath
                    model.isEditingPath = true
                } label: {
                    Image(systemName: "character.cursor.ibeam")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.leading, 6)
                .help("Edit path (⇧⌘G)")
            }
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.compact.right")
            .font(.caption)
            .foregroundStyle(.quaternary)
            .padding(.horizontal, 1)
    }

    @ViewBuilder
    private func crumb(_ seg: PathSegment, isLast: Bool) -> some View {
        CrumbButton(segment: seg, isLast: isLast, accent: model.accent) {
            model.navigate(to: seg.path)
        }
    }
}

private struct CrumbButton: View {
    let segment: PathSegment
    let isLast: Bool
    let accent: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if segment.name == "/" {
                    Image(systemName: "iphone.gen3")
                } else {
                    Text(segment.name)
                        .lineLimit(1)
                }
            }
            .font(.callout)
            .fontWeight(isLast ? .semibold : .regular)
            .padding(.horizontal, 10)
            .padding(.vertical, 3.5)
            .background(
                Capsule().fill(isLast ? accent : (hovering ? accent.opacity(0.18) : Color.clear))
            )
            .foregroundStyle(isLast ? accent.contrastingText : (hovering ? accent : Color.secondary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(isLast ? "Current folder — \(segment.path)" : "Go to \(segment.path)")
    }
}
