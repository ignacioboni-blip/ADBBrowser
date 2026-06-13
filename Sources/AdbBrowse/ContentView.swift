import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: BrowserViewModel

    @State private var sheet: SheetMode?
    @State private var isDropTargeted = false
    @State private var sidebarVisibility = NavigationSplitViewVisibility.all
    @State private var flights: [FlightOverlay.Flight] = []

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
        .overlay(FlightOverlay(flights: flights, accent: model.accent))
        .onChange(of: model.flightTrigger) { _, trigger in
            let flight = FlightOverlay.Flight(id: trigger, isUpload: model.flightIsUpload)
            flights.append(flight)
            Task {
                try? await Task.sleep(for: .seconds(1.0))
                flights.removeAll { $0.id == flight.id }
            }
        }
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
                statusBar
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
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(model.filterText.isEmpty ? Color.secondary : model.accent)
            TextField("Filter this folder (⌘F)", text: $model.filterText)
                .textFieldStyle(.plain)
                .focused($filterFocused)
                .onExitCommand {
                    model.filterText = ""
                    filterFocused = false
                }
            if !model.filterText.isEmpty {
                Text("\(model.visibleEntries.count) of \(model.entries.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    model.filterText = ""
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
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(model.accent, lineWidth: 3)
                    .background(model.accent.opacity(0.08))
                    .padding(4)
                    .allowsHitTesting(false)
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
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    urls.append(url)
                } else if let url = item as? URL {
                    urls.append(url)
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

        ToolbarItemGroup {
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

            Button { model.refreshDevices(); model.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh devices and folder")

            Menu {
                Button("New Folder…") { sheet = .newFolder }
                Button("Upload Files Here…") { model.uploadViaPanel() }
                Divider()
                Toggle("Show Hidden Files", isOn: $model.showHidden)
                Toggle("Folders First", isOn: $model.foldersFirst)
                Picker("Density", selection: $model.density) {
                    ForEach(Density.allCases, id: \.self) { d in
                        Text(d.label).tag(d)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .help("Actions")
        }
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let transfer = model.activeTransfer {
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
                if model.queuedTransferCount > 0 {
                    Text("+\(model.queuedTransferCount) queued")
                        .foregroundStyle(.tertiary)
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

    // MARK: - Empty states

    private var adbMissingView: some View {
        ContentUnavailableView {
            Label("adb Not Found", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Couldn't locate the adb binary. Set its path in Settings (⌘,) — usually ~/Library/Android/sdk/platform-tools/adb.")
        } actions: {
            Button("Try Again") { model.start() }
        }
        .frame(maxHeight: .infinity)
    }

    private var noDeviceView: some View {
        ContentUnavailableView {
            Label("No Device Connected", systemImage: "iphone.slash")
        } description: {
            Text("Plug in your phone (or connect over Wi-Fi adb) and make sure USB debugging is authorized.")
        } actions: {
            Button("Refresh") { model.refreshDevices() }
        }
        .frame(maxHeight: .infinity)
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

struct NameInputSheet: View {
    let title: String
    let initialValue: String
    let buttonLabel: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
                .onSubmit(commit)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(buttonLabel, action: commit)
                    .keyboardShortcut(.defaultAction)
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
