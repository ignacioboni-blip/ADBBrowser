import SwiftUI

struct GetInfoSheet: View {
    let file: RemoteFile
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var octal: String
    @State private var owner: String
    @State private var group: String
    @State private var measuredSize: Int64?
    @State private var isMeasuring = false

    private let originalOctal: String
    private let permsEditable: Bool

    init(file: RemoteFile, model: BrowserViewModel) {
        self.file = file
        self.model = model
        let parsed = Self.octalFromPermissions(file.permissions)
        originalOctal = parsed ?? ""
        permsEditable = parsed != nil
        _octal = State(initialValue: parsed ?? "")
        _owner = State(initialValue: file.owner)
        _group = State(initialValue: file.group)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: file.icon)
                    .font(.system(size: 28))
                    .foregroundStyle(model.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).font(.headline).lineLimit(2)
                    Text(kindLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.bottom, 12)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                infoRow("Path") {
                    HStack(spacing: 6) {
                        Text(file.path)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(file.path, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("Copy path")
                    }
                }

                infoRow("Size") {
                    if let measured = measuredSize {
                        Text(ByteCountFormatter.string(fromByteCount: measured, countStyle: .file))
                    } else if file.type == .file {
                        Text(file.sizeText)
                    } else if isMeasuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Calculate…") {
                            isMeasuring = true
                            Task {
                                measuredSize = await model.measureSize(of: file)
                                isMeasuring = false
                            }
                        }
                        .controlSize(.small)
                    }
                }

                infoRow("Modified") { Text(file.modified) }

                if let target = file.linkTarget {
                    infoRow("Links to") {
                        Text(target)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }

                Divider().gridCellUnsizedAxes(.horizontal)

                infoRow("Owner") {
                    HStack(spacing: 6) {
                        TextField("owner", text: $owner)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                        Text(":").foregroundStyle(.secondary)
                        TextField("group", text: $group)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 110)
                    }
                }

                infoRow("Permissions") {
                    if permsEditable {
                        VStack(alignment: .leading, spacing: 6) {
                            permissionToggles
                            HStack(spacing: 6) {
                                Text("Octal")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                TextField("0644", text: $octal)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 70)
                                Text(file.permissions)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    } else {
                        Text(file.permissions).font(.system(.body, design: .monospaced))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!hasChanges)
            }
            .padding(.top, 14)
        }
        .padding(18)
        .frame(width: 440)
    }

    // MARK: pieces

    @ViewBuilder
    private func infoRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content()
                .gridColumnAlignment(.leading)
        }
    }

    private var permissionToggles: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 2) {
            GridRow {
                Text("")
                Text("r").font(.caption).foregroundStyle(.secondary)
                Text("w").font(.caption).foregroundStyle(.secondary)
                Text("x").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(["Owner", "Group", "Other"].enumerated()), id: \.offset) { triad, label in
                GridRow {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    ForEach(0..<3, id: \.self) { bit in
                        Toggle("", isOn: bitBinding(triad: triad, bit: bit))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    /// Toggles read/write the low three octal digits; a special-bits digit
    /// (setuid/setgid/sticky) in front is preserved untouched.
    private func bitBinding(triad: Int, bit: Int) -> Binding<Bool> {
        Binding(
            get: {
                let digits = lowDigits()
                guard digits.count == 3 else { return false }
                let value = digits[triad]
                return value & (4 >> bit) != 0
            },
            set: { on in
                var digits = lowDigits()
                guard digits.count == 3 else { return }
                if on { digits[triad] |= (4 >> bit) } else { digits[triad] &= ~(4 >> bit) }
                let prefix = octal.count == 4 ? String(octal.first!) : ""
                octal = prefix + digits.map(String.init).joined()
            }
        )
    }

    private func lowDigits() -> [Int] {
        let low = octal.suffix(3)
        guard low.count == 3 else { return [] }
        return low.compactMap { $0.wholeNumberValue }
    }

    private var hasChanges: Bool {
        (permsEditable && octal != originalOctal && octal.count >= 3)
            || owner != file.owner || group != file.group
    }

    private func apply() {
        let newOctal = (permsEditable && octal != originalOctal) ? octal : nil
        let newOwner = (owner != file.owner || group != file.group) ? "\(owner):\(group)" : nil
        dismiss()
        model.applyFileInfo(file, octal: newOctal, ownerGroup: newOwner)
    }

    private var kindLabel: String {
        switch file.type {
        case .directory: return "Folder"
        case .file: return "File"
        case .symlink: return "Symbolic link"
        case .blockDevice: return "Block device"
        case .charDevice: return "Character device"
        case .socket: return "Socket"
        case .fifo: return "Named pipe"
        case .unknown: return "Unknown"
        }
    }

    /// "drwxrws--x" → "2771"-style octal (with special-bits digit when set).
    static func octalFromPermissions(_ perms: String) -> String? {
        let chars = Array(perms)
        guard chars.count >= 10 else { return nil }
        var digits = [0, 0, 0]
        var special = 0
        for triad in 0..<3 {
            for bit in 0..<3 {
                let c = chars[1 + triad * 3 + bit]
                if c == "?" { return nil }
                let isSet: Bool
                switch c {
                case "r", "w", "x": isSet = true
                case "s", "t": isSet = true     // executable + special bit
                case "S", "T": isSet = false    // special bit only
                default: isSet = false
                }
                if isSet { digits[triad] |= (4 >> bit) }
                if bit == 2 {
                    if triad == 0 && (c == "s" || c == "S") { special |= 4 }
                    if triad == 1 && (c == "s" || c == "S") { special |= 2 }
                    if triad == 2 && (c == "t" || c == "T") { special |= 1 }
                }
            }
        }
        let low = digits.map(String.init).joined()
        return special > 0 ? "\(special)\(low)" : low
    }
}
