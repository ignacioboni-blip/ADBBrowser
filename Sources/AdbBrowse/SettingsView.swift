import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: BrowserViewModel
    @AppStorage("adbPath") private var adbPath = ""
    @AppStorage("defaultPath") private var defaultPath = "/sdcard"

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("adb binary", text: $adbPath, prompt: Text("Auto-detect"))
                        .font(.system(.body, design: .monospaced))
                    Button("Choose…") { chooseAdb() }
                }
                LabeledContent("Detected") {
                    Text(AdbClient.resolveAdbPath() ?? "not found")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Reconnect") { model.start() }
            } header: {
                Text("adb")
            } footer: {
                Text("Leave blank to auto-detect from $ANDROID_HOME, ~/Library/Android/sdk, or Homebrew.")
            }

            Section("Browsing") {
                TextField("Start folder", text: $defaultPath)
                    .font(.system(.body, design: .monospaced))
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.bottom, 8)
    }

    private func chooseAdb() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.prompt = "Use as adb"
        if panel.runModal() == .OK, let url = panel.url {
            adbPath = url.path
            model.start()
        }
    }
}
