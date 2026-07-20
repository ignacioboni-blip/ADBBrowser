import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: BrowserViewModel

    @State private var sheet: SheetMode?
    @State private var isDropTargeted = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all

    enum SheetMode: Identifiable {
        case newFolder
        case rename(RemoteFile)
        var id: String {
            switch self {
            case .newFolder: return "newFolder"
            case .rename(let f): return "rename:\(f.path)"
            }
        }
    }

    var body: some View {
        chrome
            .sheet(item: $sheet) { mode in sheetView(mode) }
            .sheet(item: $model.infoFile) { file in
                GetInfoSheet(file: file, model: model)
            }
            .sheet(isPresented: $model.isWifiWizardVisible) {
                WifiPairWizard(model: model)
            }
            .sheet(isPresented: $model.isDiagnosticsVisible) {
                ConnectionDiagnosticsView(model: model)
            }
            .sheet(isPresented: $model.isLogcatVisible) {
                LogcatView(model: model)
            }
            .sheet(isPresented: $model.isApkManagerVisible) {
                ApkManagerView(model: model)
            }
            .sheet(isPresented: $model.isHelpVisible) {
                HelpView()
            }
            .sheet(isPresented: $model.isTransferDrawerVisible) {
                TransferDrawerView(model: model, transfers: model.transfers)
            }
            .alert(item: $model.error) { err in
                Alert(title: Text("adb Error"), message: Text(err.message), dismissButton: .default(Text("OK")))
            }
            .confirmationDialog(
                model.conflictPrompt?.title ?? "Name conflicts",
                isPresented: conflictShown
            ) {
                Button("Replace", role: .destructive) { resolveConflict(.replace) }
                Button("Keep Both") { resolveConflict(.keepBoth) }
                Button("Skip Conflicting") { resolveConflict(.skip) }
                Button("Cancel", role: .cancel) { model.conflictPrompt = nil }
            } message: {
                Text((model.conflictPrompt?.names.prefix(6).joined(separator: ", ") ?? "")
                     + ((model.conflictPrompt?.names.count ?? 0) > 6 ? ", …" : ""))
            }
            .confirmationDialog(
                apkDialogTitle,
                isPresented: apkPromptShown
            ) {
                Button("Install on Phone") {
                    if let urls = model.apkPrompt {
                        model.apkPrompt = nil
                        model.installApks(urls)
                    }
                }
                Button("Copy to Current Folder") {
                    if let urls = model.apkPrompt {
                        model.apkPrompt = nil
                        model.upload(urls: urls)
                    }
                }
                Button("Cancel", role: .cancel) { model.apkPrompt = nil }
            } message: {
                Text(model.apkPrompt?.map(\.lastPathComponent).joined(separator: ", ") ?? "")
            }
            .confirmationDialog(
                "Delete \(model.pendingDeletion.count) item(s) from the device?",
                isPresented: deleteConfirmShown
            ) {
                Button("Delete", role: .destructive) { model.confirmDelete() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(deletionSummary)
            }
            .onAppear { model.start() }
            .frame(minWidth: 920, minHeight: 520)
    }

    private var chrome: some View {
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            DeviceSidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            detailContent
        }
        .tint(model.accent)
        .quickLookPreview($model.quickLookItem, in: model.quickLookItems)
        .toolbar { toolbarContent }
        .overlay(FlightOverlayHost(transfers: model.transfers, accent: model.accent))
    }

    private var deleteConfirmShown: Binding<Bool> {
        Binding(
            get: { !model.pendingDeletion.isEmpty },
            set: { if !$0 { model.pendingDeletion = [] } }
        )
    }

    private var conflictShown: Binding<Bool> {
        Binding(
            get: { model.conflictPrompt != nil },
            set: { if !$0 { model.conflictPrompt = nil } }
        )
    }

    private var apkPromptShown: Binding<Bool> {
        Binding(
            get: { model.apkPrompt != nil },
            set: { if !$0 { model.apkPrompt = nil } }
        )
    }

    private var apkDialogTitle: String {
        let count = model.apkPrompt?.count ?? 0
        let device = model.devices.first(where: { $0.serial == model.selectedSerial })?
            .model.replacingOccurrences(of: "_", with: " ") ?? "the device"
        return count == 1 ? "Install this APK on \(device)?" : "Install \(count) APKs on \(device)?"
    }

    private func resolveConflict(_ resolution: ConflictResolution) {
        guard let prompt = model.conflictPrompt else { return }
        model.conflictPrompt = nil
        prompt.resolve(resolution)
    }

    private var deletionSummary: String {
        model.pendingDeletion.map(\.name).prefix(8).joined(separator: ", ")
            + (model.pendingDeletion.count > 8 ? ", …" : "")
            + "\nThis cannot be undone."
    }

    private var detailContent: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if model.adbAvailable && model.selectedSerial != nil {
                    filterBar
                    Divider()
                }
                mainArea
                Divider()
                StatusBarView(model: model, transfers: model.transfers)
            }
            if model.inRootTerritory {
                Rectangle()
                    .strokeBorder(Color.orange.opacity(0.5), lineWidth: 2)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if model.isPaletteVisible {
                paletteOverlay
            }
        }
        .animation(.easeInOut(duration: 0.4), value: model.inRootTerritory)
    }

    @ViewBuilder
    private var mainArea: some View {
        if !model.adbAvailable {
            adbMissingView
        } else if model.selectedSerial == nil {
            noDeviceView
        } else {
            browser
        }
    }

    @ViewBuilder
    private var paletteOverlay: some View {
        Color.black.opacity(0.12)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { model.isPaletteVisible = false }
            }
            .transition(.opacity)
            .zIndex(1)
        CommandPaletteView(model: model, onNewFolder: { sheet = .newFolder })
            .padding(.top, 52)
            .transition(.scale(scale: 0.97, anchor: .top).combined(with: .opacity))
            .zIndex(2)
    }

    // MARK: - Filter bar

    @FocusState private var filterFocused: Bool

    private var filterBar: some View {
        SearchPillField(
            icon: "line.3.horizontal.decrease.circle",
            placeholder: "Filter this folder (⌘F)",
            text: $model.filterText,
            tint: model.accent,
            focused: $filterFocused,
            onExit: {
                model.filterText = ""
                filterFocused = false
            }
        ) {
            if !model.filterText.isEmpty {
                Text("\(model.visibleEntries.count) of \(model.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
        .onChange(of: model.filterFocusRequest) { _, _ in
            filterFocused = true
        }
    }

    // MARK: - Browser (list/grid with zoom transitions)

    @State private var zoomScale: CGFloat = 1
    @State private var zoomOpacity: Double = 1

    private var browser: some View {
        Group {
            switch model.viewMode {
            case .list:
                fileTable
            case .grid:
                FileGridView(model: model) { files in
                    AnyView(contextMenu(files: files))
                }
            case .sunburst:
                SunburstView(model: model)
            }
        }
        .scaleEffect(zoomScale)
        .opacity(zoomOpacity)
        .onChange(of: model.navTick) { _, _ in
            // Zoom pulse on the live view — never a second, ghost view.
            zoomScale = model.navDirection == .forward ? 0.97 : 1.03
            zoomOpacity = 0.6
            withAnimation(.easeOut(duration: 0.18)) {
                zoomScale = 1
                zoomOpacity = 1
            }
        }
        .onKeyPress(.space) {
            let files = model.selectedFiles.filter { $0.type == .file }
            guard !files.isEmpty else { return .ignored }
            model.quickLook(files)
            return .handled
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: DS.cornerLarge, style: .continuous)
                    .strokeBorder(model.accent, style: StrokeStyle(lineWidth: 2.5, dash: [8, 6]))
                    .background(
                        RoundedRectangle(cornerRadius: DS.cornerLarge, style: .continuous)
                            .fill(model.accent.opacity(DS.tonalFaint))
                    )
                    .padding(6)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
    }

    private var fileTable: some View {
        let compact = model.density == .compact
        return Table(model.visibleEntries, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { file in
                HStack(spacing: 6) {
                    FileThumbView(file: file, model: model, side: compact ? 15 : 19)
                        .frame(width: compact ? 15 : 19)
                    Text(file.name)
                    if let target = file.linkTarget {
                        Text("→ \(target)")
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, compact ? 0 : 2)
                .draggable(file)
                .help("Drag to Finder to download")
            }
            .width(min: 200, ideal: 320)

            TableColumn("Size", value: \.sortableSize) { file in
                Text(file.sizeText)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Modified", value: \.modified) { file in
                Text(file.modified)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 140)

            TableColumn("Permissions", value: \.permissions) { file in
                Text(file.permissions).font(.system(.body, design: .monospaced))
            }
            .width(min: 90, ideal: 100)

            TableColumn("Owner", value: \.owner) { file in
                Text("\(file.owner):\(file.group)").foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .contextMenu(forSelectionType: RemoteFile.ID.self) { ids in
            contextMenu(files: model.entries.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let file = model.entries.first(where: { $0.id == ids.first }) {
                model.activate(file)
            }
        }
        .onDeleteCommand { model.requestDelete(model.selectedFiles) }
        .environment(\.defaultMinListRowHeight, compact ? 22 : 30)
    }

    @ViewBuilder
    private func contextMenu(files: [RemoteFile]) -> some View {
        if files.isEmpty {
            Button("New Folder…") { sheet = .newFolder }
            Button("Upload Files Here…") { model.uploadViaPanel() }
            if model.canPaste { Button("Paste") { model.paste() } }
            Button("Reload") { model.reload() }
        } else {
            if files.count == 1, let f = files.first {
                if f.isNavigable {
                    Button("Open") { model.activate(f) }
                } else {
                    Button("Download & Open") { model.downloadAndOpen(f) }
                }
                Divider()
            }
            if files.contains(where: { $0.type == .file }) {
                Button("Quick Look") { model.quickLook(files) }
            }
            Button("Download to Mac…") { model.download(files) }
            if files.count == 1, let f = files.first {
                Button("Get Info…") { model.infoFile = f }
            }
            Divider()
            Button("Copy") { model.copyToClipboard(files, cut: false) }
            Button("Cut (Move)") { model.copyToClipboard(files, cut: true) }
            if model.canPaste { Button("Paste") { model.paste() } }
            Divider()
            if files.count == 1, let f = files.first {
                Button("Rename…") { sheet = .rename(f) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(f.path, forType: .string)
                }
            }
            Button("Delete", role: .destructive) { model.requestDelete(files) }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []   // only touched on the main queue
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    url = item as? URL
                }
                // Completion handlers arrive on arbitrary queues; hop to main
                // so concurrent drops can't race on the array.
                DispatchQueue.main.async {
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) {
            if !urls.isEmpty { model.handleDroppedFiles(urls) }
        }
        return !providers.isEmpty
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
                .help("Back")
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
                .help("Forward")
            Button { model.goUp() } label: { Image(systemName: "arrow.up") }
                .disabled(!model.canGoUp)
                .help("Enclosing folder")
        }

        ToolbarItem(placement: .principal) {
            BreadcrumbBar(model: model)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.viewMode) {
                Image(systemName: "list.bullet").tag(ViewMode.list)
                Image(systemName: "square.grid.2x2").tag(ViewMode.grid)
                Image(systemName: "chart.pie").tag(ViewMode.sunburst)
            }
            .pickerStyle(.segmented)
            .help("List, gallery, or storage map (⌘1 / ⌘2 / ⌘3)")

            if model.devices.count != 1 {
                Picker("Device", selection: $model.selectedSerial) {
                    if model.devices.isEmpty {
                        Text("No devices").tag(String?.none)
                    }
                    ForEach(model.devices) { d in
                        Text(d.displayName).tag(Optional(d.serial))
                            .selectionDisabled(!d.isUsable)
                    }
                }
                .frame(minWidth: 140)
                .help("Connected devices")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.refreshDevices(); model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh devices and folder")

            Button { model.isWifiWizardVisible = true } label: {
                Label("Wi-Fi", systemImage: "wifi")
            }
            .labelStyle(.titleAndIcon)
            .help("Connect over Wi-Fi")

            Button { model.showDiagnostics() } label: {
                Label("Diagnostics", systemImage: "stethoscope")
            }
            .labelStyle(.titleAndIcon)
            .help("Connection diagnostics")

            Button {
                model.isLogcatVisible = true
                if !model.isLogcatRunning { model.startLogcat() }
            } label: {
                Label("Logcat", systemImage: "doc.text.magnifyingglass")
            }
            .labelStyle(.titleAndIcon)
            .help("Logcat")
            .disabled(model.selectedSerial == nil)

            Button {
                model.isApkManagerVisible = true
                if model.packages.isEmpty { model.loadPackages() }
            } label: {
                Label("APKs", systemImage: "shippingbox")
            }
            .labelStyle(.titleAndIcon)
            .help("APK manager")
            .disabled(model.selectedSerial == nil)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { sheet = .newFolder } label: {
                Label("Folder", systemImage: "folder.badge.plus")
            }
            .labelStyle(.titleAndIcon)
            .help("New folder")
            .disabled(model.selectedSerial == nil)

            Button { model.uploadViaPanel() } label: {
                Label("Upload", systemImage: "square.and.arrow.up")
            }
            .labelStyle(.titleAndIcon)
            .help("Upload files here")
            .disabled(model.selectedSerial == nil)

            Button { model.addBookmarkForCurrentPath() } label: {
                Label("Favorite", systemImage: model.canBookmarkCurrentPath ? "star" : "star.fill")
            }
            .labelStyle(.titleAndIcon)
            .help("Bookmark this folder")
            .disabled(model.selectedSerial == nil || !model.canBookmarkCurrentPath)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.showHidden.toggle() } label: {
                Label("Hidden", systemImage: model.showHidden ? "eye.fill" : "eye")
            }
            .labelStyle(.titleAndIcon)
            .help("Show hidden files")

            Button { model.foldersFirst.toggle() } label: {
                Label("Folders", systemImage: model.foldersFirst ? "folder.fill.badge.gearshape" : "folder")
            }
            .labelStyle(.titleAndIcon)
            .help("Folders first")
        }
    }

    // MARK: - Empty states

    private var adbMissingView: some View {
        EmptyStateView(
            icon: "exclamationmark.triangle",
            title: "adb Not Found",
            message: "Couldn't locate the adb binary. Set its path in Settings (⌘,) — usually ~/Library/Android/sdk/platform-tools/adb.",
            tint: .orange
        ) {
            Button("Try Again") { model.start() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var noDeviceView: some View {
        EmptyStateView(
            icon: "iphone.slash",
            title: "No Device Connected",
            message: "Plug in your phone and make sure USB debugging is authorized — or connect wirelessly.",
            tint: model.accent
        ) {
            Button("Connect over Wi-Fi…") { model.isWifiWizardVisible = true }
                .buttonStyle(.borderedProminent)
            Button("Refresh") { model.refreshDevices() }
        }
    }

    // MARK: - Sheets

    @ViewBuilder
    private func sheetView(_ mode: SheetMode) -> some View {
        switch mode {
        case .newFolder:
            NameInputSheet(title: "New Folder", initialValue: "", buttonLabel: "Create") { name in
                model.makeDirectory(named: name)
            }
        case .rename(let file):
            NameInputSheet(title: "Rename “\(file.name)”", initialValue: file.name, buttonLabel: "Rename") { name in
                model.rename(file, to: name)
            }
        }
    }
}

/// Hosts the transfer flight animation. Observes TransferCenter directly so
/// enqueue pulses fire without re-rendering the whole window.
private struct FlightOverlayHost: View {
    @ObservedObject var transfers: TransferCenter
    let accent: Color

    @State private var flights: [FlightOverlay.Flight] = []

    var body: some View {
        FlightOverlay(flights: flights, accent: accent)
            .onChange(of: transfers.flightTrigger) { _, trigger in
                let flight = FlightOverlay.Flight(id: trigger, isUpload: transfers.flightIsUpload)
                flights.append(flight)
                Task {
                    try? await Task.sleep(for: .seconds(1.0))
                    flights.removeAll { $0.id == flight.id }
                }
            }
    }
}

/// The bottom status bar. Split into its own view so 400 ms transfer-progress
/// ticks re-render only this strip, not the file table above it.
private struct StatusBarView: View {
    @ObservedObject var model: BrowserViewModel
    @ObservedObject var transfers: TransferCenter

    var body: some View {
        HStack(spacing: 10) {
            if let transfer = transfers.active {
                Image(systemName: transfer.isUpload ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(model.accent)
                Text(transfer.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 220, alignment: .leading)
                if let fraction = transfer.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 140)
                        .tint(model.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
                if !transfer.speed.isEmpty {
                    Text(transfer.speed)
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                if let counter = transfer.counter {
                    Text(counter).foregroundStyle(.tertiary)
                }
                Button {
                    model.cancelCurrentTransfer()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Cancel this transfer")
                if transfers.queuedCount > 0 {
                    Button {
                        model.isTransferDrawerVisible = true
                    } label: {
                        Label("+\(transfers.queuedCount)", systemImage: "tray.full")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .help("Show transfer queue")
                }
            } else if model.isBusy {
                ProgressView().controlSize(.small)
                Text(model.statusMessage).foregroundStyle(.secondary)
            } else if !model.statusMessage.isEmpty {
                Text(model.statusMessage).foregroundStyle(.secondary)
            } else {
                Text("\(model.visibleEntries.count) items"
                     + (model.selection.isEmpty ? "" : ", \(model.selection.count) selected"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if transfers.hasAny {
                Button {
                    model.isTransferDrawerVisible = true
                } label: {
                    Image(systemName: "tray.full")
                }
                .buttonStyle(.plain)
                .help("Show transfers")
            }
            if model.selectedSerial != nil {
                Label(model.rootMode.badge, systemImage: model.suAvailable ? "lock.open.fill" : "lock")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(
                        model.inRootTerritory ? Color.orange.opacity(0.32)
                            : model.suAvailable ? Color.orange.opacity(0.16)
                            : Color.gray.opacity(0.12)
                    ))
                    .foregroundStyle(model.suAvailable ? Color.orange : Color.secondary)
                    .shadow(color: model.inRootTerritory ? .orange.opacity(0.45) : .clear, radius: 5)
                    .help(model.inRootTerritory
                          ? "Superuser territory — this path is invisible to a plain adb shell"
                          : "How file operations are executed on the device")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct NameInputSheet: View {
    let title: String
    let initialValue: String
    let buttonLabel: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                TonalIconBadge(icon: buttonLabel == "Create" ? "folder.badge.plus" : "pencil",
                               tint: .accentColor, side: 30)
                Text(title).font(.headline)
            }
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(width: 300)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(buttonLabel, action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || text.contains("/"))
            }
        }
        .padding(20)
        .onAppear { text = initialValue }
    }

    private func commit() {
        let name = text.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !name.contains("/") else { return }
        dismiss()
        onCommit(name)
    }
}
