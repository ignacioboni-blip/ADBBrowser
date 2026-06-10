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
        let isSelected = model.selection.contains(file.id)
        return VStack(spacing: compact ? 4 : 6) {
            ZStack {
                if !ThumbnailStore.canThumbnail(file) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.quaternary.opacity(0.5))
                }
                FileThumbView(file: file, model: model, side: thumbSide)
            }
            .frame(width: thumbSide, height: thumbSide)

            Text(file.name)
                .font(compact ? .caption2 : .caption)
                .lineLimit(compact ? 1 : 2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? model.accent : Color.primary)
        }
        .padding(compact ? 5 : 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? model.accent.opacity(0.14) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? model.accent.opacity(0.6) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
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
