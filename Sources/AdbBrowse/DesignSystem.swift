import SwiftUI

// MARK: - Design tokens
//
// A small Material-3-flavored system: tonal accent surfaces, expressive
// corner radii, and a handful of shared components so every sheet, chip,
// and search field in the app reads as one family.

enum DS {
    /// Shape scale (Material 3: extra-small → extra-large).
    static let cornerSmall: CGFloat = 8
    static let corner: CGFloat = 12
    static let cornerLarge: CGFloat = 16
    static let cornerXL: CGFloat = 24

    /// Standard tonal-container opacities over the system surface.
    static let tonal: Double = 0.14
    static let tonalStrong: Double = 0.22
    static let tonalFaint: Double = 0.07
}

// MARK: - Tonal icon badge

/// A rounded-square icon container — the anchor of every sheet header.
struct TonalIconBadge: View {
    let icon: String
    let tint: Color
    var side: CGFloat = 34

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: side * 0.47, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: side * 0.32, style: .continuous)
                    .fill(tint.opacity(DS.tonal))
            )
    }
}

// MARK: - Sheet header

/// Unified chrome for tool sheets: tonal icon badge, title/subtitle, actions.
struct SheetHeader<Actions: View>: View {
    let title: String
    var subtitle: String?
    let icon: String
    let tint: Color
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            TonalIconBadge(icon: icon, tint: tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) { actions() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.bar)
    }
}

// MARK: - Search pill

/// Material-style pill search/filter field.
struct SearchPillField<Trailing: View>: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    let tint: Color
    var focused: FocusState<Bool>.Binding?
    var onExit: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    init(icon: String = "magnifyingglass",
         placeholder: String,
         text: Binding<String>,
         tint: Color,
         focused: FocusState<Bool>.Binding? = nil,
         onExit: (() -> Void)? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.icon = icon
        self.placeholder = placeholder
        self._text = text
        self.tint = tint
        self.focused = focused
        self.onExit = onExit
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.callout)
                .foregroundStyle(text.isEmpty ? Color.secondary : tint)
            field
            trailing()
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(text.isEmpty ? Color.clear : tint.opacity(0.45), lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
    }

    @ViewBuilder
    private var field: some View {
        let base = TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
        if let focused {
            base
                .focused(focused)
                .onExitCommand { onExit?() }
        } else {
            base
                .onExitCommand { onExit?() }
        }
    }
}

// MARK: - Keycap hint

/// Small keyboard-shortcut / hint chip ("↩", "open").
struct KeycapHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.quaternary.opacity(0.6))
            )
    }
}

// MARK: - Empty state

/// Expressive empty state: big tonal icon, clear title, actions.
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    let message: String
    let tint: Color
    @ViewBuilder var actions: () -> Actions

    init(icon: String, title: String, message: String, tint: Color,
         @ViewBuilder actions: @escaping () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 88, height: 88)
                .background(
                    Circle().fill(tint.opacity(DS.tonalFaint * 1.4))
                )
                .overlay(
                    Circle().strokeBorder(tint.opacity(0.16), lineWidth: 1)
                )
                .padding(.bottom, 18)
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.bottom, 6)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .padding(.bottom, 18)
            HStack(spacing: 10) { actions() }
        }
        .padding(24)
        .frame(maxHeight: .infinity)
    }
}
