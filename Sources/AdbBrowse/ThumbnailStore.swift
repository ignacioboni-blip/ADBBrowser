import AppKit
import CryptoKit
import UniformTypeIdentifiers

/// Generates and caches thumbnails for image files on the device.
/// Originals are pulled to a temp dir (at most 3 at a time so browsing stays
/// snappy), downsampled to 256 px, kept in an NSCache and persisted to
/// ~/Library/Caches keyed by (path, size, mtime).
@MainActor
final class ThumbnailStore {
    private nonisolated static let thumbableExtensions: Set<String> =
        ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"]
    private nonisolated static let maxSourceBytes: Int64 = 25_000_000
    private nonisolated static let maxPixelSize = 256

    private let memory = NSCache<NSString, NSImage>()
    private var inflight: [String: Task<NSImage?, Never>] = [:]
    // 2 concurrent pulls: thumbnails shouldn't crowd the USB link while
    // the user is navigating.
    private let limiter = ConcurrencyLimiter(slots: 2)
    private let diskDir: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        diskDir = caches.appendingPathComponent("AdbBrowse/thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    static func canThumbnail(_ file: RemoteFile) -> Bool {
        guard file.type == .file, let size = file.size, size <= maxSourceBytes else { return false }
        return thumbableExtensions.contains((file.name as NSString).pathExtension.lowercased())
    }

    func thumbnail(for file: RemoteFile, client: AdbClient, serial: String, suAvailable: Bool) async -> NSImage? {
        guard Self.canThumbnail(file) else { return nil }
        let key = Self.cacheKey(file)
        if let cached = memory.object(forKey: key as NSString) { return cached }
        if let running = inflight[key] { return await running.value }

        let diskURL = diskDir.appendingPathComponent(key + ".png")
        let limiter = self.limiter
        let task = Task<NSImage?, Never> {
            // Decode the disk cache off the main actor — NSImage(contentsOf:)
            // does file I/O + PNG decode, which janks scrolling if run here.
            if let onDisk = await Task.detached(priority: .utility, operation: {
                NSImage(contentsOf: diskURL)
            }).value {
                return onDisk
            }

            guard await limiter.acquire() else { return nil }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("AdbBrowse/thumb-src", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: tmp) }

            do {
                try await client.pull(remotePath: file.path, fileName: file.name,
                                      toLocalDir: tmp, serial: serial, suAvailable: suAvailable)
            } catch {
                await limiter.release()
                return nil
            }
            await limiter.release()

            let source = tmp.appendingPathComponent(file.name)
            return await Task.detached(priority: .utility) {
                Self.downsample(source: source, cacheTo: diskURL)
            }.value
        }

        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image { memory.setObject(image, forKey: key as NSString) }
        return image
    }

    private static func cacheKey(_ file: RemoteFile) -> String {
        let raw = "\(file.path)|\(file.size ?? 0)|\(file.modified)"
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func downsample(source: URL, cacheTo: URL) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }

        if let dest = CGImageDestinationCreateWithURL(cacheTo as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            CGImageDestinationFinalize(dest)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// Counting semaphore for async tasks. Waiting is cancellation-aware:
/// `acquire()` returns `false` — without consuming a slot — if the task is
/// cancelled first, so a queue of stale work (e.g. listings for folders the
/// user already navigated away from) drains instantly instead of executing.
actor ConcurrencyLimiter {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []
    private var cancelledIDs: Set<UUID> = []

    init(slots: Int) {
        available = slots
    }

    /// True when a slot was acquired (caller must `release()`);
    /// false when the task was cancelled while waiting.
    func acquire() async -> Bool {
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await wait(id: id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        cancelledIDs.remove(id)   // tidy the raced cancel-after-acquire case
        return acquired
    }

    private func wait(id: UUID) async -> Bool {
        if cancelledIDs.remove(id) != nil || Task.isCancelled { return false }
        if available > 0 {
            available -= 1
            return true
        }
        return await withCheckedContinuation { waiters.append((id, $0)) }
    }

    private func cancelWaiter(_ id: UUID) {
        if let idx = waiters.firstIndex(where: { $0.id == id }) {
            waiters.remove(at: idx).continuation.resume(returning: false)
        } else {
            cancelledIDs.insert(id)
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().continuation.resume(returning: true)
        } else {
            available += 1
        }
    }
}
