import SwiftUI
import Combine
import AppKit

// MARK: - Key Event Monitor
class KeyEventMonitor: ObservableObject {
    @Published var keyCode: UInt16? = nil
    private var monitor: Any?

    init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.keyCode = event.keyCode
            return event
        }
    }

    deinit {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
        }
    }
}

// MARK: - Search Ranking Engine

/// Ranks every item instead of filtering the collection.
///
/// Ranking order:
/// 1. A numeric query matching an item's position in the source list.
/// 2. An exact title match, including an exact match after correcting the
///    English/Russian keyboard layout.
/// 3. A title prefix, followed by prefixes at individual word boundaries.
/// 4. A complete substring.
/// 5. An ordered fuzzy subsequence. Compact and consecutive matches score
///    higher, with bonuses for the beginning of the title and word starts.
/// 6. A small Damerau-Levenshtein distance, which covers insertion, deletion,
///    substitution, and transposition typing errors.
/// 7. Weak character overlap.
/// 8. No match.
///
/// The original query and both keyboard-layout interpretations are evaluated.
/// Layout-corrected variants receive a small penalty so a direct match wins at
/// the same quality level. Items with equal scores retain their source order,
/// and zero-score items remain at the bottom of the results.
struct SearchRanker {
    func rank(_ items: [Item], query: String) -> [Item] {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return Array(items.prefix(50)) }

        let variants = queryVariants(for: normalizedQuery)
        let numericID = Int(normalizedQuery)

        return items.enumerated()
            .map { index, item in
                let searchableFields = item.searchableFields
                var score = variants.flatMap { variant in
                    searchableFields.map { field in
                        score(query: variant.text, title: field) - variant.penalty
                    }
                }.max() ?? 0

                if index + 1 == numericID {
                    score = 1_000_000
                }

                return RankedItem(item: item, score: max(0, score), sourceIndex: index)
            }
            .filter { $0.score > 0 }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.sourceIndex < $1.sourceIndex
            }
            .prefix(50)
            .map(\.item)
    }

    private struct RankedItem {
        let item: Item
        let score: Int
        let sourceIndex: Int
    }

    private struct QueryVariant {
        let text: String
        let penalty: Int
    }

    private func queryVariants(for query: String) -> [QueryVariant] {
        let candidates = [
            QueryVariant(text: query, penalty: 0),
            QueryVariant(text: convertToLatinLayout(query), penalty: 20_000),
            QueryVariant(text: convertToCyrillicLayout(query), penalty: 20_000)
        ]

        var seen = Set<String>()
        return candidates.filter { !$0.text.isEmpty && seen.insert($0.text).inserted }
    }

    private func score(query: String, title: String) -> Int {
        guard !query.isEmpty, !title.isEmpty else { return 0 }

        if query == title {
            return 900_000
        }

        if title.hasPrefix(query) {
            return 800_000 - lengthPenalty(title: title, query: query)
        }

        let words = title.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.contains(where: { $0.hasPrefix(query) }) {
            return 700_000 - lengthPenalty(title: title, query: query)
        }

        if let range = title.range(of: query) {
            let offset = title.distance(from: title.startIndex, to: range.lowerBound)
            return 600_000 - offset * 100 - lengthPenalty(title: title, query: query)
        }

        let queryCharacters = Array(query)
        let titleCharacters = Array(title)
        if let quality = subsequenceQuality(query: queryCharacters, title: titleCharacters) {
            return 500_000 + quality
        }

        let maximumDistance = typoTolerance(for: queryCharacters.count)
        if maximumDistance > 0 {
            let distance = damerauLevenshteinDistance(queryCharacters, titleCharacters)
            if distance <= maximumDistance {
                return 400_000 - distance * 20_000 - lengthPenalty(title: title, query: query)
            }

            let wordDistance = words
                .map { damerauLevenshteinDistance(queryCharacters, Array($0)) }
                .min() ?? Int.max
            if wordDistance <= maximumDistance {
                return 390_000 - wordDistance * 20_000 - lengthPenalty(title: title, query: query)
            }
        }

        return weakOverlapScore(query: queryCharacters, title: titleCharacters)
    }

    private func subsequenceQuality(query: [Character], title: [Character]) -> Int? {
        guard query.count <= title.count else { return nil }

        var bestScore: Int?
        for start in title.indices where title[start] == query[0] {
            var positions = [start]
            var searchIndex = start + 1
            var queryIndex = 1

            while queryIndex < query.count && searchIndex < title.count {
                if title[searchIndex] == query[queryIndex] {
                    positions.append(searchIndex)
                    queryIndex += 1
                }
                searchIndex += 1
            }

            guard positions.count == query.count else { continue }

            guard let lastPosition = positions.last else { continue }
            let span = lastPosition - positions[0] + 1
            let gaps = span - query.count
            let consecutivePairs = zip(positions, positions.dropFirst())
                .filter { $1 == $0 + 1 }
                .count
            let wordStarts = positions.filter { position in
                position == 0 || !title[position - 1].isLetter && !title[position - 1].isNumber
            }.count

            var quality = query.count * 1_000
            quality += consecutivePairs * 600
            quality += wordStarts * 500
            quality -= gaps * 250
            quality -= positions[0] * 80
            if positions[0] == 0 { quality += 1_500 }

            bestScore = max(bestScore ?? quality, quality)
        }

        return bestScore
    }

    private func damerauLevenshteinDistance(
        _ source: [Character],
        _ target: [Character]
    ) -> Int {
        guard !source.isEmpty else { return target.count }
        guard !target.isEmpty else { return source.count }

        var matrix = Array(
            repeating: Array(repeating: 0, count: target.count + 1),
            count: source.count + 1
        )

        for index in 0...source.count { matrix[index][0] = index }
        for index in 0...target.count { matrix[0][index] = index }

        for sourceIndex in 1...source.count {
            for targetIndex in 1...target.count {
                let substitutionCost = source[sourceIndex - 1] == target[targetIndex - 1] ? 0 : 1
                matrix[sourceIndex][targetIndex] = min(
                    matrix[sourceIndex - 1][targetIndex] + 1,
                    matrix[sourceIndex][targetIndex - 1] + 1,
                    matrix[sourceIndex - 1][targetIndex - 1] + substitutionCost
                )

                if sourceIndex > 1,
                   targetIndex > 1,
                   source[sourceIndex - 1] == target[targetIndex - 2],
                   source[sourceIndex - 2] == target[targetIndex - 1] {
                    matrix[sourceIndex][targetIndex] = min(
                        matrix[sourceIndex][targetIndex],
                        matrix[sourceIndex - 2][targetIndex - 2] + 1
                    )
                }
            }
        }

        return matrix[source.count][target.count]
    }

    private func weakOverlapScore(query: [Character], title: [Character]) -> Int {
        var remaining = title
        var matches = 0

        for character in query {
            if let index = remaining.firstIndex(of: character) {
                matches += 1
                remaining.remove(at: index)
            }
        }

        guard matches > 0 else { return 0 }
        return 100_000 + matches * 1_000 - (query.count - matches) * 500
    }

    private func typoTolerance(for queryLength: Int) -> Int {
        switch queryLength {
        case 0...2: return 0
        case 3...7: return 1
        default: return 2
        }
    }

    private func lengthPenalty(title: String, query: String) -> Int {
        max(0, title.count - query.count) * 10
    }

    private func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Main Overlay View
struct OverlayContent: View {
    @State private var searchText = ""
    @State private var items: [Item] = []
    @State private var rankedItems: [Item] = []
    @State private var selectedIndex: Int? = nil
    @State private var hoveredIndex: Int? = nil
    @AppStorage("overlayFontScale") private var fontScale = 2.0
    @AppStorage("overlaySpacingScale") private var spacingScale = 2.0
    @AppStorage("overlayOpacity") private var windowOpacity = 1.0
    @AppStorage("searchApplications") private var searchApplications = true
    @FocusState private var isSearchFocused: Bool
    @State private var fileMonitor: DispatchSourceFileSystemObject?
    @State private var isMonitoringItemsFile = false
    @State private var rankingTask: Task<Void, Never>?
    @ObservedObject private var keyMonitor = KeyEventMonitor()
    private let itemSources = ItemSourceRegistry.standard

    var onSelect: () -> Void

    var filteredItems: [Item] {
        rankedItems
    }

    private var scale: CGFloat {
        CGFloat(fontScale)
    }

    private var spacing: CGFloat {
        CGFloat(spacingScale)
    }

    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                searchContent
                    .glassEffect(.regular, in: .rect(cornerRadius: 24))
            } else {
                searchContent
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            }
        }
        .opacity(windowOpacity)
        .onAppear {
            loadItems()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isSearchFocused = true
            }

            isMonitoringItemsFile = true
            startMonitoringItemsFile()
        }
        .onDisappear {
            rankingTask?.cancel()
            rankingTask = nil
            isMonitoringItemsFile = false
            fileMonitor?.cancel()
            fileMonitor = nil
        }
        .onChange(of: searchText) { _, newQuery in
            scheduleRanking(query: newQuery)
            isSearchFocused = true
        }
        .onChange(of: searchApplications) { _, _ in
            loadItems()
        }
        .onReceive(keyMonitor.$keyCode) { keyCode in
            guard let code = keyCode else { return }
            isSearchFocused = true

            switch code {
            case 125: // down
                moveSelection(delta: 1)

            case 126: // up
                moveSelection(delta: -1)

            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .itemsConfigDidChange)) { _ in
            loadItems()
        }
        .background(
            KeyEventHandlingView(
                onEscapePressed: {
                    searchText = ""
                    NSApp.keyWindow?.close()
                },
                onArrowUp: { isSearchFocused = true },
                onArrowDown: { isSearchFocused = true },
                onKeyTyped: { isSearchFocused = true }
            )
        )
        .onExitCommand {
            searchText = ""
            NSApp.keyWindow?.close()
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let items = filteredItems

        VStack(spacing: 0) {
            HStack(spacing: 8 * spacing) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(.secondary)

                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22 * scale))
                    .focused($isSearchFocused)
                    .onSubmit { selectCurrent() }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13 * scale))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Clear search")
                }
            }
            .padding(12 * spacing)

            Divider()

            if items.isEmpty {
                VStack(spacing: 8 * spacing) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 26 * scale))
                        .foregroundStyle(.secondary)
                    Text("No Results")
                        .font(.system(size: 13 * scale, weight: .semibold))
                    Text("Try another search.")
                        .font(.system(size: 13 * scale))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: spacing) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                ResultRow(
                                    item: item,
                                    isSelected: index == selectedIndex,
                                    isHovered: index == hoveredIndex,
                                    fontScale: scale,
                                    spacingScale: spacing
                                )
                                .id(item.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = index
                                    selectCurrent()
                                }
                                .onHover { hovering in
                                    if hovering {
                                        hoveredIndex = index
                                    } else if hoveredIndex == index {
                                        hoveredIndex = nil
                                    }
                                }
                            }
                        }
                        .padding(6 * spacing)
                    }
                    .onChange(of: selectedIndex) { _, idx in
                        guard let idx = idx, items.indices.contains(idx) else { return }
                        proxy.scrollTo(items[idx].id, anchor: .center)
                    }
                    .onChange(of: filteredItems) { _, newItems in
                        if newItems.isEmpty {
                            selectedIndex = nil
                            return
                        }

                        if let idx = selectedIndex {
                            let clamped = min(idx, newItems.count - 1)
                            if clamped != idx { selectedIndex = clamped }
                            proxy.scrollTo(newItems[clamped].id, anchor: .center)
                        } else {
                            selectedIndex = 0
                            proxy.scrollTo(newItems[0].id, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 16 * spacing) {
                Text("↩ Run")
                Text("↑↓ Navigate")
                Text("esc Close")
                Spacer()

                if let index = selectedIndex, items.indices.contains(index) {
                    Text(items[index].actionLabel)
                }
            }
            .font(.system(size: 13 * scale))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12 * spacing)
            .padding(.vertical, 8 * spacing)
        }
        .frame(width: 680, height: 500, alignment: .top)
    }

    private func selectCurrent() {
        guard !filteredItems.isEmpty else {
            selectedIndex = nil
            return
        }

        if filteredItems.count == 1 { selectedIndex = 0 }
        let index = selectedIndex ?? 0
        guard filteredItems.indices.contains(index) else {
            selectedIndex = nil
            return
        }

        let selectedItem = filteredItems[index]
        selectedItem.perform()
        onSelect()
    }

    private func moveSelection(delta: Int) {
        guard !filteredItems.isEmpty else {
            selectedIndex = nil
            return
        }

        let current = selectedIndex ?? (delta > 0 ? -1 : filteredItems.count)
        let next = max(0, min(filteredItems.count - 1, current + delta))
        if next != selectedIndex { selectedIndex = next }
    }

    private func loadItems() {
        let sources = searchApplications
            ? itemSources
            : ItemSourceRegistry(sources: [FileItemSource()])

        Task {
            let loadedItems = await sources.loadAllItems()
            items = loadedItems
            scheduleRanking(query: searchText, debounce: false)
        }
    }

    private func scheduleRanking(query: String, debounce: Bool = true) {
        rankingTask?.cancel()
        let itemsToRank = items

        rankingTask = Task {
            if debounce {
                do {
                    try await Task.sleep(for: .milliseconds(75))
                } catch {
                    return
                }
            }

            let results = await Task.detached(priority: .userInitiated) {
                SearchRanker().rank(itemsToRank, query: query)
            }.value

            guard !Task.isCancelled, searchText == query else { return }
            rankedItems = results
            selectedIndex = results.isEmpty ? nil : 0
        }
    }

    private func startMonitoringItemsFile() {
        guard isMonitoringItemsFile else { return }

        fileMonitor?.cancel()
        fileMonitor = nil

        let fd = open(itemsConfigURL.path, O_EVTONLY)

        guard fd != -1 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                startMonitoringItemsFile()
            }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )

        source.setEventHandler {
            fileMonitor?.cancel()
            fileMonitor = nil

            // Editors often save by replacing the original file. Wait until that
            // replacement is complete, then reload and monitor the new file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                loadItems()
                startMonitoringItemsFile()
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileMonitor = source
    }
}

// MARK: - Row View
@MainActor
private enum ApplicationIconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        let key = path as NSString
        if let cachedIcon = cache.object(forKey: key) {
            return cachedIcon
        }

        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

struct ResultRow: View {
    let item: Item
    let isSelected: Bool
    let isHovered: Bool
    let fontScale: CGFloat
    let spacingScale: CGFloat

    private var rowBackground: Color {
        if isSelected {
            return Color.accentColor
        }

        if isHovered {
            return Color.accentColor.opacity(0.25)
        }

        return .clear
    }

    private var primaryColor: Color {
        isSelected ? .white : .primary
    }

    private var secondaryColor: Color {
        isSelected ? .white.opacity(0.8) : .secondary
    }

    var body: some View {
        HStack(spacing: 10 * spacingScale) {
            itemIcon
                .frame(width: 34 * spacingScale, height: 34 * spacingScale)

            VStack(alignment: .leading, spacing: 2 * spacingScale) {
                Text(item.title)
                    .foregroundStyle(primaryColor)
                    .font(.system(size: 20 * fontScale))
                Text(item.description)
                    .foregroundStyle(secondaryColor)
                    .font(.system(size: 13 * fontScale))
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: item.actionSymbolName)
                .font(.system(size: 13 * fontScale))
                .foregroundStyle(secondaryColor)
                .help(item.actionLabel)
        }
        .padding(.horizontal, 8 * spacingScale)
        .padding(.vertical, 8 * spacingScale)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 5))
    }

    @ViewBuilder
    private var itemIcon: some View {
        switch item.icon {
        case .text(let value):
            Text(value)
                .font(.system(size: 22 * fontScale))
        case .file(let path):
            if FileManager.default.fileExists(atPath: path) {
                Image(nsImage: ApplicationIconCache.icon(for: path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "app")
                    .resizable()
                    .scaledToFit()
            }
        case .system(let name):
            Image(systemName: name)
                .resizable()
                .scaledToFit()
        }
    }
}

// MARK: - KeyEventHandlingView (fixed)
struct KeyEventHandlingView: NSViewRepresentable {
    let onEscapePressed: () -> Void
    let onArrowUp: () -> Void
    let onArrowDown: () -> Void
    let onKeyTyped: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherView()
        view.onEscapePressed = onEscapePressed
        view.onArrowUp = onArrowUp
        view.onArrowDown = onArrowDown
        view.onKeyTyped = onKeyTyped
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class KeyCatcherView: NSView {
        var onEscapePressed: (() -> Void)?
        var onArrowUp: (() -> Void)?
        var onArrowDown: (() -> Void)?
        var onKeyTyped: (() -> Void)?

        override var acceptsFirstResponder: Bool { false } // <-- FIX

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: onEscapePressed?()
            case 126: onArrowUp?()
            case 125: onArrowDown?()
            default:
                if let chars = event.charactersIgnoringModifiers, chars.count == 1 {
                    onKeyTyped?()
                }
            }
        }
    }
}

// MARK: - Keyboard Layout Convertors
func convertToLatinLayout(_ text: String) -> String {
    let map: [Character: Character] = [
        "ф":"a","и":"b","с":"c","в":"d","у":"e","а":"f","п":"g","р":"h","ш":"i","о":"j","л":"k","д":"l",
        "ь":"m","т":"n","щ":"o","з":"p","й":"q","к":"r","ы":"s","е":"t","г":"u","м":"v","ц":"w","ч":"x","н":"y","я":"z"
    ]
    return String(text.map { map[$0] ?? $0 })
}

func convertToCyrillicLayout(_ text: String) -> String {
    let map: [Character: Character] = [
        "a":"ф","b":"и","c":"с","d":"в","e":"у","f":"а","g":"п","h":"р","i":"ш","j":"о","k":"л","l":"д",
        "m":"ь","n":"т","o":"щ","p":"з","q":"й","r":"к","s":"ы","t":"е","u":"г","v":"м","w":"ц","x":"ч","y":"н","z":"я"
    ]
    return String(text.map { map[$0] ?? $0 })
}
