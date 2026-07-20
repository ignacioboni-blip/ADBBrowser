import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum QRGenerator {
    static func image(from string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let ci = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: ci)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

struct WifiPairWizard: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case prepare, pair, connect, done
    }
    enum PairMode { case code, qr }

    @State private var step: Step = .prepare
    @State private var pairMode: PairMode = .qr
    @State private var pairEndpoint = ""
    @State private var pairCode = ""
    @State private var connectEndpoint = ""
    @State private var connectedTo = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var discoveredHost: String?
    @State private var alreadyPaired: MdnsService?
    @State private var qr: QrPairing?
    @State private var qrImage: NSImage?
    @State private var qrWaiting = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, minHeight: 210, alignment: .topLeading)
                .padding(20)
            Divider()
            footer
        }
        .frame(width: 470)
        .tint(model.accent)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
                .font(.title2)
                .foregroundStyle(model.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connect over Wi-Fi").font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 5) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s.rawValue <= step.rawValue ? model.accent : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var subtitle: String {
        switch step {
        case .prepare: return "Step 1 of 3 — prepare your phone"
        case .pair: return "Step 2 of 3 — pair with a code"
        case .connect: return "Step 3 of 3 — connect"
        case .done: return "Connected"
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .prepare: prepareStep
        case .pair: pairStep
        case .connect: connectStep
        case .done: doneStep
        }
    }

    private var prepareStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make sure your Mac and phone are on the same Wi-Fi network, then on your phone:")
                .fixedSize(horizontal: false, vertical: true)
            instruction(1, "Open Settings ▸ Developer options ▸ Wireless debugging and turn it on.")
            instruction(2, "Tap “Pair device with QR code” (or “…with pairing code”).")
            instruction(3, "On the next screen you'll either scan a code or read off an address and number.")
            if let svc = alreadyPaired {
                Divider()
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(model.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A device is broadcasting wireless debugging at \(svc.endpoint).")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("If it's already paired with this Mac, you can skip pairing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Connect") {
                        connectEndpoint = svc.endpoint
                        advanceTo(.connect)
                        doConnect()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await scanForAlreadyPaired() }
    }

    /// Pairing survives on Android — if the phone is already broadcasting a
    /// connect service, the user shouldn't be forced through pairing again.
    private func scanForAlreadyPaired() async {
        await model.ensureWirelessReady()
        let services = await model.mdnsScan()
        guard step == .prepare else { return }
        alreadyPaired = services.first(where: { $0.isConnect })
    }

    private var pairStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $pairMode) {
                Text("QR code").tag(PairMode.qr)
                Text("Pairing code").tag(PairMode.code)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if pairMode == .qr {
                qrPairContent
            } else {
                codePairContent
            }
            errorBanner
        }
        .task(id: pairMode) { await runQrFlow() }
    }

    private var codePairContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enter the IP address, port, and code shown in the “Pair with code” dialog on your phone.")
                .fixedSize(horizontal: false, vertical: true)
            field("IP address & port", text: $pairEndpoint, placeholder: "192.168.1.50:37123", mono: true)
            field("Pairing code", text: $pairCode, placeholder: "123456", mono: true)
            if let discoveredHost {
                Label("Found a device pairing at \(discoveredHost)", systemImage: "sparkles")
                    .font(.caption)
                    .foregroundStyle(model.accent)
            }
        }
    }

    private var qrPairContent: some View {
        VStack(spacing: 10) {
            Text("On your phone, tap “Pair device with QR code” and point the camera at this code.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            if let qrImage {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 170, height: 170)
                    .padding(8)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ProgressView().frame(height: 186)
            }
            Label(qrWaiting ? "Waiting for your phone to scan…" : "Preparing…",
                  systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pairing succeeded. Now enter the IP address & port from the main Wireless debugging screen (the port is usually different from the pairing port).")
                .fixedSize(horizontal: false, vertical: true)
            field("IP address & port", text: $connectEndpoint, placeholder: "192.168.1.50:41234", mono: true)
            if busy && connectEndpoint.isEmpty {
                Label("Looking for your device on the network…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.caption).foregroundStyle(.secondary)
            }
            errorBanner
        }
    }

    private var doneStep: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(model.accent)
            Text("Connected wirelessly").font(.headline)
            Text("\(connectedTo) is now available. You can unplug the USB cable.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step == .pair || step == .connect {
                Button("Back") { back() }.disabled(busy)
            }
            Spacer()
            Button("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            primaryButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case .prepare:
            Button("Continue") { advanceTo(.pair) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        case .pair:
            if pairMode == .code {
                Button(busy ? "Pairing…" : "Pair") { doPair() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !isValid(pairEndpoint) || pairCode.count < 4)
                    .overlay { if busy { ProgressView().controlSize(.small) } }
            }
        case .connect:
            Button(busy ? "Connecting…" : "Connect") { doConnect() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(busy || !isValid(connectEndpoint))
                .overlay { if busy { ProgressView().controlSize(.small) } }
        case .done:
            Button("Done") { close() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Actions

    private func advanceTo(_ s: Step) {
        errorText = nil
        withAnimation(.easeInOut(duration: 0.2)) { step = s }
        if s == .pair { scanForPairing() }
    }

    private func back() {
        errorText = nil
        withAnimation(.easeInOut(duration: 0.2)) {
            step = step == .connect ? .pair : .prepare
        }
    }

    /// Generate a QR (once) and watch mDNS until the phone scans it, then pair.
    private func runQrFlow() async {
        guard step == .pair, pairMode == .qr else { return }
        errorText = nil
        if qr == nil {
            let newQr = model.makeQrPairing()
            qr = newQr
            qrImage = QRGenerator.image(from: newQr.payload)
        }
        guard let qr else { return }
        qrWaiting = true
        defer { qrWaiting = false }
        do {
            try await model.qrPairAndWait(qr)
            advanceTo(.connect)
            await prefillConnect()
        } catch is CancellationError {
            // mode switched or wizard closed — leave quietly
        } catch {
            errorText = (error as? AdbError)?.message ?? error.localizedDescription
        }
    }

    private func doPair() {
        busy = true
        errorText = nil
        Task {
            do {
                try await model.wifiPair(endpoint: pairEndpoint.trimmingCharacters(in: .whitespaces),
                                         code: pairCode.trimmingCharacters(in: .whitespaces))
                busy = false
                advanceTo(.connect)
                await prefillConnect()
            } catch {
                busy = false
                errorText = (error as? AdbError)?.message ?? error.localizedDescription
            }
        }
    }

    private func doConnect() {
        busy = true
        errorText = nil
        Task {
            do {
                let serial = try await model.wifiConnect(endpoint: connectEndpoint.trimmingCharacters(in: .whitespaces))
                connectedTo = serial
                busy = false
                withAnimation(.easeInOut(duration: 0.2)) { step = .done }
            } catch {
                busy = false
                errorText = (error as? AdbError)?.message ?? error.localizedDescription
            }
        }
    }

    /// Best-effort mDNS scan to surface a pairing endpoint as a hint.
    private func scanForPairing() {
        Task {
            let services = await model.mdnsScan()
            if let pairing = services.first(where: { $0.isPairing }) {
                discoveredHost = pairing.endpoint
                if pairEndpoint.isEmpty { pairEndpoint = pairing.endpoint }
            } else if let connect = services.first(where: { $0.isConnect }) {
                discoveredHost = connect.host
            }
        }
    }

    /// After pairing, auto-fill the connect endpoint from mDNS if we can.
    private func prefillConnect() async {
        busy = true
        let services = await model.mdnsScan()
        busy = false
        if let connect = services.first(where: { $0.isConnect }) {
            connectEndpoint = connect.endpoint
        } else if connectEndpoint.isEmpty, isValid(pairEndpoint) {
            connectEndpoint = (pairEndpoint.split(separator: ":").first.map(String.init) ?? "") + ":"
        }
    }

    private func close() {
        model.isWifiWizardVisible = false
        dismiss()
    }

    // MARK: - Pieces

    private func instruction(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(model.accent.contrastingText)
                .frame(width: 20, height: 20)
                .background(Circle().fill(model.accent))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, mono: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(mono ? .system(.body, design: .monospaced) : .body)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorText {
            Label(errorText, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func isValid(_ endpoint: String) -> Bool {
        let parts = endpoint.split(separator: ":")
        return parts.count == 2 && !parts[0].isEmpty && Int(parts[1]) != nil
    }
}
