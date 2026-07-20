import SwiftUI

struct PaletteItem: Identifiable {
    let id: String
    let icon: String
    let title: String
    var subtitle: String?
    var hint: String?
    let action: () -> Void
}

struct CommandPaletteView: View {
    @ObservedObject var model: BrowserViewModel
    var onNewFolder: () -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var searchResults: [String]?
    @State private var isSearching = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let items = buildItems()
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .foregroundStyle(model.accent)
                TextField("Go to folder, find files, run a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit { activate(items, at: selectedIndex) }
                    .onKeyPress(.downArrow) {
                        selectedIndex = min(selectedIndex + 1, max(0, items.count - 1))
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        selectedIndex = max(selectedIndex - 1, 0)
                        return .handled
                    }
                    .onExitCommand { close() }
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                            row(item, isSelected: i == selectedIndex)
                                .id(i)
                                .onTapGesture { activate(items, at: i) }
                        }
                        if items.isEmpty {
                            Text("No matches")
                                .foregroundStyle(.tertiary)
                                .padding(.vertical, 16)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
                .onChange(of: selectedIndex) { _, new in
                    proxy.scrollTo(new, anchor: nil)
                }
            }
        }
        .frame(width: 580)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.cornerXL, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.cornerXL, style: .continuous)
            .strokeBorder(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 32, y: 12)
        .onAppear { fieldFocused = true }
        .onChange(of: query) {
            selectedIndex = 0
            searchResults = nil
        }
    }

    private func row(_ item: PaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isSelected ? model.accent : .secondary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? model.accent.opacity(DS.tonal) : Color.secondary.opacity(0.08))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let hint = item.hint {
                KeycapHint(text: hint)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DS.corner, style: .continuous)
                .fill(isSelected ? model.accent.opacity(DS.tonal) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    // MARK: - Item construction

    private func buildItems() -> [PaletteItem] {
        if let results = searchResults {
            return results.map { path in
                PaletteItem(
                    id: "find:\(path)", icon: "doc.text.magnifyingglass",
                    title: (path as NSString).lastPathComponent, subtitle: path, hint: "jump"
                ) {
                    model.revealSearchResult(path)
                    close()
                }
            }
        }

        var fixed: [PaletteItem] = []
        if query.hasPrefix("/") {
            fixed.append(PaletteItem(id: "goto", icon: "arrow.right.circle", title: "Go to \(query)", hint: "↩") {
                model.navigate(to: query)
                close()
            })
        }

        let actions: [PaletteItem] = [
            PaletteItem(id: "act:newfolder", icon: "folder.badge.plus", title: "New Folder…") {
                close(); onNewFolder()
            },
            PaletteItem(id: "act:upload", icon: "square.and.arrow.up", title: "Upload Files Here…") {
                close(); model.uploadViaPanel()
            },
            PaletteItem(id: "act:download", icon: "square.and.arrow.down", title: "Download Selection to Mac…") {
                close(); model.download(model.selectedFiles)
            },
            PaletteItem(id: "act:hidden", icon: "eye", title: "Toggle Hidden Files") {
                model.showHidden.toggle(); close()
            },
            PaletteItem(id: "act:reload", icon: "arrow.clockwise", title: "Reload") {
                model.reload(); close()
            },
            PaletteItem(id: "act:bookmark", icon: "star", title: "Bookmark This Folder") {
                model.addBookmarkForCurrentPath(); close()
            },
            PaletteItem(id: "act:diagnostics", icon: "stethoscope", title: "Connection Diagnostics…") {
                model.showDiagnostics(); close()
            },
            PaletteItem(id: "act:logcat", icon: "doc.text.magnifyingglass", title: "Logcat…") {
                model.isLogcatVisible = true
                if !model.isLogcatRunning { model.startLogcat() }
                close()
            },
            PaletteItem(id: "act:apkmanager", icon: "shippingbox", title: "APK Manager…") {
                model.isApkManagerVisible = true
                if model.packages.isEmpty { model.loadPackages() }
                close()
            },
        ]

        let places = BrowserViewModel.places.map { place in
            PaletteItem(id: "place:\(place.path)", icon: place.icon, title: place.name, subtitle: place.path) {
                model.navigate(to: place.path)
                close()
            }
        }

        let recents = model.recentPaths
            .filter { path in
                path != model.currentPath && !BrowserViewModel.places.contains(where: { $0.path == path })
            }
            .prefix(6)
            .map { path in
                PaletteItem(id: "recent:\(path)", icon: "clock", title: (path as NSString).lastPathComponent,
                            subtitle: path) {
                    model.navigate(to: path)
                    close()
                }
            }

        let entries = model.visibleEntries.map { file in
            PaletteItem(id: "entry:\(file.id)", icon: file.icon, title: file.name,
                        hint: file.isNavigable ? "open" : "select") {
                if file.isNavigable {
                    model.activate(file)
                } else {
                    model.selection = [file.id]
                }
                close()
            }
        }

        if query.isEmpty {
            return fixed + Array(recents) + places + actions
        }

        var candidates: [PaletteItem] = actions
        candidates.append(contentsOf: places)
        candidates.append(contentsOf: recents)
        candidates.append(contentsOf: entries)

        var scored: [(score: Int, item: PaletteItem)] = []
        for item in candidates {
            let score = Self.fuzzyScore(query, item.title)
            if score > 0 { scored.append((score, item)) }
        }
        scored.sort { $0.score > $1.score }

        var out: [PaletteItem] = fixed
        out.append(contentsOf: scored.prefix(11).map(\.item))
        if query.count >= 2 {
            out.append(PaletteItem(
                id: "act:search", icon: "magnifyingglass",
                title: "Search device for “\(query)”",
                subtitle: "find, under \(model.currentPath)", hint: "↩"
            ) { runDeviceSearch() })
        }
        return out
    }

    private func activate(_ items: [PaletteItem], at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].action()
    }

    private func runDeviceSearch() {
        guard !isSearching else { return }
        isSearching = true
        let q = query
        Task {
            let results = await model.searchDevice(q)
            guard q == query else { return }
            searchResults = results
            isSearching = false
            selectedIndex = 0
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.15)) {
            model.isPaletteVisible = false
        }
    }

    /// Subsequence match with streak and prefix bonuses.
    static func fuzzyScore(_ needle: String, _ haystack: String) -> Int {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        guard !n.isEmpty else { return 1 }
        var score = 0, ni = 0, streak = 0
        for ch in h {
            if ni < n.count && ch == n[ni] {
                ni += 1
                streak += 1
                score += 1 + streak
            } else {
                streak = 0
            }
        }
        guard ni == n.count else { return 0 }
        if h.starts(with: n) { score += 20 }
        return score
    }
}
