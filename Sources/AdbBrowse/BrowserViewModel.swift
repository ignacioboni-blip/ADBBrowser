import SwiftUI
import UniformTypeIdentifiers

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

    var title: String {
        switch kind {
        case .pull(let items, _, _):
            return items.count == 1 ? "Download \(items[0].file.name)" : "Download \(items.count) items"
        case .push(let items, _):
            return items.count == 1 ? "Upload \(items[0].destName)" : "Upload \(items.count) items"
        }
    }

    var subtitle: String {
        switch kind {
        case .pull(_, let dest, _):
            return dest.path
        case .push(_, let destDir):
            return destDir
        }
    }
}

/// Fast-changing transfer state, split out of BrowserViewModel so the
/// progress-monitor ticks (every 400–900 ms during a transfer) only
/// re-render the status bar and drawer — not the whole browser window.
@MainActor
final class TransferCenter: ObservableObject {
    @Published var active: TransferProgress?
    @Published var batches: [TransferBatch] = []
    @Published private(set) var flightTrigger = 0
    @Published private(set) var flightIsUpload = false

    var queuedCount: Int { max(0, batches.count - 1) }
    var hasAny: Bool { active != nil || !batches.isEmpty }

    func pulseFlight(isUpload: Bool) {
        flightIsUpload = isUpload
        flightTrigger &+= 1
    }
}

@MainActor
final class BrowserViewModel: ObservableObject {
    private static let noisyLogcatTags: Set<String> = ["trusty", "gsp_crypto_proxy_srv"]

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
    @Published var filterText = "" {
        didSet { updateVisibleEntries() }
    }
    @Published var filterFocusRequest = 0
    @Published var showHidden = UserDefaults.standard.bool(forKey: "showHidden") {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHidden")
            updateVisibleEntries()
        }
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
    @Published var bookmarks: [BookmarkedPath] = BrowserViewModel.loadBookmarks() {
        didSet { BrowserViewModel.saveBookmarks(bookmarks) }
    }
    @Published var quickLookItem: URL?
    @Published var quickLookItems: [URL] = []
    @Published var usageTree: UsageNode?
    @Published var isMeasuring = false
    @Published var infoFile: RemoteFile?
    private var usageCache: [String: UsageNode] = [:]

    // Activity / errors
    @Published var isBusy = false
    @Published var statusMessage = ""
    @Published var error: AdbError?
    @Published var pendingDeletion: [RemoteFile] = []
    @Published var conflictPrompt: ConflictPrompt?
    @Published var apkPrompt: [URL]?
    @Published var isWifiWizardVisible = false
    @Published var isDiagnosticsVisible = false
    @Published var isLogcatVisible = false
    @Published var isApkManagerVisible = false
    @Published var isHelpVisible = false
    @Published var diagnostics = ConnectionDiagnostics()
    private var logcatLines: [LogcatLine] = []
    @Published private(set) var filteredLogcatLines: [LogcatLine] = []
    @Published var logcatFilter = "" {
        didSet { refilterLogcat() }
    }
    @Published var logcatLevel = "All" {
        didSet { refilterLogcat() }
    }
    @Published var quietLogcat = (UserDefaults.standard.object(forKey: "quietLogcat") as? Bool) ?? true {
        didSet {
            UserDefaults.standard.set(quietLogcat, forKey: "quietLogcat")
            refilterLogcat()
        }
    }
    @Published var isLogcatRunning = false
    @Published var packages: [AndroidPackage] = []
    @Published var packageFilter = ""
    @Published var packageScopeThirdPartyOnly = true
    @Published var isLoadingPackages = false
    @Published var aapt2Missing = false
    @Published var isTransferDrawerVisible = false

    // Transfer queue — fast-changing progress lives in its own observable.
    let transfers = TransferCenter()
    private var batchWorker: Task<Void, Never>?

    // Internal clipboard for device-side copy/move
    @Published private(set) var clipboardPaths: [String] = []
    @Published private(set) var clipboardIsCut = false

    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var pollTask: Task<Void, Never>?
    private var trackTask: Task<Void, Never>?
    private var deviceRefreshDebounce: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var logcatTask: Task<Void, Never>?
    private var packageMetadataTask: Task<Void, Never>?
    private var wallpaperThemeSignature: String?
    private var wallpaperThemeHex: String?

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
        updateVisibleEntries()
    }

    /// Cached — the table, status bar, and filter bar all read this on every
    /// render, so recomputing the filter per access made selection feel laggy
    /// in big folders. Refreshed whenever entries/sort/filter/hidden change.
    private(set) var visibleEntries: [RemoteFile] = []

    private func updateVisibleEntries() {
        var list = sortedEntries
        if !showHidden { list = list.filter { !$0.name.hasPrefix(".") } }
        if !filterText.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
        }
        visibleEntries = list
    }

    var canBookmarkCurrentPath: Bool { !bookmarks.contains(where: { $0.path == currentPath }) }

    private func logcatLineMatches(_ line: LogcatLine) -> Bool {
        let levelMatches = logcatLevel == "All" || line.level == logcatLevel
        let textMatches = logcatFilter.isEmpty || line.text.localizedCaseInsensitiveContains(logcatFilter)
        let quietMatches = !quietLogcat || !Self.noisyLogcatTags.contains(line.tag)
        return levelMatches && textMatches && quietMatches
    }

    /// Full recompute — only when a filter control changes, never per line.
    private func refilterLogcat() {
        filteredLogcatLines = logcatLines.filter(logcatLineMatches)
    }

    var filteredPackages: [AndroidPackage] {
        packages.filter { package in
            packageFilter.isEmpty || package.name.localizedCaseInsensitiveContains(packageFilter)
        }
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
        reconnectTask?.cancel()
        loadTask?.cancel()
        logcatTask?.cancel()
        packageMetadataTask?.cancel()
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
        // Start the server first, then fire concurrent calls — otherwise they
        // race to bind port 5037 on a cold start and all fail.
        Task {
            await client.startServer()
            // If a server was already running (Android Studio, a terminal) it
            // is on the broken openscreen mDNS backend: pairing faults and
            // wireless devices are never rediscovered after a port change,
            // which forced users back into the pairing wizard. Restart it
            // once with the Bonjour backend before anything wireless runs.
            await ensureWirelessReady()
            startDeviceTracking(client: client)
            startReconnectLoop(client: client)
            refreshDevices()
            if await reconnectWirelessDevices(client: client) {
                refreshDevices(quiet: true)
            }
        }
    }

    func refreshDevices(quiet: Bool = false) {
        guard let client else { return }
        Task {
            let apply = { (found: [DeviceInfo]) in
                self.devices = found
                // Remember usable ip:port endpoints so the reconnect loop can
                // revive them after a drop. Only usable ones: a lingering
                // offline entry carries a dead port that would evict the
                // freshly-working endpoint for the same host.
                for d in found where d.serial.contains(":") && d.isUsable {
                    self.rememberWireless(d.serial)
                }
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

    // MARK: - Wireless auto-reconnect

    @Published private(set) var knownWirelessEndpoints: [String] =
        UserDefaults.standard.stringArray(forKey: "wirelessEndpoints") ?? []
    private var reconnectTask: Task<Void, Never>?

    private func rememberWireless(_ endpoint: String) {
        guard endpoint.contains(":") else { return }
        // One endpoint per host: Android rotates the wireless-debugging port
        // on every reboot/toggle, so keeping old ports for the same phone just
        // makes every reconnect pass slower (each dead port costs a timeout).
        let host = endpoint.split(separator: ":").first.map(String.init) ?? endpoint
        var updated = knownWirelessEndpoints.filter {
            $0.split(separator: ":").first.map(String.init) != host
        }
        updated.append(endpoint)
        if updated.count > 8 { updated.removeFirst(updated.count - 8) }
        guard updated != knownWirelessEndpoints else { return }
        knownWirelessEndpoints = updated
        UserDefaults.standard.set(knownWirelessEndpoints, forKey: "wirelessEndpoints")
    }

    func forgetWireless(_ endpoint: String) {
        knownWirelessEndpoints.removeAll { $0 == endpoint }
        UserDefaults.standard.set(knownWirelessEndpoints, forKey: "wirelessEndpoints")
        Task { await client?.disconnect(endpoint: endpoint) }
    }

    /// Quietly revive dropped wireless connections: every few seconds, try to
    /// reconnect any remembered endpoint that isn't currently online.
    private func startReconnectLoop(client: AdbClient) {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(6))
                guard let self else { return }
                if await self.reconnectWirelessDevices(client: client) {
                    self.refreshDevices(quiet: true)
                }
            }
        }
    }

    /// Try to reconnect paired Wi-Fi devices immediately or from the polling
    /// loop. mDNS connect services cover the common case where Android changes
    /// the wireless debugging port after the app was quit.
    @discardableResult
    private func reconnectWirelessDevices(client: AdbClient) async -> Bool {
        // Work off fresh data so we never disturb a healthy connection. Leave
        // alone anything that isn't outright offline — a device in
        // "connecting"/"authorizing" is mid-TLS-handshake, and disconnecting
        // it every pass would keep killing a connection about to succeed.
        let current = (try? await client.listDevices()) ?? []
        let settled = Set(current.filter { $0.state != "offline" }.map(\.serial))

        var targets = Set(knownWirelessEndpoints)
        for svc in await client.mdnsServices() where svc.isConnect {
            targets.insert(svc.endpoint)
        }

        let missing = targets.subtracting(settled)
        guard !missing.isEmpty else { return false }

        // Attempt every endpoint concurrently: with several stale ports a
        // serial pass took up to 6 s × N and stalled startup reconnects.
        let revived = await withTaskGroup(of: String?.self) { group in
            for ep in missing {
                group.addTask {
                    await client.disconnect(endpoint: ep)   // clear stale/offline state
                    return (try? await client.connect(endpoint: ep, timeout: 6)) != nil ? ep : nil
                }
            }
            var connected: [String] = []
            for await ep in group where ep != nil {
                connected.append(ep!)
            }
            return connected
        }
        for ep in revived {
            rememberWireless(ep)
        }
        return !revived.isEmpty
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

    // MARK: - Wireless pairing

    func wifiPair(endpoint: String, code: String) async throws {
        guard let client else { throw AdbError(message: "adb is not available") }
        do {
            try await client.pair(endpoint: endpoint, code: code)
        } catch let e as AdbError {
            // A pre-existing adb server may be using the broken openscreen mDNS
            // backend. Restart it with Bonjour and retry — the fault happens
            // before the phone is reached, so the pairing code is still valid.
            if e.message.contains("protocol fault") {
                await client.restartServer()
                do {
                    try await client.pair(endpoint: endpoint, code: code)
                    return
                } catch let retry as AdbError {
                    throw AdbError(message: NetworkInfo.pairingErrorMessage(endpoint: endpoint, underlying: retry.message))
                }
            }
            throw AdbError(message: NetworkInfo.pairingErrorMessage(endpoint: endpoint, underlying: e.message))
        }
    }

    /// Connect to a paired device and select it. Returns its serial (host:port).
    @discardableResult
    func wifiConnect(endpoint: String) async throws -> String {
        guard let client else { throw AdbError(message: "adb is not available") }
        try await client.connect(endpoint: endpoint)
        rememberWireless(endpoint)
        let found = (try? await client.listDevices()) ?? []
        devices = found
        if found.contains(where: { $0.serial == endpoint && $0.isUsable }) {
            selectedSerial = endpoint
        } else if let match = found.first(where: { $0.serial.hasPrefix(endpoint.split(separator: ":").first.map(String.init) ?? endpoint) && $0.isUsable }) {
            selectedSerial = match.serial
        }
        return endpoint
    }

    func mdnsScan() async -> [MdnsService] {
        guard let client else { return [] }
        return await client.mdnsServices()
    }

    /// One-time server check: if the running server is on the openscreen mDNS
    /// backend (broken for pairing and discovery on macOS), restart it with
    /// the Bonjour backend. A server we started ourselves already has the
    /// right environment, so this usually does nothing.
    private var wirelessServerReady = false
    func ensureWirelessReady() async {
        guard !wirelessServerReady, let client else { return }
        wirelessServerReady = true
        if await client.serverUsesOpenscreen() {
            await client.restartServer()
        }
    }

    func makeQrPairing() -> QrPairing {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        func token(_ n: Int) -> String { String((0..<n).map { _ in alphabet.randomElement()! }) }
        return QrPairing(serviceName: "ADBBrowser-" + token(6), password: token(8))
    }

    /// After the phone scans the QR it advertises a pairing service named after
    /// our QR. Watch mDNS for it, then pair with the embedded password.
    func qrPairAndWait(_ qr: QrPairing) async throws {
        guard let client else { throw AdbError(message: "adb is not available") }
        await ensureWirelessReady()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try Task.checkCancellation()
            let services = await client.mdnsServices()
            if let pairing = services.first(where: { $0.isPairing && $0.name.contains(qr.serviceName) }) {
                do {
                    try await client.pair(endpoint: pairing.endpoint, code: qr.password)
                } catch let e as AdbError {
                    throw AdbError(message: NetworkInfo.pairingErrorMessage(endpoint: pairing.endpoint, underlying: e.message))
                }
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        throw AdbError(message: "Timed out waiting for your phone to scan the code.")
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
            await self.reloadCurrentPathNow()
            self.rootMode = await detected
            await self.refreshLiveStatus(client: client, serial: serial)
            if self.lastListingFailed {
                await self.reloadCurrentPathNow()   // path needed root after all
            }
        }
    }

    // MARK: - Live presence polling

    private func startPolling(client: AdbClient, serial: String) {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !Task.isCancelled else { return }
                await self.refreshLiveStatus(client: client, serial: serial)
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func refreshLiveStatus(client: AdbClient, serial: String) async {
        var status = await client.fetchStatus(serial: serial)
        if status.seedSource == "preset" || status.seedHex == nil {
            status.seedHex = await wallpaperSeedHex(client: client, serial: serial) ?? status.seedHex
        }
        deviceStatus = status
        let newTheme = DeviceTheme.from(hex: status.seedHex)
        if newTheme != theme {
            withAnimation(.easeInOut(duration: 0.8)) { theme = newTheme }
        }
    }

    private func wallpaperSeedHex(client: AdbClient, serial: String) async -> String? {
        guard let signature = await client.wallpaperSignature(serial: serial, suAvailable: suAvailable) else {
            return wallpaperThemeHex
        }
        if signature == wallpaperThemeSignature {
            return wallpaperThemeHex
        }
        let dir = Self.makeTempDir()
        guard let url = try? await client.pullWallpaper(to: dir, serial: serial, suAvailable: suAvailable),
              let hex = Self.averageImageHex(at: url) else {
            return wallpaperThemeHex
        }
        wallpaperThemeSignature = signature
        wallpaperThemeHex = hex
        return hex
    }

    // MARK: - Navigation

    func navigate(to rawPath: String, direction: NavDirection? = nil) {
        isEditingPath = false
        let path = normalize(rawPath)
        guard path != currentPath else { scheduleLoadCurrentPath(); return }
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
        scheduleLoadCurrentPath()
    }

    func reload() {
        invalidateListing()
        scheduleLoadCurrentPath()
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
                try Task.checkCancellation()
                let fresh = try await client.list(path: path, serial: serial, su: useSu)
                try Task.checkCancellation()
                storeListing(fresh, key: key, path: path)
            } catch is CancellationError {
                return
            } catch let e as AdbError {
                lastListingFailed = true
                error = e
            } catch {}
            return
        }

        await withStatus("Loading \(path)…") {
            try Task.checkCancellation()
            do {
                let fresh = try await client.list(path: path, serial: serial, su: self.useSu)
                try Task.checkCancellation()
                self.storeListing(fresh, key: key, path: path)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                self.lastListingFailed = true
                throw error
            }
        }
    }

    private func scheduleLoadCurrentPath() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadCurrentPath()
        }
    }

    private func reloadCurrentPathNow() async {
        loadTask?.cancel()
        await loadCurrentPath()
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

    func addBookmarkForCurrentPath() {
        guard !bookmarks.contains(where: { $0.path == currentPath }) else { return }
        bookmarks.append(BookmarkedPath(name: Self.defaultBookmarkName(for: currentPath), path: currentPath))
        bookmarks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func removeBookmark(_ path: String) {
        bookmarks.removeAll { $0.path == path }
    }

    func renameBookmark(_ bookmark: BookmarkedPath) {
        let alert = NSAlert()
        alert.messageText = "Rename Favorite"
        alert.informativeText = bookmark.path
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: bookmark.name)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let idx = bookmarks.firstIndex(where: { $0.path == bookmark.path }) else { return }
        bookmarks[idx].name = name
        bookmarks.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func normalize(_ raw: String) -> String {
        var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty { p = "/" }
        if !p.hasPrefix("/") { p = "/" + p }
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private static func defaultBookmarkName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private static func loadBookmarks() -> [BookmarkedPath] {
        if let data = UserDefaults.standard.data(forKey: "bookmarkedPaths"),
           let decoded = try? JSONDecoder().decode([BookmarkedPath].self, from: data) {
            return decoded
        }
        return (UserDefaults.standard.stringArray(forKey: "bookmarks") ?? []).map {
            BookmarkedPath(name: defaultBookmarkName(for: $0), path: $0)
        }
    }

    private static func saveBookmarks(_ bookmarks: [BookmarkedPath]) {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: "bookmarkedPaths")
        }
        UserDefaults.standard.set(bookmarks.map(\.path), forKey: "bookmarks")
    }

    // MARK: - Tools

    func refreshDiagnostics() {
        guard let client else { return }
        Task {
            diagnostics = await client.diagnostics(knownWirelessEndpoints: knownWirelessEndpoints)
        }
    }

    func showDiagnostics() {
        isDiagnosticsVisible = true
        refreshDiagnostics()
    }

    private var logcatPending: [LogcatLine] = []
    private var logcatFlushScheduled = false

    func startLogcat() {
        guard let client, let serial = selectedSerial else { return }
        logcatTask?.cancel()
        logcatLines = []
        logcatPending = []
        filteredLogcatLines = []
        isLogcatRunning = true
        logcatTask = Task { [weak self] in
            for await line in client.logcat(serial: serial) {
                guard let self, !Task.isCancelled else { return }
                // Buffer and flush on a timer: publishing per line made the
                // viewer re-filter and re-diff thousands of rows per line,
                // pegging a core on busy streams.
                self.logcatPending.append(LogcatLine(text: line))
                self.scheduleLogcatFlush()
            }
            self?.flushLogcat()
            self?.isLogcatRunning = false
        }
    }

    private func scheduleLogcatFlush() {
        guard !logcatFlushScheduled else { return }
        logcatFlushScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self else { return }
            self.logcatFlushScheduled = false
            self.flushLogcat()
        }
    }

    private func flushLogcat() {
        guard !logcatPending.isEmpty else { return }
        let fresh = logcatPending
        logcatPending.removeAll(keepingCapacity: true)
        logcatLines.append(contentsOf: fresh)
        if logcatLines.count > 3000 {
            logcatLines.removeFirst(logcatLines.count - 3000)
        }
        // Incremental: only the new lines are filtered, not the whole buffer.
        filteredLogcatLines.append(contentsOf: fresh.filter(logcatLineMatches))
        if filteredLogcatLines.count > 3000 {
            filteredLogcatLines.removeFirst(filteredLogcatLines.count - 3000)
        }
    }

    func stopLogcat() {
        logcatTask?.cancel()
        logcatTask = nil
        flushLogcat()
        isLogcatRunning = false
    }

    func clearLogcat() {
        guard let client, let serial = selectedSerial else { return }
        logcatLines = []
        logcatPending = []
        filteredLogcatLines = []
        Task { await client.clearLogcat(serial: serial) }
    }

    func loadPackages() {
        guard let client, let serial = selectedSerial else { return }
        packageMetadataTask?.cancel()
        isLoadingPackages = true
        aapt2Missing = AdbClient.aapt2Path == nil
        Task {
            do {
                packages = try await client.listPackages(serial: serial, thirdPartyOnly: packageScopeThirdPartyOnly)
                enrichPackages(client: client, serial: serial)
            } catch let e as AdbError {
                error = e
            } catch {
                self.error = AdbError(message: error.localizedDescription)
            }
            isLoadingPackages = false
        }
    }

    private func enrichPackages(client: AdbClient, serial: String) {
        packageMetadataTask = Task { [weak self] in
            guard let self else { return }
            let snapshot = self.packages
            // A few packages at a time — serial enrichment made icons trickle
            // in for minutes on large lists; more would crowd the adb link.
            let limiter = ConcurrencyLimiter(slots: 4)
            await withTaskGroup(of: AndroidPackage?.self) { group in
                for package in snapshot {
                    group.addTask {
                        guard await limiter.acquire() else { return nil }
                        let enriched = await client.enrichPackage(package, serial: serial)
                        await limiter.release()
                        return enriched
                    }
                }
                for await enriched in group {
                    guard let enriched, !Task.isCancelled else { continue }
                    if let index = self.packages.firstIndex(where: { $0.id == enriched.id }) {
                        self.packages[index] = enriched
                    }
                }
            }
        }
    }

    func launchPackage(_ package: AndroidPackage) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            await withStatus("Launching \(package.shortName)…") {
                try await client.launchPackage(package.name, serial: serial)
            }
        }
    }

    func forceStopPackage(_ package: AndroidPackage) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            await withStatus("Stopping \(package.shortName)…") {
                try await client.forceStopPackage(package.name, serial: serial)
            }
        }
    }

    func clearPackageData(_ package: AndroidPackage) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            await withStatus("Clearing \(package.shortName)…") {
                try await client.clearPackageData(package.name, serial: serial)
            }
        }
    }

    func uninstallPackage(_ package: AndroidPackage) {
        guard let client, let serial = selectedSerial else { return }
        Task {
            await withStatus("Uninstalling \(package.shortName)…") {
                try await client.uninstallPackage(package.name, serial: serial)
            }
            packages.removeAll { $0.id == package.id }
        }
    }

    func pullApk(_ package: AndroidPackage) {
        guard let client, let serial = selectedSerial else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save APK"
        panel.message = "Choose where to save \(package.shortName).apk"
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        Task {
            await withStatus("Pulling \(package.shortName).apk…") {
                try await client.pull(remotePath: package.apkPath,
                                      fileName: package.shortName + ".apk",
                                      destName: package.shortName + ".apk",
                                      toLocalDir: dir,
                                      serial: serial,
                                      suAvailable: self.suAvailable)
            }
        }
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
        // The cut clipboard is cleared per-item in performPaste once each move
        // succeeds — clearing here lost the selection when a move failed or
        // the conflict dialog was cancelled.

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
        var moved: Set<String> = []
        await withStatus("\(isCut ? "Moving" : "Copying") \(sources.count) item(s)…") {
            for src in sources {
                let name = (src as NSString).lastPathComponent
                var targetName = name
                if existing.contains(name) {
                    switch resolution {
                    case .skip, nil:
                        continue   // skipped items stay on the clipboard
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
                    moved.insert(src)
                } else {
                    try await client.copy(from: src, to: target, serial: serial, su: self.useSu)
                }
            }
        }
        if isCut, !moved.isEmpty {
            // Drop only what actually moved; a failed item can be retried.
            clipboardPaths.removeAll { moved.contains($0) }
            if clipboardPaths.isEmpty { clipboardIsCut = false }
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

    /// "Install APK…" button in the APK manager: pick .apk files in Finder.
    func installApkViaPanel() {
        guard selectedSerial != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.prompt = "Install"
        panel.message = "Choose APK files to install on the device"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        installApks(panel.urls)
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
            if failures.count < urls.count, isApkManagerVisible {
                loadPackages()   // show the newly installed app in the list
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
        defer { statusMessage = "Downloaded \(file.name) to Finder" }
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

    private static func averageImageHex(at url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let data = cg.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }

        let width = cg.width
        let height = cg.height
        let bytesPerRow = cg.bytesPerRow
        let bytesPerPixel = max(1, cg.bitsPerPixel / 8)
        let sampleStep = max(1, min(width, height) / 80)
        var red = 0.0, green = 0.0, blue = 0.0, count = 0.0

        for y in stride(from: 0, to: height, by: sampleStep) {
            for x in stride(from: 0, to: width, by: sampleStep) {
                let offset = y * bytesPerRow + x * bytesPerPixel
                guard offset + 2 < CFDataGetLength(data) else { continue }
                let r: UInt8
                let g: UInt8
                let b: UInt8
                if cg.bitmapInfo.contains(.byteOrder32Little), bytesPerPixel >= 4 {
                    b = bytes[offset]
                    g = bytes[offset + 1]
                    r = bytes[offset + 2]
                } else {
                    r = bytes[offset]
                    g = bytes[offset + 1]
                    b = bytes[offset + 2]
                }
                let brightness = (Double(r) + Double(g) + Double(b)) / (3.0 * 255.0)
                // Avoid letting very dark or blown-out wallpaper areas dominate.
                guard brightness > 0.08, brightness < 0.94 else { continue }
                red += Double(r)
                green += Double(g)
                blue += Double(b)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return String(format: "%02X%02X%02X",
                      Int(red / count).clampedByte,
                      Int(green / count).clampedByte,
                      Int(blue / count).clampedByte)
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
        transfers.batches.append(batch)
        transfers.pulseFlight(isUpload: batch.isUpload)
        pumpTransfers()
    }

    func cancelCurrentTransfer() {
        batchWorker?.cancel()
    }

    private func pumpTransfers() {
        guard batchWorker == nil, let batch = transfers.batches.first else { return }
        batchWorker = Task {
            await self.run(batch: batch)
            self.transfers.batches.removeAll { $0.id == batch.id }
            self.transfers.active = nil
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
                self?.transfers.active = TransferProgress(
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
                self?.transfers.active = TransferProgress(
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

private extension Int {
    var clampedByte: Int { Swift.max(0, Swift.min(255, self)) }
}
