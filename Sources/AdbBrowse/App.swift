import SwiftUI

@main
struct AdbBrowseApp: App {
    @StateObject private var model = BrowserViewModel()

    init() {
        // When launched from a bare executable (swift run), make sure we behave
        // like a regular foreground app with a Dock icon and key window.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    var body: some Scene {
        WindowGroup("ADB Browser") {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Command Palette…") {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                        model.isPaletteVisible.toggle()
                    }
                }
                .keyboardShortcut("k")
                Button("Quick Look") {
                    model.quickLook(model.selectedFiles)
                }
                .keyboardShortcut("y")
                Button("Filter Folder") {
                    model.filterFocusRequest &+= 1
                }
                .keyboardShortcut("f")
                Button("Get Info") {
                    model.infoFile = model.selectedFiles.first
                }
                .keyboardShortcut("i")
                Divider()
                Button("View as List") { model.viewMode = .list }
                    .keyboardShortcut("1")
                Button("View as Gallery") { model.viewMode = .grid }
                    .keyboardShortcut("2")
                Button("View as Storage Map") { model.viewMode = .sunburst }
                    .keyboardShortcut("3")
                Divider()
                Button("Connect over Wi-Fi…") {
                    model.isWifiWizardVisible = true
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                Button("Go to Folder…") {
                    model.pathFieldText = model.currentPath
                    model.isEditingPath = true
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Reload") { model.reload() }
                    .keyboardShortcut("r")
                Button("Go Up") { model.goUp() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[")
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]")
            }
            CommandGroup(after: .pasteboard) {
                Button("Copy Selection (Device)") { model.copyToClipboard(model.selectedFiles, cut: false) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                Button("Cut Selection (Device)") { model.copyToClipboard(model.selectedFiles, cut: true) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Button("Paste (Device)") { model.paste() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                Divider()
                Button("Show Hidden Files") { model.showHidden.toggle() }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}
