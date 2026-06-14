import SwiftUI

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("ADB Browser Help", systemImage: "questionmark.circle")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.bar)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    helpSection("Connections", [
                        "The device card shows whether the selected phone is connected over USB ADB or Wi-Fi ADB.",
                        "Use Wi-Fi to pair or reconnect Android wireless debugging.",
                        "Diagnostics shows adb path/version, visible devices, mDNS services, and remembered Wi-Fi endpoints."
                    ])
                    helpSection("Browsing Files", [
                        "Double-click a folder or symlink to open it.",
                        "Use Favorites to pin folders you visit often. Rename favorites from the sidebar context menu.",
                        "Use Hidden and Folders controls in the toolbar to change folder display."
                    ])
                    helpSection("Transfers", [
                        "Download selected files with the context menu or toolbar actions.",
                        "Drag a file from its icon/name in list view, or from a gallery tile, to Finder or Desktop to download it.",
                        "Drop local files onto the browser to upload them to the current folder.",
                        "Open the transfer drawer from the status bar to inspect active and queued work."
                    ])
                    helpSection("Logcat", [
                        "Logcat is a live system-wide Android log stream, so repeated messages from background services are normal.",
                        "The viewer starts from new logs when opened. Use Pause, Clear, level filters, Quiet mode, and text search to reduce noise.",
                        "Closing the Logcat window stops the live stream."
                    ])
                    helpSection("APK Manager", [
                        "APK Manager lists installed packages and fills in app labels/icons when the APK exposes readable metadata.",
                        "Some apps use adaptive or resource-only icons, so a generic icon can still appear.",
                        "Launch, Stop, Pull, Clear, and Uninstall act on the selected app package."
                    ])
                    helpSection("Root Access", [
                        "The status bar shows whether commands are plain adb, su, or adbd root.",
                        "Paths outside public storage may require root and can show an orange keyline.",
                        "File permission changes and root-only browsing use the detected root mode."
                    ])
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 620)
    }

    private func helpSection(_ title: String, _ rows: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(rows, id: \.self) { row in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .padding(.top, 2)
                    Text(row)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct TransferDrawerView: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Transfers", systemImage: "tray.full")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.activeTransfer != nil {
                    Button("Cancel Current") { model.cancelCurrentTransfer() }
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.bar)

            if !model.hasTransfers {
                ContentUnavailableView {
                    Label("No Transfers", systemImage: "tray")
                } description: {
                    Text("Downloads and uploads will appear here.")
                }
                .frame(width: 620, height: 360)
            } else {
                List {
                    if let transfer = model.activeTransfer {
                        Section("Active") {
                            HStack(spacing: 10) {
                                Image(systemName: transfer.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundStyle(model.accent)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(transfer.name).font(.headline)
                                    HStack(spacing: 8) {
                                        if let counter = transfer.counter {
                                            Text(counter)
                                        }
                                        if !transfer.speed.isEmpty {
                                            Text(transfer.speed).monospacedDigit()
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    if let fraction = transfer.fraction {
                                        ProgressView(value: fraction).tint(model.accent)
                                    } else {
                                        ProgressView().controlSize(.small)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    let queued = model.transferBatches.dropFirst(model.activeTransfer == nil ? 0 : 1)
                    if !queued.isEmpty {
                        Section("Queued") {
                            ForEach(Array(queued)) { batch in
                                HStack(spacing: 10) {
                                    Image(systemName: batch.isUpload ? "arrow.up.doc" : "arrow.down.doc")
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(batch.title)
                                        Text(batch.subtitle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
                .frame(width: 620, height: 420)
            }
        }
    }
}

struct ConnectionDiagnosticsView: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(title: "Connection Diagnostics", icon: "stethoscope") {
                Button { model.refreshDiagnostics() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    diagnosticBlock("adb", model.diagnostics.adbPath + "\n\n" + model.diagnostics.adbVersion)
                    diagnosticBlock("Devices", model.diagnostics.devicesOutput)
                    diagnosticBlock("mDNS Services", model.diagnostics.mdnsOutput)
                    diagnosticBlock("Remembered Wi-Fi Endpoints",
                                    model.diagnostics.knownWirelessEndpoints.isEmpty
                                    ? "None"
                                    : model.diagnostics.knownWirelessEndpoints.joined(separator: "\n"))
                }
                .padding(18)
            }
        }
        .frame(width: 720, height: 560)
        .onAppear { model.refreshDiagnostics() }
    }

    private func diagnosticBlock(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy")
            }
            Text(text.isEmpty ? "No output" : text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func header(title: String, icon: String, @ViewBuilder actions: () -> some View) -> some View {
        HStack(spacing: 10) {
            Label(title, systemImage: icon)
                .font(.title3.weight(.semibold))
            Spacer()
            actions()
        }
        .padding(14)
        .background(.bar)
    }
}

struct LogcatView: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    private let levels = ["All", "V", "D", "I", "W", "E", "F"]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("Logcat", systemImage: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    model.isLogcatRunning ? model.stopLogcat() : model.startLogcat()
                } label: {
                    Image(systemName: model.isLogcatRunning ? "pause.fill" : "play.fill")
                }
                .help(model.isLogcatRunning ? "Pause" : "Resume")
                Button { model.clearLogcat() } label: {
                    Image(systemName: "trash")
                }
                .help("Clear")
                Button("Done") {
                    model.stopLogcat()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.bar)

            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(model.logcatFilter.isEmpty ? .secondary : model.accent)
                TextField("Filter logs", text: $model.logcatFilter)
                    .textFieldStyle(.roundedBorder)
                Picker("Level", selection: $model.logcatLevel) {
                    ForEach(levels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                Toggle("Quiet", isOn: $model.quietLogcat)
                    .help("Hide known noisy system tags")
                Text("\(model.filteredLogcatLines.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            ScrollViewReader { proxy in
                ZStack {
                    if model.filteredLogcatLines.isEmpty {
                        ContentUnavailableView {
                            Label("No Logs", systemImage: "doc.text.magnifyingglass")
                        } description: {
                            Text(model.isLogcatRunning ? "Waiting for matching live log entries." : "Logcat is paused.")
                        }
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(model.filteredLogcatLines) { line in
                                    Text(line.text)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(color(for: line.level))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(line.id)
                                }
                            }
                            .padding(10)
                        }
                        .background(Color(nsColor: .textBackgroundColor))
                    }
                }
                .onChange(of: model.filteredLogcatLines.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(width: 920, height: 620)
        .onAppear {
            if !model.isLogcatRunning { model.startLogcat() }
        }
    }

    private func color(for level: String) -> Color {
        switch level {
        case "E", "F": return .red
        case "W": return .orange
        case "I": return .blue
        case "D": return .primary
        default: return .secondary
        }
    }
}

struct ApkManagerView: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var pending: PendingAction?

    struct PendingAction: Identifiable {
        enum Kind { case clearData, uninstall }
        let id = UUID()
        let kind: Kind
        let package: AndroidPackage
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label("APK Manager", systemImage: "shippingbox")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button { model.loadPackages() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
            .background(.bar)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(model.packageFilter.isEmpty ? .secondary : model.accent)
                TextField("Filter packages", text: $model.packageFilter)
                    .textFieldStyle(.roundedBorder)
                Toggle("Third-party only", isOn: $model.packageScopeThirdPartyOnly)
                    .onChange(of: model.packageScopeThirdPartyOnly) { _, _ in model.loadPackages() }
                if model.isLoadingPackages {
                    ProgressView().controlSize(.small)
                }
                Text("\(model.filteredPackages.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            Divider()

            ZStack {
                if model.isLoadingPackages && model.packages.isEmpty {
                    ContentUnavailableView {
                        Label("Loading Apps", systemImage: "shippingbox")
                    } description: {
                        Text("Reading installed packages from the device.")
                    } actions: {
                        ProgressView().controlSize(.small)
                    }
                } else if model.filteredPackages.isEmpty {
                    ContentUnavailableView {
                        Label("No Apps", systemImage: "app.dashed")
                    } description: {
                        Text(model.packageFilter.isEmpty ? "No packages matched this scope." : "No packages match this filter.")
                    }
                } else {
                    List(model.filteredPackages) { package in
                        PackageRowView(model: model, package: package) { action in
                            pending = PendingAction(kind: action, package: package)
                        }
                    }
                }
            }
        }
        .frame(width: 860, height: 620)
        .onAppear {
            if model.packages.isEmpty { model.loadPackages() }
        }
        .confirmationDialog(confirmTitle, isPresented: pendingShown) {
            switch pending?.kind {
            case .clearData:
                Button("Clear Data", role: .destructive) {
                    if let package = pending?.package { model.clearPackageData(package) }
                    pending = nil
                }
            case .uninstall:
                Button("Uninstall", role: .destructive) {
                    if let package = pending?.package { model.uninstallPackage(package) }
                    pending = nil
                }
            case nil:
                EmptyView()
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text(pending?.package.name ?? "")
        }
    }

    private var pendingShown: Binding<Bool> {
        Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        )
    }

    private var confirmTitle: String {
        guard let pending else { return "Confirm" }
        switch pending.kind {
        case .clearData: return "Clear app data?"
        case .uninstall: return "Uninstall app?"
        }
    }
}

private struct PackageIconView: View {
    let package: AndroidPackage
    let accent: Color

    var body: some View {
        Group {
            if let path = package.iconPath, let image = NSImage(contentsOfFile: path) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 21))
                    .foregroundStyle(accent)
            }
        }
        .frame(width: 34, height: 34)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct PackageRowView: View {
    @ObservedObject var model: BrowserViewModel
    let package: AndroidPackage
    let confirm: (ApkManagerView.PendingAction.Kind) -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            PackageIconView(package: package, accent: model.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(package.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(package.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(package.apkPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 6) {
                Button { model.launchPackage(package) } label: {
                    Label("Launch", systemImage: "play.fill")
                }
                .help("Launch")
                Button { model.forceStopPackage(package) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .help("Force Stop")
                Button { model.pullApk(package) } label: {
                    Label("Pull", systemImage: "square.and.arrow.down")
                }
                .help("Pull APK")
                Button(role: .destructive) {
                    confirm(.clearData)
                } label: {
                    Label("Clear", systemImage: "eraser")
                }
                .help("Clear Data")
                Button(role: .destructive) {
                    confirm(.uninstall)
                } label: {
                    Label("Uninstall", systemImage: "trash")
                }
                .help("Uninstall")
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.small)
            .opacity(hovering ? 1 : 0.78)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(hovering ? model.accent.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
