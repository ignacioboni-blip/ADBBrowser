import CoreTransferable
import Foundation
import UniformTypeIdentifiers

// MARK: - Devices

struct DeviceInfo: Identifiable, Hashable {
    let serial: String
    let state: String      // "device", "unauthorized", "offline", ...
    let model: String      // e.g. "Pixel_10"
    var deviceCodename: String = ""   // e.g. "frankel"
    var product: String = ""

    var id: String { serial }

    /// True for an `ip:port` or mDNS (`._adb-tls-…`) serial — i.e. not USB.
    var isWireless: Bool { serial.contains(":") || serial.contains("._") }

    var prettyModel: String { model.replacingOccurrences(of: "_", with: " ") }

    var displayName: String {
        let m = prettyModel
        let suffix = isWireless ? "Wi-Fi" : (serial.count > 16 ? String(serial.prefix(12)) + "…" : serial)
        if state == "device" {
            return m.isEmpty ? serial : "\(m) (\(suffix))"
        }
        return "\(m.isEmpty ? serial : m) — \(state)"
    }

    var isUsable: Bool { state == "device" }

    /// Identity shared by all transports of one physical phone. Empty when we
    /// have no model info (e.g. unauthorized) so those are never merged.
    var signature: String {
        model.isEmpty && deviceCodename.isEmpty ? "" : "\(model)|\(deviceCodename)|\(product)"
    }

    /// Prefer a usable device, then USB > ip:port > mDNS name, when
    /// collapsing duplicates into one chosen transport.
    var transportRank: Int {
        let serialRank: Int
        if serial.contains("._") { serialRank = 1 }       // adb-…._adb-tls-connect._tcp
        else if serial.contains(":") { serialRank = 2 }   // 192.168.1.180:41571
        else { serialRank = 3 }                            // USB serial
        return (isUsable ? 10 : 0) + serialRank
    }

    /// Collapse the multiple `adb devices` entries that refer to one phone
    /// (USB + Wi-Fi + mDNS auto-connect) into a single chosen transport.
    static func deduplicated(_ devices: [DeviceInfo]) -> [DeviceInfo] {
        var bySignature: [String: DeviceInfo] = [:]
        var result: [DeviceInfo] = []
        for device in devices {
            guard !device.signature.isEmpty else { result.append(device); continue }
            if let existing = bySignature[device.signature] {
                // Keep a usable transport, then the higher-priority serial.
                if device.transportRank > existing.transportRank {
                    if let idx = result.firstIndex(of: existing) { result[idx] = device }
                    bySignature[device.signature] = device
                }
            } else {
                bySignature[device.signature] = device
                result.append(device)
            }
        }
        return result
    }
}

// MARK: - Root mode

enum RootMode: String {
    case adbdRoot = "adbd root"   // adbd itself runs as root (adb root / userdebug)
    case su = "su"                // wrap commands in `su -c` (Magisk / KernelSU)
    case none = "no root"         // plain shell user
    case unknown = "…"

    var badge: String {
        switch self {
        case .adbdRoot: return "Root (adbd)"
        case .su: return "Root (su)"
        case .none: return "No root"
        case .unknown: return "Detecting…"
        }
    }
}

// MARK: - Remote files

enum RemoteFileType: String {
    case directory, file, symlink, blockDevice, charDevice, socket, fifo, unknown

    init(permissionChar c: Character) {
        switch c {
        case "d": self = .directory
        case "-": self = .file
        case "l": self = .symlink
        case "b": self = .blockDevice
        case "c": self = .charDevice
        case "s": self = .socket
        case "p": self = .fifo
        default: self = .unknown
        }
    }
}

struct RemoteFile: Identifiable, Hashable {
    let name: String
    let directory: String          // the directory it lives in (device path)
    let type: RemoteFileType
    let permissions: String
    let owner: String
    let group: String
    let size: Int64?               // nil for devices/unparseable
    let modified: String           // "2026-06-09 19:44" (sortable as text)
    let linkTarget: String?

    var id: String { path }

    var path: String {
        directory == "/" ? "/" + name : directory + "/" + name
    }

    var isDirectory: Bool { type == .directory }
    /// Symlinks might point at directories; we resolve on navigation.
    var isNavigable: Bool { type == .directory || type == .symlink }

    var sizeText: String {
        guard let size else { return "—" }
        if type == .directory { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var sortableSize: Int64 { size ?? -1 }

    var icon: String {
        switch type {
        case .directory: return "folder.fill"
        case .symlink: return "arrow.triangle.turn.up.right.diamond"
        case .blockDevice, .charDevice: return "memorychip"
        case .socket, .fifo: return "point.3.connected.trianglepath.dotted"
        case .unknown: return "questionmark.square.dashed"
        case .file:
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp": return "photo"
            case "mp4", "mkv", "mov", "avi", "webm": return "film"
            case "mp3", "ogg", "flac", "wav", "m4a", "opus": return "music.note"
            case "apk", "apex": return "shippingbox.fill"
            case "zip", "tar", "gz", "7z", "rar", "xz", "zst": return "doc.zipper"
            case "txt", "log", "md", "json", "xml", "prop", "conf", "rc", "sh": return "doc.text"
            case "pdf": return "doc.richtext"
            case "db", "sqlite": return "cylinder.split.1x2"
            default: return "doc"
            }
        }
    }
}

// MARK: - ls -lA parser (toybox / Android)

enum LsParser {
    // perms nlink owner group (size | maj, min) date time name[ -> target]
    private static let pattern =
        #"^([dlcbsp\-?][rwxsStT\-?]{9}[\.\+]?)\s+(\S+)\s+(\S+)\s+(\S+)\s+(?:(\d+)|\d+,\s*\d+|\?)\s+(\d{4}-\d{2}-\d{2}|\?)\s+(\d{2}:\d{2}(?::\d{2})?|\?)\s(.+)$"#
    private static let regex = try! NSRegularExpression(pattern: pattern)

    static func parse(output: String, directory: String) -> [RemoteFile] {
        var files: [RemoteFile] = []
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .init(charactersIn: "\r"))
            if line.hasPrefix("total ") || line.isEmpty { continue }

            let range = NSRange(line.startIndex..., in: line)
            guard let m = regex.firstMatch(in: line, range: range) else {
                if let f = lenientParse(line: line, directory: directory) { files.append(f) }
                continue
            }

            func group(_ i: Int) -> String? {
                guard let r = Range(m.range(at: i), in: line) else { return nil }
                return String(line[r])
            }

            let perms = group(1) ?? "?"
            let owner = group(3) ?? "?"
            let grp = group(4) ?? "?"
            let size = group(5).flatMap { Int64($0) }
            let date = group(6) ?? "?"
            let time = group(7) ?? "?"
            var name = group(8) ?? "?"

            let type = RemoteFileType(permissionChar: perms.first ?? "?")
            var linkTarget: String? = nil
            if type == .symlink, let arrow = name.range(of: " -> ") {
                linkTarget = String(name[arrow.upperBound...])
                name = String(name[..<arrow.lowerBound])
            }
            if name == "." || name == ".." { continue }

            files.append(RemoteFile(
                name: name, directory: directory, type: type,
                permissions: perms, owner: owner, group: grp,
                size: size, modified: date == "?" ? "—" : "\(date) \(time)",
                linkTarget: linkTarget
            ))
        }
        return files
    }

    /// Entries stat couldn't read (e.g. "d????????? ? ? ? ? ? efs") still get listed.
    private static func lenientParse(line: String, directory: String) -> RemoteFile? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 2, let permChar = tokens.first?.first,
              "dlcbsp-?".contains(permChar) else { return nil }
        let name = String(tokens.last!)
        if name == "." || name == ".." { return nil }
        return RemoteFile(
            name: name, directory: directory,
            type: RemoteFileType(permissionChar: permChar),
            permissions: String(tokens[0]), owner: "?", group: "?",
            size: nil, modified: "—", linkTarget: nil
        )
    }
}

// MARK: - Wireless (mDNS) discovery

struct MdnsService: Identifiable, Hashable {
    let name: String
    let type: String        // _adb-tls-connect._tcp / _adb-tls-pairing._tcp
    let endpoint: String     // host:port

    var id: String { name + type + endpoint }
    var isConnect: Bool { type.contains("connect") }
    var isPairing: Bool { type.contains("pairing") }
    var host: String { endpoint.split(separator: ":").first.map(String.init) ?? endpoint }
}

struct QrPairing {
    let serviceName: String
    let password: String
    /// Android's "Pair with QR code" payload format.
    var payload: String { "WIFI:T:ADB;S:\(serviceName);P:\(password);;" }
}

// MARK: - Errors

struct AdbError: LocalizedError, Identifiable {
    let id = UUID()
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Drag out to Finder

/// FileRepresentation needs a static export closure; the view model installs
/// one that pulls the file over adb when a drag is dropped in Finder.
enum DragExport {
    nonisolated(unsafe) static var handler: (@Sendable (RemoteFile) async throws -> URL)?
}

extension RemoteFile: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .item) { file in
            guard let handler = DragExport.handler else {
                throw AdbError(message: "No device connected")
            }
            return SentTransferredFile(try await handler(file), allowAccessingOriginalFile: true)
        }
    }
}
