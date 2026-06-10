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
    /// Sorted once per change, not on every render — filtering stays O(n).
    private var sortedEntries: [RemoteFile] = []
    private var lastListingFailed = false
    @Published var filterText = ""
    @Published var filterFocusRequest = 0
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet { UserDefaults.standard.set(showHidden, forKey: "showHidden") }
    }

    // Presentation
    @Published var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var density: Density = Density(rawValue: UserDefaults.standard.string(forKey: "density") ?? "") ?? .comfortable {
        didSet { UserDefaults.standard.set(density.rawValue, forKey: "density") }
    }
    @Published private(set) var navDirection: NavDirection = .forward
    @Published var isPaletteVisible = false
    @Published var recentPaths: [String] = UserDefaults.standard.stringArray(forKey: "recentPaths") ?? []
    @Published var quickLookItem: URL?
    @Published var quickLookItems: [URL] = []
    @Published var usageTree: UsageNode?
    @Published var isMeasuring = false
    @Published private(set) var flightTrigger = 0
    @Published private(set) var flightIsUpload = false
    private var usageCache: [String: UsageNode] = [:]

    // Activity / errors
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var error: AdbError?
    @Published var pendingDeletion: [RemoteFile] = []
    @Published var activeTransfer: TransferProgress?

    // Internal clipboard for device-side copy/move
    @Published private(set) var clipboardPaths: [String] = []
    @Published private(set) var clipboardIsCut = false

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var pollTask: Task<Void, Never>?

    var client: AdbClient?

    var accent: Color { theme?.accent ?? .accentColor }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { currentPath != "/" }
    var canPaste: Bool { !clipboardPaths.isEmpty }
    var useSu: Bool { rootMode == .su }
    var suAvailable: Bool { rootMode == .su || rootMode == .adbdRoot }

    /// True when browsing paths a plain adb shell couldn't reach —
    /// the UI shows an amber keyline as a "you are superuser here" signal.
    var inRootTerritory: Bool {
        guard suAvailable, currentPath != "/" else { return false }
        let publicPrefixes = ["/sdcard", "/storage", "/mnt/sdcard"]
        return !publicPrefixes.contains { currentPath == $0 || currentPath.hasPrefix($0 + "/") }
    }

    private func resort() {
        sortedEntries = entries.sorted(using: sortOrder)
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
    }

    // MARK: - Setup

    func start() {
        guard let path = AdbClient.resolveAdbPath() else {
            adbAvailable = false
            return
        }
        adbAvailable = true
        client = AdbClient(adbPath: path)
        if selectedSerial == nil,
           let start = UserDefaults.standard.string(forKey: "defaultPath"),
           !start.isEmpty {
            currentPath = normalize(start)
            pathFieldText = currentPath
        }
        refreshDevices()
    }

    func refreshDevices() {
        guard let client else { return }
        Task {
            await withStatus("Looking for devices…") {
                let found = try await client.listDevices()
                self.devices = found
                if let current = self.selectedSerial, !found.contains(where: { $0.serial == current && $0.isUsable }) {
                    self.selectedSerial = nil
                }
                if self.selectedSerial == nil, let first = found.first(where: { $0.isUsable }) {
                    self.selectedSerial = first.serial
                }
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
                // Battery / storage / Material You seed
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

    /// Change the path with a zoom transition: forward zooms in, backward zooms out.
    private func setPath(_ path: String, direction: NavDirection) {
        navDirection = direction
        withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
            currentPath = path
        }
        Task { await loadCurrentPath() }
    }

    func reload() {
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

    /// Set before navigation to select an item once the listing arrives
    /// (used by command-palette search results).
    var pendingSelection: String?

    private func loadCurrentPath() async {
        guard let client, let serial = selectedSerial else { return }
        pathFieldText = currentPath
        lastListingFailed = false
        await withStatus("Loading \(currentPath)…") {
            do {
                self.entries = try await client.list(path: self.currentPath, serial: serial, su: self.useSu)
            } catch {
                self.lastListingFailed = true
                throw error
            }
            if let pending = self.pendingSelection {
                self.selection = self.entries.contains(where: { $0.id == pending }) ? [pending] : []
                self.pendingSelection = nil
            } else {
                self.selection = []
            }
            self.addRecent(self.currentPath)
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
            await loadCurrentPath()
        }
    }

    func copyToClipboard(_ files: [RemoteFile], cut: Bool) {
        clipboardPaths = files.map(\.path)
        clipboardIsCut = cut
        statusMessage = "\(files.count) item(s) ready to \(cut ? "move" : "copy")"
    }

    func paste() {
        guard let client, let serial = selectedSerial, !clipboardPaths.isEmpty else { return }
        let paths = clipboardPaths
        let isCut = clipboardIsCut
        let dest = currentPath
        if isCut { clipboardPaths = [] }
        Task {
            await withStatus("\(isCut ? "Moving" : "Copying") \(paths.count) item(s)…") {
                for src in paths {
                    if isCut {
                        try await client.move(from: src, to: dest + "/", serial: serial, su: self.useSu)
                    } else {
                        try await client.copy(from: src, to: dest + "/", serial: serial, su: self.useSu)
                    }
                }
            }
            await loadCurrentPath()
        }
    }

    // MARK: - Transfers

    func download(_ files: [RemoteFile]) {
        guard !files.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        panel.message = "Choose where to save \(files.count) item(s) from the device"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        transfer(files, to: dir, completion: .revealInFinder)
    }

    func downloadAndOpen(_ file: RemoteFile) {
        transfer([file], to: Self.makeTempDir(), completion: .open)
    }

    /// Pull the files to a temp folder, then show them in Quick Look.
    func quickLook(_ files: [RemoteFile]) {
        let pullable = files.filter { $0.type == .file }
        guard !pullable.isEmpty else { return }
        transfer(pullable, to: Self.makeTempDir(), completion: .quickLook)
    }

    private static func makeTempDir() -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbBrowse", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private enum TransferCompletion {
        case revealInFinder, open, quickLook
    }

    private func transfer(_ files: [RemoteFile], to dir: URL, completion: TransferCompletion) {
        guard let client, let serial = selectedSerial else { return }
        let suAvailable = self.suAvailable
        flightIsUpload = false
        flightTrigger &+= 1
        Task {
            await withStatus("Pulling \(files.count) item(s)…") {
                for (i, f) in files.enumerated() {
                    let local = dir.appendingPathComponent(f.name)
                    let monitor = self.startPullMonitor(file: f, localURL: local, index: i + 1, total: files.count)
                    defer { monitor.cancel() }
                    try await client.pull(remotePath: f.path, fileName: f.name,
                                          toLocalDir: dir, serial: serial, suAvailable: suAvailable)
                }
                let locals = files.map { dir.appendingPathComponent($0.name) }
                switch completion {
                case .open:
                    if let first = locals.first { NSWorkspace.shared.open(first) }
                case .revealInFinder:
                    NSWorkspace.shared.activateFileViewerSelecting(locals)
                case .quickLook:
                    self.quickLookItems = locals
                    self.quickLookItem = locals.first
                }
            }
        }
    }

    // MARK: - Thumbnails & search

    private let thumbnails = ThumbnailStore()

    func thumbnail(for file: RemoteFile) async -> NSImage? {
        guard let client, let serial = selectedSerial else { return nil }
        return await thumbnails.thumbnail(for: file, client: client, serial: serial, suAvailable: suAvailable)
    }

    /// Recursive find under the current folder (used by the command palette).
    func searchDevice(_ query: String) async -> [String] {
        guard let client, let serial = selectedSerial else { return [] }
        return await client.find(query: query, under: currentPath, serial: serial, su: useSu)
    }

    func revealSearchResult(_ path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        pendingSelection = path
        navigate(to: parent.isEmpty ? "/" : parent)
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

    /// Sunburst wedges can be files or folders — du doesn't say which,
    /// so check before deciding to descend or reveal.
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
        guard let client, let serial = selectedSerial, !urls.isEmpty else { return }
        let dest = currentPath
        let suAvailable = self.suAvailable
        flightIsUpload = true
        flightTrigger &+= 1
        Task {
            await withStatus("Pushing \(urls.count) item(s)…") {
                for (i, url) in urls.enumerated() {
                    let remote = dest == "/" ? "/" + url.lastPathComponent : dest + "/" + url.lastPathComponent
                    let monitor = self.startPushMonitor(localURL: url, remotePath: remote,
                                                        index: i + 1, total: urls.count)
                    defer { monitor.cancel() }
                    try await client.push(localURL: url, toRemoteDir: dest, serial: serial, suAvailable: suAvailable)
                }
            }
            await loadCurrentPath()
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

    // MARK: - Helpers

    private func childPath(_ name: String) -> String {
        currentPath == "/" ? "/" + name : currentPath + "/" + name
    }

    private func withStatus(_ message: String, _ body: () async throws -> Void) async {
        isBusy = true
        statusMessage = message
        defer {
            isBusy = false
            statusMessage = ""
            activeTransfer = nil
        }
        do {
            try await body()
        } catch let e as AdbError {
            error = e
        } catch {
            self.error = AdbError(message: error.localizedDescription)
        }
    }
}
