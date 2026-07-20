import Foundation

/// A long-lived `adb shell` (optionally `exec su`) that runs many commands
/// without re-spawning a process and re-doing the USB handshake each time.
/// Commands are terminated with a unique marker line carrying the exit code.
actor DeviceShell {
    private let adbPath: String
    private let serial: String
    private let su: Bool

    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var streamEnded = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private let queue = ConcurrencyLimiter(slots: 1)

    init(adbPath: String, serial: String, su: Bool) {
        self.adbPath = adbPath
        self.serial = serial
        self.su = su
    }

    func run(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        // Cancellation-aware: a burst of navigations doesn't leave a backlog
        // of obsolete commands each holding the shell in turn.
        guard await queue.acquire() else { throw CancellationError() }
        do {
            try Task.checkCancellation()
            let result = try await execute(command, timeout: timeout)
            await queue.release()
            return result
        } catch {
            await queue.release()
            throw error
        }
    }

    private func execute(_ command: String, timeout: TimeInterval) async throws -> ShellResult {
        if process?.isRunning != true {
            try start()
        }
        guard let stdin else { throw AdbError(message: "shell not running") }

        let marker = "__ADBB_\(UInt64.random(in: 0..<UInt64.max))_"
        // Trailing plain `echo` guarantees the marker starts on its own line
        // even if the command's output lacks a final newline.
        let script = "\(command)\n__r=$?\necho\necho \(marker)${__r}\n"
        do {
            try stdin.write(contentsOf: Data(script.utf8))
        } catch {
            reset()
            throw AdbError(message: "device shell went away")
        }

        let deadline = Date().addingTimeInterval(timeout)
        let markerData = Data(marker.utf8)
        while true {
            if let result = parse(marker: markerData) {
                return result
            }
            if streamEnded {
                reset()
                throw AdbError(message: "device shell exited")
            }
            if Date() >= deadline {
                reset()
                throw AdbError(message: "shell command timed out: \(command.prefix(80))")
            }
            await waitForData(until: deadline)
        }
    }

    /// Look for "<marker><exitcode>\n" in the buffer; on success consume it
    /// and return everything before it (minus the newline our `echo` added).
    /// `scanFrom` remembers how far we've already looked so multi-megabyte
    /// outputs (du -a) aren't rescanned from the start on every chunk.
    private var scanFrom = 0

    private func parse(marker: Data) -> ShellResult? {
        let searchStart = min(max(buffer.startIndex, scanFrom), buffer.endIndex)
        guard let markerRange = buffer.range(of: marker, in: searchStart..<buffer.endIndex) else {
            // Back off marker-length bytes so a marker split across chunks is
            // still found by the next scan.
            scanFrom = max(buffer.startIndex, buffer.endIndex - marker.count + 1)
            return nil
        }
        scanFrom = markerRange.lowerBound   // hold position until the exit-code newline arrives
        let afterMarker = buffer[markerRange.upperBound...]
        guard let newline = afterMarker.firstIndex(of: UInt8(ascii: "\n")) else { return nil }

        let code = Int32(String(data: afterMarker[..<newline], encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1

        var output = buffer[..<markerRange.lowerBound]
        if output.last == UInt8(ascii: "\n") { output = output.dropLast() }   // our echo
        buffer = Data(buffer[buffer.index(after: newline)...])
        scanFrom = 0

        // stderr is merged into stdout at the fd level, preserving order.
        return ShellResult(
            stdout: String(data: output, encoding: .utf8) ?? "",
            stderr: "",
            exitCode: code
        )
    }

    private func start() throws {
        reset()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: adbPath)
        p.arguments = ["-s", serial, "shell"]
        p.environment = AdbClient.serverEnvironment

        let inPipe = Pipe()
        let outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = outPipe   // merge, kernel preserves write order

        let stream = AsyncStream<Data>(bufferingPolicy: .unbounded) { continuation in
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
            p.terminationHandler = { _ in continuation.finish() }
        }

        try p.run()
        process = p
        stdin = inPipe.fileHandleForWriting
        buffer = Data()
        streamEnded = false

        pumpTask = Task { [weak self] in
            for await chunk in stream {
                await self?.ingest(chunk)
            }
            await self?.markEnded()
        }

        if su {
            try stdin?.write(contentsOf: Data("exec su\n".utf8))
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        waiter?.resume()
        waiter = nil
    }

    private func markEnded() {
        streamEnded = true
        waiter?.resume()
        waiter = nil
    }

    private func waitForData(until deadline: Date) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiter = c
            let remaining = deadline.timeIntervalSinceNow
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0.05, remaining)))
                await self?.kickWaiter()
            }
        }
    }

    private func kickWaiter() {
        waiter?.resume()
        waiter = nil
    }

    private func reset() {
        pumpTask?.cancel()
        pumpTask = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil
        try? stdin?.close()
        stdin = nil
        buffer = Data()
        scanFrom = 0
        streamEnded = false
    }
}

/// Which persistent shell a command runs on. Interactive commands (ls, stat,
/// quick file ops) get their own shell so they never queue behind long-running
/// bulk work (du for the sunburst, find, recursive copies) — previously a
/// storage measurement could block folder navigation for minutes.
enum ShellLane: String, Sendable {
    case interactive, bulk
}

/// One persistent shell per (device, su, lane) triple.
actor ShellPool {
    private var shells: [String: DeviceShell] = [:]

    func shell(adbPath: String, serial: String, su: Bool, lane: ShellLane) -> DeviceShell {
        let key = "\(serial)|\(su ? "su" : "sh")|\(lane.rawValue)"
        if let existing = shells[key] { return existing }
        let fresh = DeviceShell(adbPath: adbPath, serial: serial, su: su)
        shells[key] = fresh
        return fresh
    }
}
