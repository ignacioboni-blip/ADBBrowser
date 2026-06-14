import Foundation

struct ShellResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var ok: Bool { exitCode == 0 }
    var combinedError: String {
        let e = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !e.isEmpty { return e }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    var combinedOutput: String {
        [stdout, stderr]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

/// Thin async wrapper around the adb binary. All methods are safe to call
/// from any task; each invocation spawns its own short-lived process.
final class AdbClient: Sendable {
    let adbPath: String

    init(adbPath: String) {
        self.adbPath = adbPath
    }

    // MARK: adb binary discovery

    static func resolveAdbPath() -> String? {
        if let custom = UserDefaults.standard.string(forKey: "adbPath"),
           FileManager.default.isExecutableFile(atPath: custom) {
            return custom
        }
        var candidates = [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.insert(home + "/platform-tools/adb", at: 0)
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    static func resolveAapt2Path() -> String? {
        var roots: [String] = []
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            roots.append(home + "/build-tools")
        }
        roots.append(NSHomeDirectory() + "/Library/Android/sdk/build-tools")

        for root in roots {
            guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for version in versions.sorted(by: { $0.localizedStandardCompare($1) == .orderedDescending }) {
                let candidate = root + "/" + version + "/aapt2"
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    // MARK: low-level process runner

    /// Environment for every adb process we spawn. `ADB_MDNS_OPENSCREEN=0`
    /// forces adb's server to use Apple's Bonjour mDNS backend; the bundled
    /// "openscreen" backend is broken for `adb pair` on macOS (it faults with
    /// "protocol fault (couldn't read status message)" before any network I/O).
    static let serverEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["ADB_MDNS_OPENSCREEN"] = "0"
        return env
    }()

    /// Start the adb server once, up front. Without this, the app's concurrent
    /// startup calls each try to fork-start a server and collide on port 5037
    /// ("Address already in use" / "server didn't ACK").
    func startServer() async {
        _ = try? await run(["start-server"], timeout: 30)
    }

    /// Restart the adb server so it picks up `serverEnvironment` (needed when a
    /// server started by something else — with the broken backend — is running).
    func restartServer() async {
        _ = try? await run(["kill-server"], timeout: 10)
        _ = try? await run(["start-server"], timeout: 20)
    }

    private struct RawResult {
        let stdout: Data
        let stderr: Data
        let exitCode: Int32
    }

    private func run(_ arguments: [String], timeout: TimeInterval) async throws -> ShellResult {
        let raw = try await runRaw(arguments, timeout: timeout)
        return ShellResult(
            stdout: String(data: raw.stdout, encoding: .utf8) ?? "",
            stderr: String(data: raw.stderr, encoding: .utf8) ?? "",
            exitCode: raw.exitCode
        )
    }

    private func runRaw(_ arguments: [String], timeout: TimeInterval) async throws -> RawResult {
        let adbPath = self.adbPath
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if box.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: adbPath)
                process.arguments = arguments
                process.environment = AdbClient.serverEnvironment

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AdbError(message: "Could not launch adb: \(error.localizedDescription)"))
                    return
                }
                box.attach(process)

                let timedOut = LockedFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }

                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.wait()
                    if box.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if timedOut.value {
                        continuation.resume(throwing: AdbError(message: "adb command timed out: adb \(arguments.joined(separator: " "))"))
                    } else {
                        continuation.resume(returning: RawResult(
                            stdout: outData,
                            stderr: errData,
                            exitCode: process.terminationStatus
                        ))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    private static func runLocal(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ShellResult {
        let raw = try await runLocalRaw(executable, arguments, timeout: timeout)
        return ShellResult(
            stdout: String(data: raw.stdout, encoding: .utf8) ?? "",
            stderr: String(data: raw.stderr, encoding: .utf8) ?? "",
            exitCode: raw.exitCode
        )
    }

    private static func runLocalRaw(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> RawResult {
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if box.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                let group = DispatchGroup()
                var outData = Data()
                var errData = Data()

                group.enter()
                DispatchQueue.global().async {
                    outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: AdbError(message: "Could not launch \(executable): \(error.localizedDescription)"))
                    return
                }
                box.attach(process)

                let timedOut = LockedFlag()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut.set()
                        process.terminate()
                    }
                }

                DispatchQueue.global().async {
                    process.waitUntilExit()
                    group.wait()
                    if box.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if timedOut.value {
                        continuation.resume(throwing: AdbError(message: "\(executable) timed out"))
                    } else {
                        continuation.resume(returning: RawResult(stdout: outData, stderr: errData, exitCode: process.terminationStatus))
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    // MARK: shell helpers

    /// Quote a string for the device-side shell.
    static func quote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private let shellPool = ShellPool()

    /// Run a shell command on the device via a persistent `adb shell`
    /// (root shell when `su`), falling back to a one-shot invocation if the
    /// persistent shell hiccups (device reconnect, su death, …).
    func shell(_ command: String, serial: String, su: Bool, timeout: TimeInterval = 25) async throws -> ShellResult {
        let persistent = await shellPool.shell(adbPath: adbPath, serial: serial, su: su)
        do {
            return try await persistent.run(command, timeout: timeout)
        } catch {
            return try await oneShotShell(command, serial: serial, su: su, timeout: timeout)
        }
    }

    /// Spawn a fresh adb process for one command. Slower, but has no shared
    /// state — used as fallback and for root-mode probes.
    func oneShotShell(_ command: String, serial: String, su: Bool, timeout: TimeInterval = 25) async throws -> ShellResult {
        let full = su ? "su -c \(Self.quote(command))" : command
        return try await run(["-s", serial, "shell", full], timeout: timeout)
    }

    // MARK: devices & root

    func listDevices() async throws -> [DeviceInfo] {
        let result = try await run(["devices", "-l"], timeout: 15)
        guard result.ok else { throw AdbError(message: "adb devices failed: \(result.combinedError)") }

        var devices: [DeviceInfo] = []
        for line in result.stdout.split(separator: "\n").dropFirst() {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens[0]
            let state = tokens[1]
            var model = "", codename = "", product = ""
            for t in tokens.dropFirst(2) {
                if t.hasPrefix("model:") { model = String(t.dropFirst(6)) }
                else if t.hasPrefix("device:") { codename = String(t.dropFirst(7)) }
                else if t.hasPrefix("product:") { product = String(t.dropFirst(8)) }
            }
            devices.append(DeviceInfo(serial: serial, state: state, model: model,
                                      deviceCodename: codename, product: product))
        }
        return DeviceInfo.deduplicated(devices)
    }

    /// Detect how we can get root without restarting adbd. Uses one-shot
    /// shells so a hung `su` prompt can't poison the persistent shell.
    func detectRootMode(serial: String) async -> RootMode {
        if let r = try? await oneShotShell("id -u", serial: serial, su: false, timeout: 15),
           r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            return .adbdRoot
        }
        // Generous timeout: first run may pop a Magisk/KernelSU grant dialog on the phone.
        if let r = try? await oneShotShell("id -u", serial: serial, su: true, timeout: 45),
           r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            return .su
        }
        return .none
    }

    // MARK: live device presence

    /// Battery, storage and Material You seed color. Best-effort: any probe
    /// that fails just leaves its field nil.
    func fetchStatus(serial: String) async -> DeviceStatus {
        var status = DeviceStatus()

        if let r = try? await shell("dumpsys battery", serial: serial, su: false, timeout: 15), r.ok {
            for line in r.stdout.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("level:"), let v = Int(t.dropFirst(6).trimmingCharacters(in: .whitespaces)) {
                    status.batteryLevel = v
                }
                if t == "AC powered: true" || t == "USB powered: true" || t == "Wireless powered: true" {
                    status.isCharging = true
                }
            }
        }

        if let r = try? await shell("df /data", serial: serial, su: false, timeout: 15), r.ok,
           let last = r.stdout.split(separator: "\n").last {
            let tok = last.split(separator: " ", omittingEmptySubsequences: true)
            if tok.count >= 4, let totalKB = Int64(tok[1]), let availKB = Int64(tok[3]) {
                status.totalBytes = totalKB * 1024
                status.freeBytes = availKB * 1024
            }
        }

        if let r = try? await shell("settings get secure theme_customization_overlay_packages",
                                    serial: serial, su: false, timeout: 15), r.ok,
           let data = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            status.seedHex = (obj["android.theme.customization.system_palette"] as? String)
                ?? (obj["android.theme.customization.accent_color"] as? String)
            status.seedSource = obj["android.theme.customization.color_source"] as? String
        }

        return status
    }

    func wallpaperSignature(serial: String, suAvailable: Bool) async -> String? {
        let command = "stat -c '%Y:%s' /data/system/users/0/wallpaper 2>/dev/null"
        if suAvailable,
           let r = try? await oneShotShell(command, serial: serial, su: true, timeout: 10),
           r.ok {
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let r = try? await oneShotShell(command, serial: serial, su: false, timeout: 10), r.ok {
            return r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    func pullWallpaper(to dir: URL, serial: String, suAvailable: Bool) async throws -> URL {
        try await pull(remotePath: "/data/system/users/0/wallpaper",
                       fileName: "wallpaper",
                       toLocalDir: dir,
                       serial: serial,
                       suAvailable: suAvailable)
        return dir.appendingPathComponent("wallpaper")
    }

    /// Recursive case-insensitive filename search, capped at 80 results.
    func find(query: String, under root: String, serial: String, su: Bool) async -> [String] {
        let cmd = "find \(Self.quote(root)) -iname \(Self.quote("*\(query)*")) 2>/dev/null | head -80"
        guard let r = try? await shell(cmd, serial: serial, su: su, timeout: 60) else { return [] }
        return r.stdout
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .init(charactersIn: "\r")) }
            .filter { $0.hasPrefix("/") && $0 != root }
    }

    /// Recursive disk usage (`du -a -k -d N`) including files, for the
    /// storage sunburst. Returns (path, bytes) pairs; paths are normalized
    /// without trailing slashes.
    func diskUsage(path: String, serial: String, su: Bool, depth: Int = 3) async throws -> [(path: String, bytes: Int64)] {
        // Trailing slash so du follows symlinked roots like /sdcard.
        let target = path.hasSuffix("/") ? path : path + "/"
        let cmd = "du -a -k -d \(depth) \(Self.quote(target)) 2>/dev/null"
        let result = try await shell(cmd, serial: serial, su: su, timeout: 180)

        var entries: [(String, Int64)] = []
        for line in result.stdout.split(separator: "\n") {
            guard let tab = line.firstIndex(where: { $0 == "\t" || $0 == " " }),
                  let kb = Int64(line[..<tab].trimmingCharacters(in: .whitespaces)) else { continue }
            var p = String(line[line.index(after: tab)...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: .init(charactersIn: "\r"))
            while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            entries.append((p, kb * 1024))
        }
        if entries.isEmpty {
            throw AdbError(message: "Could not measure \(path): \(result.combinedError)")
        }
        return entries
    }

    /// Current byte size of a remote file (used for push progress).
    func statSize(path: String, serial: String, su: Bool) async -> Int64? {
        guard let r = try? await shell("stat -c %s \(Self.quote(path))", serial: serial, su: su, timeout: 10),
              r.ok else { return nil }
        return Int64(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: directory listing

    func list(path: String, serial: String, su: Bool) async throws -> [RemoteFile] {
        // Trailing slash makes toybox ls follow symlinked directories
        // (e.g. /sdcard -> /storage/self/primary) instead of listing the link.
        let target = path.hasSuffix("/") ? path : path + "/"
        let result = try await shell("ls -lA \(Self.quote(target))", serial: serial, su: su)
        // toybox ls exits non-zero if *any* entry fails to stat, but still prints
        // the rest — only fail if we got nothing back.
        let files = LsParser.parse(output: result.stdout, directory: path)
        if !result.ok && files.isEmpty {
            throw AdbError(message: result.combinedError.isEmpty ? "Could not list \(path)" : result.combinedError)
        }
        return files
    }

    func isDirectory(path: String, serial: String, su: Bool) async -> Bool {
        guard let r = try? await shell("test -d \(Self.quote(path)) && echo D", serial: serial, su: su) else { return false }
        return r.stdout.contains("D")
    }

    // MARK: device-side file operations

    func makeDirectory(path: String, serial: String, su: Bool) async throws {
        try await runOrThrow("mkdir \(Self.quote(path))", serial: serial, su: su)
    }

    func delete(path: String, serial: String, su: Bool) async throws {
        try await runOrThrow("rm -rf \(Self.quote(path))", serial: serial, su: su, timeout: 300)
    }

    func move(from: String, to: String, serial: String, su: Bool) async throws {
        try await runOrThrow("mv \(Self.quote(from)) \(Self.quote(to))", serial: serial, su: su, timeout: 600)
    }

    func copy(from: String, to: String, serial: String, su: Bool) async throws {
        try await runOrThrow("cp -a \(Self.quote(from)) \(Self.quote(to))", serial: serial, su: su, timeout: 3600)
    }

    private func runOrThrow(_ command: String, serial: String, su: Bool, timeout: TimeInterval = 60) async throws {
        let r = try await shell(command, serial: serial, su: su, timeout: timeout)
        guard r.ok else { throw AdbError(message: r.combinedError.isEmpty ? "Command failed: \(command)" : r.combinedError) }
    }

    // MARK: wireless pairing / connection

    /// `adb pair HOST:PORT CODE` — pairs with the phone's "Pair with code" dialog.
    func pair(endpoint: String, code: String) async throws {
        let r = try await run(["pair", endpoint, code], timeout: 30)
        let out = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard out.localizedCaseInsensitiveContains("success") else {
            let reason = out.split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            throw AdbError(message: reason.isEmpty ? "Pairing failed — check the code and address." : reason)
        }
    }

    /// `adb connect HOST:PORT` — connects to an already-paired device.
    func connect(endpoint: String, timeout: TimeInterval = 30) async throws {
        let r = try await run(["connect", endpoint], timeout: timeout)
        let out = (r.stdout + "\n" + r.stderr).lowercased()
        guard out.contains("connected to") || out.contains("already connected") else {
            let reason = (r.stdout + "\n" + r.stderr).split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            throw AdbError(message: reason.isEmpty ? "Could not connect to \(endpoint)." : reason)
        }
    }

    func disconnect(endpoint: String) async {
        _ = try? await run(["disconnect", endpoint], timeout: 10)
    }

    func diagnostics(knownWirelessEndpoints: [String]) async -> ConnectionDiagnostics {
        async let version = run(["version"], timeout: 8)
        async let devices = run(["devices", "-l"], timeout: 10)
        async let mdns = run(["mdns", "services"], timeout: 12)

        let versionResult = try? await version
        let devicesResult = try? await devices
        let mdnsResult = try? await mdns

        return ConnectionDiagnostics(
            adbPath: adbPath,
            adbVersion: versionResult?.combinedOutput ?? "Could not read adb version",
            devicesOutput: devicesResult?.combinedOutput ?? "Could not read adb devices",
            mdnsOutput: mdnsResult?.combinedOutput ?? "Could not read adb mDNS services",
            knownWirelessEndpoints: knownWirelessEndpoints,
            generatedAt: Date()
        )
    }

    /// `adb mdns services` — devices advertising wireless debugging on the LAN.
    func mdnsServices() async -> [MdnsService] {
        guard let r = try? await run(["mdns", "services"], timeout: 12), r.ok else { return [] }
        var services: [MdnsService] = []
        for line in r.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
                .map(String.init).filter { !$0.isEmpty }
            guard cols.count >= 3, cols[2].contains(":") else { continue }
            services.append(MdnsService(name: cols[0], type: cols[1], endpoint: cols[2]))
        }
        return services
    }

    // MARK: logcat

    func logcat(serial: String) -> AsyncStream<String> {
        let adbPath = self.adbPath
        return AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["-s", serial, "logcat", "-v", "threadtime", "-T", "1"]
            process.environment = AdbClient.serverEnvironment
            let outPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = Pipe()

            var buffer = Data()
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let lineData = buffer[..<newline]
                    buffer.removeSubrange(...newline)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        continuation.yield(line)
                    }
                }
            }
            process.terminationHandler = { _ in continuation.finish() }
            continuation.onTermination = { _ in
                outPipe.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish()
            }
        }
    }

    func clearLogcat(serial: String) async {
        _ = try? await run(["-s", serial, "logcat", "-c"], timeout: 8)
    }

    // MARK: packages

    func listPackages(serial: String, thirdPartyOnly: Bool) async throws -> [AndroidPackage] {
        let flag = thirdPartyOnly ? "-3" : ""
        let command = ["pm", "list", "packages", "-f", flag]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let r = try await oneShotShell(command, serial: serial, su: false, timeout: 45)
        guard r.ok else { throw AdbError(message: r.combinedError.isEmpty ? "Could not list packages" : r.combinedError) }
        return r.stdout
            .split(separator: "\n")
            .compactMap { line -> AndroidPackage? in
                let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.hasPrefix("package:"), let eq = text.lastIndex(of: "=") else { return nil }
                let pathStart = text.index(text.startIndex, offsetBy: "package:".count)
                let path = String(text[pathStart..<eq])
                let name = String(text[text.index(after: eq)...])
                guard !name.isEmpty, !path.isEmpty else { return nil }
                return AndroidPackage(name: name, apkPath: path)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func enrichPackage(_ package: AndroidPackage, serial: String) async -> AndroidPackage {
        guard let aapt2 = Self.resolveAapt2Path() else { return package }
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AdbBrowsePackageMetadata", isDirectory: true)
            .appendingPathComponent(package.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let apkURL = workDir.appendingPathComponent("base.apk")
        if !FileManager.default.fileExists(atPath: apkURL.path) {
            let pulled = try? await run(["-s", serial, "pull", package.apkPath, apkURL.path], timeout: 45)
            guard pulled?.ok == true else { return package }
        }

        guard let badging = try? await Self.runLocal(aapt2, ["dump", "badging", apkURL.path], timeout: 15),
              badging.ok else { return package }

        var enriched = package
        enriched.label = Self.bestApplicationLabel(from: badging.stdout)

        if let iconInApk = Self.bestIconPath(from: badging.stdout) {
            let ext = (iconInApk as NSString).pathExtension
            let iconURL = workDir.appendingPathComponent("icon.\(ext.isEmpty ? "png" : ext)")
            if !FileManager.default.fileExists(atPath: iconURL.path),
               let iconData = try? await Self.runLocalRaw("/usr/bin/unzip", ["-p", apkURL.path, iconInApk], timeout: 10),
               iconData.exitCode == 0,
               !iconData.stdout.isEmpty {
                try? iconData.stdout.write(to: iconURL)
            }
            if FileManager.default.fileExists(atPath: iconURL.path) {
                enriched.iconPath = iconURL.path
            }
        }

        return enriched
    }

    private static func badgingValue(prefix: String, in text: String) -> String? {
        for line in text.split(separator: "\n").map(String.init) where line.hasPrefix(prefix) {
            let raw = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        }
        return nil
    }

    private static func bestApplicationLabel(from badging: String) -> String? {
        if let defaultLabel = badgingValue(prefix: "application-label:", in: badging) {
            return defaultLabel
        }

        let localized = badging
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("application-label-") }
            .compactMap { line -> (locale: String, label: String)? in
                guard let colon = line.firstIndex(of: ":") else { return nil }
                let localeStart = line.index(line.startIndex, offsetBy: "application-label-".count)
                let locale = String(line[localeStart..<colon])
                let raw = String(line[line.index(after: colon)...])
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                guard !raw.isEmpty else { return nil }
                return (locale, raw)
            }

        if let english = localized.first(where: { $0.locale.hasPrefix("en") }) {
            return english.label
        }
        if let first = localized.first {
            return first.label
        }
        return badgingValue(prefix: "application: label=", in: badging)
    }

    private static func bestIconPath(from badging: String) -> String? {
        let iconLines = badging
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.hasPrefix("application-icon-") || $0.hasPrefix("application-icon:") }

        let bitmap = iconLines.compactMap { line -> String? in
            guard let value = line.split(separator: ":", maxSplits: 1).last else { return nil }
            let path = String(value).trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            let ext = (path as NSString).pathExtension.lowercased()
            return ["png", "webp", "jpg", "jpeg"].contains(ext) ? path : nil
        }
        return bitmap.last
    }

    func launchPackage(_ package: String, serial: String) async throws {
        let command = "monkey -p \(Self.quote(package)) -c android.intent.category.LAUNCHER 1"
        let r = try await oneShotShell(command, serial: serial, su: false, timeout: 15)
        guard r.ok else { throw AdbError(message: r.combinedError.isEmpty ? "Could not launch \(package)" : r.combinedError) }
    }

    func forceStopPackage(_ package: String, serial: String) async throws {
        let r = try await oneShotShell("am force-stop \(Self.quote(package))", serial: serial, su: false, timeout: 10)
        guard r.ok else { throw AdbError(message: r.combinedError.isEmpty ? "Could not force-stop \(package)" : r.combinedError) }
    }

    func clearPackageData(_ package: String, serial: String) async throws {
        let r = try await oneShotShell("pm clear \(Self.quote(package))", serial: serial, su: false, timeout: 25)
        guard r.ok, r.stdout.localizedCaseInsensitiveContains("success") else {
            throw AdbError(message: r.combinedError.isEmpty ? "Could not clear \(package)" : r.combinedError)
        }
    }

    func uninstallPackage(_ package: String, serial: String) async throws {
        let r = try await run(["-s", serial, "uninstall", package], timeout: 60)
        guard r.ok, r.stdout.localizedCaseInsensitiveContains("success") else {
            throw AdbError(message: r.combinedError.isEmpty ? "Could not uninstall \(package)" : r.combinedError)
        }
    }

    // MARK: APK install

    /// `adb install -r` — installs (or updates) an app from a local APK.
    func installApk(at url: URL, serial: String) async throws {
        let r = try await run(["-s", serial, "install", "-r", url.path], timeout: 600)
        let output = (r.stdout + "\n" + r.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        guard r.ok, output.contains("Success") else {
            // adb prints the useful reason on the last non-empty line,
            // e.g. INSTALL_FAILED_VERSION_DOWNGRADE.
            let reason = output.split(separator: "\n").last.map(String.init) ?? "install failed"
            throw AdbError(message: reason)
        }
    }

    // MARK: file metadata (Get Info)

    func chmod(_ octal: String, path: String, serial: String, su: Bool) async throws {
        try await runOrThrow("chmod \(octal) \(Self.quote(path))", serial: serial, su: su)
    }

    func chown(_ ownerGroup: String, path: String, serial: String, su: Bool) async throws {
        try await runOrThrow("chown \(Self.quote(ownerGroup)) \(Self.quote(path))", serial: serial, su: su)
    }

    /// Total size of a file or folder tree (`du -sk`).
    func sizeOf(path: String, serial: String, su: Bool) async -> Int64? {
        let target = path.hasSuffix("/") ? path : path + "/"
        guard let r = try? await shell("du -sk \(Self.quote(target))", serial: serial, su: su, timeout: 300),
              let kb = Int64(r.stdout.split(separator: "\t").first?
                  .trimmingCharacters(in: .whitespaces) ?? "") else { return nil }
        return kb * 1024
    }

    // MARK: device hot-plug tracking

    /// Long-lived `adb track-devices`: yields whenever the device list
    /// changes, finishes when the tracker dies (caller restarts it).
    func deviceEvents() -> AsyncStream<Void> {
        let adbPath = self.adbPath
        return AsyncStream { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["track-devices"]
            process.environment = AdbClient.serverEnvironment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                if handle.availableData.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(())
                }
            }
            process.terminationHandler = { _ in continuation.finish() }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            do {
                try process.run()
            } catch {
                continuation.finish()
            }
        }
    }

    // MARK: pull / push (with su staging fallback)

    /// Pull `remotePath` to `localDir/destName`. If adbd can't read the
    /// path (su-only root), stage a copy in /data/local/tmp first.
    func pull(remotePath: String, fileName: String, destName: String? = nil,
              toLocalDir localDir: URL, serial: String, suAvailable: Bool) async throws {
        let target = localDir.appendingPathComponent(destName ?? fileName).path
        let direct = try await run(["-s", serial, "pull", remotePath, target], timeout: 3600)
        if direct.ok { return }
        try Task.checkCancellation()
        guard suAvailable else {
            throw AdbError(message: "Pull failed: \(direct.combinedError)")
        }

        let stage = "/data/local/tmp/.adbbrowse-\(UUID().uuidString.prefix(8))"
        let q = Self.quote
        do {
            try await runOrThrow("mkdir -p \(q(stage)) && cp -a \(q(remotePath)) \(q(stage + "/")) && chmod -R a+rX \(q(stage))",
                                 serial: serial, su: true, timeout: 3600)
            let staged = try await run(["-s", serial, "pull", stage + "/" + fileName, target], timeout: 3600)
            guard staged.ok else { throw AdbError(message: "Pull failed: \(staged.combinedError)") }
        } catch {
            _ = try? await shell("rm -rf \(q(stage))", serial: serial, su: true)
            throw error
        }
        _ = try? await shell("rm -rf \(q(stage))", serial: serial, su: true)
    }

    /// Push a local file/folder to `remoteDir/destName`. If adbd can't write
    /// there (su-only root), push to /data/local/tmp and `su mv` into place.
    func push(localURL: URL, toRemoteDir remoteDir: String, destName: String? = nil,
              serial: String, suAvailable: Bool) async throws {
        let name = destName ?? localURL.lastPathComponent
        let dest = remoteDir == "/" ? "/" + name : remoteDir + "/" + name

        let direct = try await run(["-s", serial, "push", localURL.path, dest], timeout: 3600)
        if direct.ok { return }
        try Task.checkCancellation()
        guard suAvailable else {
            throw AdbError(message: "Push failed: \(direct.combinedError)")
        }

        let stage = "/data/local/tmp/.adbbrowse-\(UUID().uuidString.prefix(8))"
        let q = Self.quote
        do {
            let staged = try await run(["-s", serial, "push", localURL.path, stage], timeout: 3600)
            guard staged.ok else { throw AdbError(message: "Push failed: \(staged.combinedError)") }
            try await runOrThrow("mv \(q(stage)) \(q(dest))", serial: serial, su: true, timeout: 600)
        } catch {
            _ = try? await shell("rm -rf \(q(stage))", serial: serial, su: true)
            throw error
        }
    }
}

/// Tiny thread-safe boolean for the timeout race.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func set() { lock.lock(); flag = true; lock.unlock() }
}

/// Bridges Task cancellation to Process termination.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func attach(_ p: Process) {
        lock.lock()
        process = p
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { p.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
