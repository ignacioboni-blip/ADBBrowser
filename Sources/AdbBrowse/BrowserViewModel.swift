import SwiftUI

enum ViewMode: String {
    case list, grid, sunburst
}

enum Density: String, CaseIterable {
    case comfortable, compact

    var label: String {
        switch self {
        case .comfortable: return "Comfortable"
        case .compact: return "Compact"
        }
    }
}

enum NavDirection {
    case forward, backward
}

// MARK: - Conflicts

enum ConflictResolution {
    case replace, keepBoth, skip
}

struct ConflictPrompt: Identifiable {
    let id = UUID()
    let title: String
    let names: [String]
    let resolve: (ConflictResolution) -> Void
}

// MARK: - Transfer queue

enum TransferCompletion {
    case revealInFinder, open, quickLook, none
}

struct PullItem {
    let file: RemoteFile
    let destName: String
}

struct PushItem {
    let url: URL
    let destName: String
    let deleteFirst: Bool
}

struct TransferBatch: Identifiable {
    enum Kind {
        case pull(items: [PullItem], dest: URL, completion: TransferCompletion)
        case push(items: [PushItem], destDir: String)
    }
    let id = UUID()
    let kind: Kind

    var isUpload: Bool {
        if case .push = kind { return true }
        return false
    }
}

@MainActor
final class BrowserViewModel: ObservableObject {
    static let places: [(name: String, icon: String, path: String)] = [
        ("Internal Storage", "internaldrive", "/sdcard"),
        ("Downloads", "arrow.down.circle", "/sdcard/Download"),
        ("Camera", "camera", "/sdcard/DCIM/Camera"),
        ("Pictures", "photo.on.rectangle", "/sdcard/Pictures"),
        ("Movies", "film", "/sdcard/Movies"),
        ("App Data", "shippingbox", "/data/data"),
        ("Local Tmp", "wrench.and.screwdriver", "/data/local/tmp"),
        ("System Root", "iphone.gen3", "/"),
    ]

    // Connection
    @Published var adbAvailable = true
    @Published var devices: [DeviceInfo] = []
    @Published var selectedSerial: String? {
        didSet { if oldValue != selectedSerial { onDeviceSelected() } }
    }
    @Published var rootMode: RootMode = .unknown

    // Live device presence
    @Published var deviceStatus = DeviceStatus.empty
    @Published var theme: DeviceTheme?

    // Browsing
    @Published var currentPath = "/sdcard"
    @Published var pathFieldText = "/sdcard"
    @Published var isEditingPath = false
    @Published var entries: [RemoteFile] = [] {
        didSet { resort() }
    }
    @Published var selection = Set<RemoteFile.ID>()
    @Published var sortOrder = [KeyPathComparator(\RemoteFile.name)] {
        didSet { resort() }
    }
    private var sortedEntries: [RemoteFile] = []
    private var lastListingFailed = false
    private var listingCache: [String: [RemoteFile]] = [:]
    @Published var filterText = ""
    @Published var filterFocusRequest = 0
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }
    @Published var foldersFirst = (UserDefaults.standard.object(forKey: "foldersFirst") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(foldersFirst, forKey: "foldersFirst")
            resort()
        }
    }

    // Presentation
    @Published var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var density: Density = Density(rawValue: UserDefaults.standard.string(forKey: "density") ?? "") ?? .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    @Published private(set) var navDirection: NavDirection = .forward
    @Published private(set) var navTick = 0
    @Published var isPaletteVisible = false
    @Published var recentPaths: [String] = UserDefaults.standard.stringArray(forKey: "recentPaths") ?? []
    @Published var quickLookItem: URL?
    @Published var quickLookItems: [URL] = []
    @Published var usageTree: UsageNode?
    @Published var isMeasuring = false
    @Published private(set) var flightTrigger = 0
    @Published private(set) var flightIsUpload = false
    @Published var infoFile: RemoteFile?
    private var usageCache: [String: UsageNode] = [:]

    // Activity / errors
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var error: AdbError?
    @Published var pendingDeletion: [RemoteFile] = []
    @Published var conflictPrompt: ConflictPrompt?
    @Published var apkPrompt: [URL]?

    // Transfer queue
    @Published var activeTransfer: TransferProgress?
    @Published private(set) var transferBatches: [TransferBatch] = []
    private var batchWorker: Task<Void, Never>?

    // Internal clipboard for device-side copy/move
    @Published private(set) var clipboardPaths: [String] = []
    @Published private(set) var clipboardIsCut = false

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var pollTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var deviceRefreshDebounce: Task<Void, Never>?

    var client: AdbClient?

    var accent: Color { theme?.accent ?? .accentColor }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentPath != "/" }
    var canPaste: Bool { !clipboardPaths.isEmpty }
    var useSu: Bool { rootMode == .su }
    var suAvailable: Bool { rootMode == .su || rootMode == .adbdRoot }
    var queuedTransferCount: Int { max(0, transferBatches.count - 1) }

    /// True when browsing paths a plain adb shell couldn't reach —
    /// the UI shows an amber keyline as a "you are superuser here" signal.
    var inRootTerritory: Bool {
        guard suAvailable, currentPath != "/" else { return false }
        let publicPrefixes = ["/sdcard", "/storage", "/mnt/sdcard"]
        return !publicPrefixes.contains { currentPath == $0 || currentPath.hasPrefix($0 + "/") }
    }

    private func resort() {
        var list: [RemoteFile]
        // Finder-style natural ordering for names ("IMG_2" before "IMG_10").
        if let primary = sortOrder.first, primary.keyPath == \RemoteFile.name {
            list = entries.sorted {
                let r = $0.name.localizedStandardCompare($1.name)
                return primary.order == .forward ? r == .orderedAscending : r == .orderedDescending
            }
        } else {
            list = entries.sorted(using: sortOrder)
        }
        if foldersFirst {
            list = list.filter(\.isDirectory) + list.filter { !$0.isDirectory }
        }
        sortedEntries = list
    }

    var visibleEntries: [RemoteFile] {
        var list = sortedEntries
        if !showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        if !filterText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        return list
    }

    var selectedFiles: [RemoteFile] {
        entries.filter { selection.contains($0.id) }
    }

    var pathSegments: [PathSegment] {
        var segments = [PathSegment(name: "/", path: "/")]
        var acc = ""
        for comp in currentPath.split(separator: "/") {
            acc += "/" + comp
            segments.append(PathSegment(name: String(comp), path: acc))
        }
        return segments
    }

    deinit {
        pollTask?.cancel()
        trackTask?.cancel()
    }

    // MARK: - Setup

    func start() {
        guard let path = AdbClient.resolveAdbPath() else {
            adbAvailable = false
            return
        }
        adbAvailable = true
        let client = AdbClient(adbPath: path)
        self.client = client
        DragExport.handler = { [weak self] file in
            guard let self else { throw AdbError(message: "App is shutting down") }
            return try await self.exportForDrag(file)
        }
        if selectedSerial == nil,
           let start = UserDefaults.standard.string(forKey: "defaultPath"),
           !start.isEmpty {
            currentPath = normalize(start)
            pathFieldText = currentPath
        }
        startDeviceTracking(client: client)
        refreshDevices()
    }

    func refreshDevices(quiet: Bool = false) {
        guard let client else { return }
        Task {
            let apply = { (found: [DeviceInfo]) in
                self.devices = found
                if let current = self.selectedSerial, !found.contains(where: { $0.serial == current && $0.isUsable }) {
                    self.selectedSerial = nil
                }
                if self.selectedSerial == nil, let first = found.first(where: { $0.isUsable }) {
                    self.selectedSerial = first.serial
                }
            }
            if quiet {
                if let found = try? await client.listDevices() { apply(found) }
            } else {
                await withStatus("Looking for devices…") {
                    apply(try await client.listDevices())
                }
            }
        }
    }

    /// adb track-devices: refresh the device list the moment something
    /// plugs in or drops off, no manual refresh needed.
    private func startDeviceTracking(client: AdbClient) {
        trackTask?.cancel()
        trackTask = Task { [weak self] in
            while !Task.isCancelled {
                for await _ in client.deviceEvents() {
                    guard let self else { return }
                    self.deviceRefreshDebounce?.cancel()
                    self.deviceRefreshDebounce = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        self?.refreshDevices(quiet: true)
                    }
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func onDeviceSelected() {
        pollTask?.cancel()
        guard let client, let serial = selectedSerial else {
            deviceStatus = .empty
            withAnimation(.easeInOut(duration: 0.6)) { theme = nil }
            return
        }
        rootMode = .unknown
        backStack = []
        forwardStack = []
        listingCache.removeAll()
        startPolling(client: client, serial: serial)
        Task {
            // Root detection and the first listing race in parallel — /sdcard
            // lists fine without root, so the UI fills immediately.
            async let detected = client.detectRootMode(serial: serial)
            await self.loadCurrentPath()
            self.rootMode = await detected
            if self.lastListingFailed {
                await self.loadCurrentPath()   // path needed root after all
            }
        }
    }

    // MARK: - Live presence polling

    private func startPolling(client: AdbClient, serial: String) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                let status = await client.fetchStatus(serial: serial)
                guard let self, !Task.isCancelled else { return }
                self.deviceStatus = status
                let newTheme = DeviceTheme.from(hex: status.seedHex)
                if newTheme != self.theme {
                    withAnimation(.easeInOut(duration: 0.8)) { self.theme = newTheme }
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Navigation

    func navigate(to rawPath: String, direction: NavDirection? = nil) {
        isEditingPath = false
        let path = normalize(rawPath)
        guard path != currentPath else { Task { await loadCurrentPath() }; return }
        // Going to an ancestor should zoom out, not in (breadcrumbs, places).
        let inferred: NavDirection = currentPath.hasPrefix(path == "/" ? "/" : path + "/") ? .backward : .forward
        backStack.append(currentPath)
        forwardStack = []
        setPath(path, direction: direction ?? inferred)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(currentPath)
        setPath(prev, direction: .backward)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentPath)
        setPath(next, direction: .forward)
    }

    func goUp() {
        guard canGoUp else { return }
        let parent = (currentPath as NSString).deletingLastPathComponent
        navigate(to: parent.isEmpty ? "/" : parent, direction: .backward)
    }

    private func setPath(_ path: String, direction: NavDirection) {
        navDirection = direction
        navTick &+= 1
        // No withAnimation here: identity-swap transitions on the
        // NSTableView-backed Table left ghost views that swallowed clicks.
        // The zoom effect is a transform pulse in ContentView instead.
        currentPath = path
        Task { await loadCurrentPath() }
    }

    func reload() {
        invalidateListing()
        Task { await loadCurrentPath() }
    }

    /// Double-click: descend into directories (resolving symlinks), open files.
    func activate(_ file: RemoteFile) {
        if file.isDirectory {
            navigate(to: file.path)
            return
        }
        guard let client, let serial = selectedSerial else { return }
        if file.type == .symlink {
            Task {
                if await client.isDirectory(path: file.path, serial: serial, su: self.useSu) {
                    self.navigate(to: file.path)
                } else {
                    self.downloadAndOpen(file)
                }
            }
        } else {
            downloadAndOpen(file)
        }
    }

    /// Set before navigation to select an item once the listing arrives.
    var pendingSelection: String?

    private func cacheKey(_ path: String) -> String {
        "\(selectedSerial ?? "-")|\(path)"
    }

    private func invalidateListing(_ path: String? = nil) {
        if let path {
            listingCache[cacheKey(path)] = nil
        } else {
            listingCache[cacheKey(currentPath)] = nil
        }
    }

    private func loadCurrentPath() async {
        guard let client, let serial = selectedSerial else { return }
        let path = currentPath
        let key = cacheKey(path)
        pathFieldText = path
        lastListingFailed = false

        // Instant render from cache, then refresh silently in the background.
        if let cached = listingCache[key] {
            entries = cached
            applySelectionAfterLoad()
            do {
                let fresh = try await client.list(path: path, serial: serial, su: useSu)
                storeListing(fresh, key: key, path: path)
            } catch let e as AdbError {
                lastListingFailed = true
                error = e
            } catch {}
            return
        }

        await withStatus("Loading \(path)…") {
            do {
                let fresh = try await client.list(path: path, serial: serial, su: self.useSu)
                self.storeListing(fresh, key: key, path: path)
            } catch {
                self.lastListingFailed = true
                throw error
            }
        }
    }

    private func storeListing(_ fresh: [RemoteFile], key: String, path: String) {
        if listingCache.count > 80 { listingCache.removeAll() }
        listingCache[key] = fresh
        guard currentPath == path else { return }
        entries = fresh
        applySelectionAfterLoad()
        addRecent(path)
    }

    private func applySelectionAfterLoad() {
        if let pending = pendingSelection {
            selection = entries.contains(where: { $0.id == pending }) ? [pending] : []
            pendingSelection = nil
        } else {
            selection = selection.filter { id in entries.contains(where: { $0.id == id }) }
        }
    }

    private func addRecent(_ path: String) {
        recentPaths.removeAll { $0 == path }
        recentPaths.insert(path, at: 0)
        if recentPaths.count > 12 { recentPaths.removeLast(recentPaths.count - 12) }
        UserDefaults.standard.set(recentPaths, forKey: "recentPaths")
    }

    private func normalize(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    // MARK: - File operations

    func makeDirectory(named name: String) {
        guard let client, let serial = selectedSerial else { return }
        let path = childPath(name)
        Task {
            await withStatus("Creating folder…") {
                try await client.makeDirectory(path: path, serial: serial, su: self.useSu)
            }
            invalidateListing()
            await loadCurrentPath()
        }
    }

    func rename(_ file: RemoteFile, to newName: String) {
        guard let client, let serial = selectedSerial, newName != file.name else { return }
        let dest = file.directory == "/" ? "/" + newName : file.directory + "/" + newName
        Task {
            await withStatus("Renaming…") {
                try await client.move(from: file.path, to: dest, serial: serial, su: self.useSu)
            }
            invalidateListing()
            await loadCurrentPath()
        }
    }

    func requestDelete(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        pendingDeletion = files
    }

    func confirmDelete() {
        guard let client, let serial = selectedSerial else { return }
        let files = pendingDeletion
        pendingDeletion = []
        Task {
            await withStatus("Deleting \(files.count) item(s)…") {
                for f in files {
                    try await client.delete(path: f.path, serial: serial, su: self.useSu)
                }
            }
            invalidateListing()
            await loadCurrentPath()
        }
    }

    func copyToClipboard(_ files: [RemoteFile], cut: Bool) {
        clipboardPaths = files.map(\.path)
        clipboardIsCut = cut
        statusMessage = "\(files.count) item(s) ready to \(cut ? "move" : "copy")"
    }

    func paste() {
        guard selectedSerial != nil, !clipboardPaths.isEmpty else { return }
        let sources = clipboardPaths
        let isCut = clipboardIsCut
        let dest = currentPath
        let existing = Set(entries.map(\.name))
        let conflicts = sources.map { ($0 as NSString).lastPathComponent }.filter { existing.contains($0) }
        if isCut { clipboardPaths = [] }

        let proceed: (ConflictResolution?) -> Void = { resolution in
            Task { await self.performPaste(sources: sources, isCut: isCut, dest: dest,
                                           existing: existing, resolution: resolution) }
        }
        if conflicts.isEmpty {
            proceed(nil)
        } else {
            conflictPrompt = ConflictPrompt(
                title: "\(conflicts.count) item(s) already exist in \((dest as NSString).lastPathComponent.isEmpty ? dest : (dest as NSString).lastPathComponent)",
                names: conflicts.sorted(),
                resolve: proceed
            )
        }
    }

    private func performPaste(sources: [String], isCut: Bool, dest: String,
                              existing: Set<String>, resolution: ConflictResolution?) async {
        guard let client, let serial = selectedSerial else { return }
        var taken = existing
        await withStatus("\(isCut ? "Moving" : "Copying") \(sources.count) item(s)…") {
            for src in sources {
                let name = (src as NSString).lastPathComponent
                var targetName = name
                if existing.contains(name) {
                    switch resolution {
                    case .skip, nil:
                        continue
                    case .replace:
                        try await client.delete(path: self.join(dest, name), serial: serial, su: self.useSu)
                    case .keepBoth:
                        targetName = Self.availableName(name, existing: taken)
                    }
                }
                taken.insert(targetName)
                let target = self.join(dest, targetName)
                if isCut {
                    try await client.move(from: src, to: target, serial: serial, su: self.useSu)
                } else {
                    try await client.copy(from: src, to: target, serial: serial, su: self.useSu)
                }
            }
        }
        invalidateListing(dest)
        await loadCurrentPath()
    }

    // MARK: - Transfers (queued, cancellable)

    func download(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = "Choose where to save \(files.count) item(s) from the device"
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let conflicts = files.map(\.name).filter { existing.contains($0) }

        let proceed: (ConflictResolution?) -> Void = { resolution in
            var taken = existing
            var items: [PullItem] = []
            for f in files {
                var destName = f.name
                if existing.contains(f.name) {
                    switch resolution {
                    case .skip, nil: continue
                    case .replace:
                        try? FileManager.default.removeItem(at: dir.appendingPathComponent(f.name))
                    case .keepBoth:
                        destName = Self.availableName(f.name, existing: taken)
                    }
                }
                taken.insert(destName)
                items.append(PullItem(file: f, destName: destName))
            }
            guard !items.isEmpty else { return }
            self.enqueue(TransferBatch(kind: .pull(items: items, dest: dir, completion: .revealInFinder)))
        }

        if conflicts.isEmpty {
            proceed(nil)
        } else {
            conflictPrompt = ConflictPrompt(
                title: "\(conflicts.count) item(s) already exist in \(dir.lastPathComponent)",
                names: conflicts.sorted(),
                resolve: proceed
            )
        }
    }

    func downloadAndOpen(_ file: RemoteFile) {
        enqueue(TransferBatch(kind: .pull(items: [PullItem(file: file, destName: file.name)],
                                          dest: Self.makeTempDir(), completion: .open)))
    }

    func quickLook(_ files: [RemoteFile]) {
        let pullable = files.filter { $0.type == .file }
        guard !pullable.isEmpty else { return }
        let items = pullable.map { PullItem(file: $0, destName: $0.name) }
        enqueue(TransferBatch(kind: .pull(items: items, dest: Self.makeTempDir(), completion: .quickLook)))
    }

    func uploadViaPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Choose files or folders to copy to \(currentPath)"
        guard panel.runModal() == .OK else { return }
        upload(urls: panel.urls)
    }

    func upload(urls: [URL]) {
        guard selectedSerial != nil, !urls.isEmpty else { return }
        let dest = currentPath
        let existing = Set(entries.map(\.name))
        let conflicts = urls.map(\.lastPathComponent).filter { existing.contains($0) }

        let proceed: (ConflictResolution?) -> Void = { resolution in
            var taken = existing
            var items: [PushItem] = []
            for url in urls {
                let name = url.lastPathComponent
                var destName = name
                var deleteFirst = false
                if existing.contains(name) {
                    switch resolution {
                    case .skip, nil: continue
                    case .replace: deleteFirst = true
                    case .keepBoth: destName = Self.availableName(name, existing: taken)
                    }
                }
                taken.insert(destName)
                items.append(PushItem(url: url, destName: destName, deleteFirst: deleteFirst))
            }
            guard !items.isEmpty else { return }
            self.enqueue(TransferBatch(kind: .push(items: items, destDir: dest)))
        }

        if conflicts.isEmpty {
            proceed(nil)
        } else {
            conflictPrompt = ConflictPrompt(
                title: "\(conflicts.count) item(s) already exist in this folder",
                names: conflicts.sorted(),
                resolve: proceed
            )
        }
    }

    /// Files dropped on the window: APKs get an install-or-copy prompt,
    /// everything else uploads to the current folder.
    func handleDroppedFiles(_ urls: [URL]) {
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        let others = urls.filter { $0.pathExtension.lowercased() != "apk" }
        if !others.isEmpty { upload(urls: others) }
        if !apks.isEmpty { apkPrompt = apks }
    }

    func installApks(_ urls: [URL]) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            var failures: [String] = []
            await withStatus("Installing…") {
                for url in urls {
                    self.statusMessage = "Installing \(url.lastPathComponent)…"
                    do {
                        try await client.installApk(at: url, serial: serial)
                    } catch {
                        failures.append("\(url.lastPathComponent): \((error as? AdbError)?.message ?? error.localizedDescription)")
                    }
                }
                if !failures.isEmpty {
                    throw AdbError(message: failures.joined(separator: "\n"))
                }
            }
            if failures.isEmpty {
                statusMessage = "Installed \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) APKs")"
            }
        }
    }

    /// Pull a file for a drag that landed in Finder.
    private func exportForDrag(_ file: RemoteFile) async throws -> URL {
        guard let client, let serial = selectedSerial else {
            throw AdbError(message: "No device connected")
        }
        let dir = Self.makeTempDir()
        statusMessage = "Exporting \(file.name)…"
        defer { statusMessage = "" }
        try await client.pull(remotePath: file.path, fileName: file.name,
                              toLocalDir: dir, serial: serial, suAvailable: suAvailable)
        return dir.appendingPathComponent(file.name)
    }

    private static func makeTempDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbBrowse", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    static func availableName(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(i)" : "\(base) \(i).\(ext)"
            if !existing.contains(candidate) { return candidate }
            i += 1
        }
    }

    private func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    // MARK: queue machinery

    private func enqueue(_ batch: TransferBatch) {
        transferBatches.append(batch)
        flightIsUpload = batch.isUpload
        flightTrigger &+= 1
        pumpTransfers()
    }

    func cancelCurrentTransfer() {
        batchWorker?.cancel()
    }

    private func pumpTransfers() {
        guard batchWorker == nil, let batch = transferBatches.first else { return }
        batchWorker = Task {
            await self.run(batch: batch)
            self.transferBatches.removeAll { $0.id == batch.id }
            self.activeTransfer = nil
            self.batchWorker = nil
            self.pumpTransfers()
        }
    }

    private func run(batch: TransferBatch) async {
        guard let client, let serial = selectedSerial else { return }
        let suAvailable = self.suAvailable

        switch batch.kind {
        case .pull(let items, let dest, let completion):
            var completed: [URL] = []
            for (i, item) in items.enumerated() {
                let local = dest.appendingPathComponent(item.destName)
                let monitor = startPullMonitor(file: item.file, localURL: local, index: i + 1, total: items.count)
                do {
                    try await client.pull(remotePath: item.file.path, fileName: item.file.name,
                                          destName: item.destName, toLocalDir: dest,
                                          serial: serial, suAvailable: suAvailable)
                    monitor.cancel()
                    completed.append(local)
                } catch is CancellationError {
                    monitor.cancel()
                    try? FileManager.default.removeItem(at: local)
                    statusMessage = "Transfer cancelled"
                    return
                } catch {
                    monitor.cancel()
                    self.error = AdbError(message: "Pulling \(item.file.name) failed: \((error as? AdbError)?.message ?? error.localizedDescription)")
                    return
                }
            }
            switch completion {
            case .open:
                if let first = completed.first { NSWorkspace.shared.open(first) }
            case .revealInFinder:
                NSWorkspace.shared.activateFileViewerSelecting(completed)
            case .quickLook:
                quickLookItems = completed
                quickLookItem = completed.first
            case .none:
                break
            }

        case .push(let items, let destDir):
            for (i, item) in items.enumerated() {
                let remote = join(destDir, item.destName)
                let monitor = startPushMonitor(localURL: item.url, remotePath: remote,
                                               index: i + 1, total: items.count)
                do {
                    if item.deleteFirst {
                        try await client.delete(path: remote, serial: serial, su: useSu)
                    }
                    try await client.push(localURL: item.url, toRemoteDir: destDir,
                                          destName: item.destName, serial: serial, suAvailable: suAvailable)
                    monitor.cancel()
                } catch is CancellationError {
                    monitor.cancel()
                    statusMessage = "Transfer cancelled"
                    break
                } catch {
                    monitor.cancel()
                    self.error = AdbError(message: "Pushing \(item.destName) failed: \((error as? AdbError)?.message ?? error.localizedDescription)")
                    break
                }
            }
            invalidateListing(destDir)
            if currentPath == destDir {
                await loadCurrentPath()
            }
        }
    }

    // MARK: - Transfer progress monitors

    private func startPullMonitor(file: RemoteFile, localURL: URL, index: Int, total: Int) -> Task<Void, Never> {
        let expected = file.type == .file ? file.size : nil
        let counter = total > 1 ? "\(index) of \(total)" : nil
        return Task { [weak self] in
            var lastSize: Int64 = 0
            var lastDate = Date()
            var speed = ""
            while !Task.isCancelled {
                let size = Self.localFileSize(localURL)
                let now = Date()
                let dt = now.timeIntervalSince(lastDate)
                if dt > 0.2 && size > lastSize {
                    let rate = Double(size - lastSize) / dt
                    speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
                }
                lastSize = size
                lastDate = now
                let fraction = expected.flatMap { $0 > 0 ? min(1, Double(size) / Double($0)) : nil }
                self?.activeTransfer = TransferProgress(
                    name: file.name, isUpload: false, fraction: fraction, speed: speed, counter: counter
                )
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func startPushMonitor(localURL: URL, remotePath: String, index: Int, total: Int) -> Task<Void, Never> {
        guard let client, let serial = selectedSerial else { return Task {} }
        let su = useSu
        let counter = total > 1 ? "\(index) of \(total)" : nil
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: localURL.path, isDirectory: &isDir)
        let expected: Int64? = isDir.boolValue ? nil : Self.localFileSize(localURL)
        let name = localURL.lastPathComponent
        return Task { [weak self] in
            var lastSize: Int64 = 0
            var lastDate = Date()
            var speed = ""
            while !Task.isCancelled {
                let size = await client.statSize(path: remotePath, serial: serial, su: su) ?? 0
                if Task.isCancelled { return }
                let now = Date()
                let dt = now.timeIntervalSince(lastDate)
                if dt > 0.2 && size > lastSize {
                    let rate = Double(size - lastSize) / dt
                    speed = ByteCountFormatter.string(fromByteCount: Int64(rate), countStyle: .file) + "/s"
                }
                lastSize = size
                lastDate = now
                let fraction = expected.flatMap { $0 > 0 ? min(1, Double(size) / Double($0)) : nil }
                self?.activeTransfer = TransferProgress(
                    name: name, isUpload: true, fraction: fraction, speed: speed, counter: counter
                )
                try? await Task.sleep(for: .milliseconds(900))
            }
        }
    }

    private nonisolated static func localFileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Get Info

    func applyFileInfo(_ file: RemoteFile, octal: String?, ownerGroup: String?) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            await withStatus("Applying changes…") {
                if let octal {
                    try await client.chmod(octal, path: file.path, serial: serial, su: self.useSu)
                }
                if let ownerGroup {
                    try await client.chown(ownerGroup, path: file.path, serial: serial, su: self.useSu)
                }
            }
            invalidateListing()
            await loadCurrentPath()
        }
    }

    func measureSize(of file: RemoteFile) async -> Int64? {
        guard let client, let serial = selectedSerial else { return nil }
        return await client.sizeOf(path: file.path, serial: serial, su: useSu)
    }

    // MARK: - Storage sunburst

    func loadUsage(force: Bool = false) {
        guard let client, let serial = selectedSerial else { return }
        let path = currentPath
        let key = serial + ":" + path
        if !force, let cached = usageCache[key] {
            usageTree = cached
            return
        }
        usageTree = nil
        isMeasuring = true
        Task {
            do {
                let entries = try await client.diskUsage(path: path, serial: serial, su: useSu)
                if self.currentPath == path, let tree = UsageNode.build(root: path, entries: entries) {
                    self.usageCache[key] = tree
                    self.usageTree = tree
                }
            } catch let e as AdbError {
                self.error = e
            } catch {}
            self.isMeasuring = false
        }
    }

    func openFromSunburst(_ path: String) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            if await client.isDirectory(path: path, serial: serial, su: self.useSu) {
                self.navigate(to: path)
            } else {
                self.revealSearchResult(path)
            }
        }
    }

    // MARK: - Search & thumbnails

    private let thumbnails = ThumbnailStore()

    func thumbnail(for file: RemoteFile) async -> NSImage? {
        guard let client, let serial = selectedSerial else { return nil }
        return await thumbnails.thumbnail(for: file, client: client, serial: serial, suAvailable: suAvailable)
    }

    func searchDevice(_ query: String) async -> [String] {
        guard let client, let serial = selectedSerial else { return [] }
        return await client.find(query: query, under: currentPath, serial: serial, su: useSu)
    }

    func revealSearchResult(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        pendingSelection = path
        navigate(to: parent.isEmpty ? "/" : parent)
    }

    // MARK: - Helpers

    private func childPath(_ name: String) -> String {
        join(currentPath, name)
    }

    private func withStatus(_ message: String, _ body: () async throws -> Void) async {
        isBusy = true
        statusMessage = message
        defer {
            isBusy = false
            statusMessage = ""
        }
        do {
            try await body()
        } catch let e as AdbError {
            error = e
        } catch is CancellationError {
            statusMessage = "Cancelled"
        } catch {
            self.error = AdbError(message: error.localizedDescription)
        }
    }
}
