import SwiftUI

/// Icon or photo thumbnail for a remote file; loads lazily via the store.
struct FileThumbView: View {
    let file: RemoteFile
    @ObservedObject var model: BrowserViewModel
    let side: CGFloat

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: max(3, side * 0.12)))
            } else {
                Image(systemName: file.icon)
                    .font(.system(size: side * 0.62))
                    .foregroundStyle(file.isDirectory ? model.accent : Color.secondary)
                    .frame(width: side, height: side)
            }
        }
        .task(id: file.id) {
            if image == nil, ThumbnailStore.canThumbnail(file) {
                image = await model.thumbnail(for: file)
            }
        }
    }
}

struct FileGridView: View {
    @ObservedObject var model: BrowserViewModel
    var contextMenuBuilder: ([RemoteFile]) -> AnyView

    private var compact: Bool { model.density == .compact }
    private var thumbSide: CGFloat { compact ? 62 : 88 }
    private var gridSpacing: CGFloat { compact ? 8 : 12 }

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: compact ? 84 : 110, maximum: compact ? 116 : 150),
                                spacing: gridSpacing)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: gridSpacing) {
                ForEach(model.visibleEntries) { file in
                    cell(file)
                        .contextMenu { contextMenuBuilder([file]) }
                }
            }
            .padding(compact ? 10 : 14)
        }
        .contextMenu { contextMenuBuilder([]) }
    }

    private func cell(_ file: RemoteFile) -> some View {
        GridCell(file: file, model: model, compact: compact, thumbSide: thumbSide)
    }
}

private struct GridCell: View {
    let file: RemoteFile
    @ObservedObject var model: BrowserViewModel
    let compact: Bool
    let thumbSide: CGFloat

    @State private var hovering = false

    var body: some View {
        let isSelected = model.selection.contains(file.id)
        VStack(spacing: compact ? 4 : 6) {
            ZStack {
                if !ThumbnailStore.canThumbnail(file) {
                    RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                        .fill(file.isDirectory
                              ? model.accent.opacity(DS.tonalFaint)
                              : Color.secondary.opacity(0.07))
                }
                FileThumbView(file: file, model: model, side: thumbSide)
            }
            .frame(width: thumbSide, height: thumbSide)
            .scaleEffect(hovering && !isSelected ? 1.03 : 1)

            Text(file.name)
                .font(compact ? .caption2 : .caption)
                .lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? model.accent : Color.primary)
                .fontWeight(isSelected ? .medium : .regular)
        }
        .padding(compact ? 5 : 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.cornerLarge, style: .continuous)
                .fill(isSelected
                      ? model.accent.opacity(DS.tonal)
                      : hovering ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerLarge, style: .continuous)
                .strokeBorder(isSelected ? model.accent.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.13), value: hovering)
        .draggable(file)
        .gesture(TapGesture(count: 2).onEnded { model.activate(file) })
        .simultaneousGesture(TapGesture().onEnded {
            if NSEvent.modifierFlags.contains(.command) {
                if model.selection.contains(file.id) {
                    model.selection.remove(file.id)
                } else {
                    model.selection.insert(file.id)
                }
            } else {
                model.selection = [file.id]
            }
        })
    }
}
