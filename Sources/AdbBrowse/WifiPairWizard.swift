import SwiftUI

struct WifiPairWizard: View {
    @ObservedObject var model: BrowserViewModel
    @Environment(\.dismiss) private var dismiss

    enum Step: Int, CaseIterable {
        case prepare, pair, connect, done
    }

    @State private var step: Step = .prepare
    @State private var pairEndpoint = ""
    @State private var pairCode = ""
    @State private var connectEndpoint = ""
    @State private var connectedTo = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var discoveredHost: String?

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
            instruction(2, "Tap “Pair device with pairing code.”")
            instruction(3, "Keep that screen open — it shows an IP address, port, and a 6-digit code.")
        }
    }

    private var pairStep: some View {
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
            errorBanner
        }
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
            Button(busy ? "Pairing…" : "Pair") { doPair() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(busy || !isValid(pairEndpoint) || pairCode.count < 4)
                .overlay { if busy { ProgressView().controlSize(.small) } }
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
