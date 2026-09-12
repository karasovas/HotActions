import AppKit
import Foundation

enum ItemIcon: Equatable, Sendable {
    case text(String)
    case file(String)
    case system(String)
}

enum ItemAction: Equatable, Sendable {
    case copy(String)
    case shell(String)
    case openApplication(String)
}

struct Item: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let description: String
    let icon: ItemIcon
    let action: ItemAction
    let metadata: [String: String]
    let searchableFields: [String]

    init(
        id: String,
        title: String,
        description: String,
        icon: ItemIcon,
        action: ItemAction,
        metadata: [String: String] = [:],
        searchableFields: [String]? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.icon = icon
        self.action = action
        self.metadata = metadata
        self.searchableFields = (searchableFields ?? [title, description] + metadata.keys + metadata.values)
            .map(Self.normalizeForSearch)
    }

    private static func normalizeForSearch(_ value: String) -> String {
        value
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: .current
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var actionLabel: String {
        switch action {
        case .copy: "Copy to clipboard"
        case .shell: "Shell command"
        case .openApplication: "Open application"
        }
    }

    var actionSymbolName: String {
        switch action {
        case .copy: "doc.on.clipboard"
        case .shell: "terminal"
        case .openApplication: "app"
        }
    }

    @MainActor
    func perform() {
        switch action {
        case .copy(let value):
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value.replacingOccurrences(of: "<clipboard>", with: clipboard), forType: .string)
        case .shell(let command):
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/zsh")
            task.arguments = ["-c", "export PATH=/usr/bin:/bin:/usr/local/bin:$PATH; \(command.replacingOccurrences(of: "<clipboard>", with: clipboard))"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe
            do {
                try task.run()
                task.waitUntilExit()
            } catch {
                print("Failed to run action: \(error)")
            }
        case .openApplication(let path):
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: path),
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    print("Failed to open application at \(path): \(error)")
                }
            }
        }
    }
}

protocol ItemSource: Sendable {
    var id: String { get }
    func loadItems() async throws -> [Item]
}

struct ItemSourceRegistry: Sendable {
    let sources: [any ItemSource]

    func loadAllItems() async -> [Item] {
        await withTaskGroup(of: (Int, [Item]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return (index, try await source.loadItems())
                    } catch {
                        print("Item source '\(source.id)' failed: \(error)")
                        return (index, [])
                    }
                }
            }

            var results: [(Int, [Item])] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
    }

    static let standard = ItemSourceRegistry(sources: [FileItemSource(), ApplicationsItemSource()])
}

let itemsConfigURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("items.json")

struct ConfigItem: Codable {
    let title: String
    let icon: String
    let value: String
    let type: String

    var item: Item {
        let action: ItemAction = type == "clipboard" ? .copy(value) : .shell(value)
        let description = type == "sh"
            ? "Shell · \(value.replacingOccurrences(of: "<clipboard>", with: "⌘V"))"
            : "Clipboard · Inserts <clipboard> at runtime"
        return Item(
            id: "file:\(title):\(type):\(value)",
            title: title,
            description: description,
            icon: .text(icon),
            action: action
        )
    }
}

func loadOrCreateItemsConfigData() throws -> Data {
    if FileManager.default.fileExists(atPath: itemsConfigURL.path) {
        return try Data(contentsOf: itemsConfigURL)
    }

    let exampleItems = [
        ConfigItem(title: "Copy a greeting", icon: "👋", value: "Hello from HotActions!", type: "clipboard"),
        ConfigItem(title: "Add a prefix to clipboard text", icon: "📋", value: "Selected text: <clipboard>", type: "clipboard"),
        ConfigItem(title: "Open the example website", icon: "🌐", value: "open 'https://example.com'", type: "sh"),
        ConfigItem(title: "Run curl with the clipboard value", icon: "⚡️", value: "osascript -e 'tell application \"Terminal\" to do script \"curl -v <clipboard>\"'", type: "sh"),
        ConfigItem(title: "Run traceroute in Terminal", icon: "🛰️", value: "osascript -e 'tell application \"Terminal\" to do script \"traceroute 8.8.8.8\"'", type: "sh")
    ]

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(exampleItems)
    try data.write(to: itemsConfigURL, options: .atomic)
    return data
}

struct FileItemSource: ItemSource {
    let id = "file"

    func loadItems() async throws -> [Item] {
        let data = try loadOrCreateItemsConfigData()
        return try JSONDecoder().decode([ConfigItem].self, from: data).map(\.item)
    }
}

struct ApplicationsItemSource: ItemSource {
    let id = "applications"

    func loadItems() async throws -> [Item] {
        await ApplicationsCache.shared.items()
    }

    fileprivate static func discoverApplications() -> [Item] {
        let fileManager = FileManager.default
        let roots = fileManager.urls(for: .applicationDirectory, in: .allDomainsMask)
        var seenPaths = Set<String>()
        var items: [Item] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: { url, error in
                    print("Could not inspect \(url.path): \(error)")
                    return true
                }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()

                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted, let bundle = Bundle(url: url) else { continue }

                let info = bundle.infoDictionary ?? [:]
                let name = (info["CFBundleDisplayName"] as? String)
                    ?? (info["CFBundleName"] as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                let bundleIdentifier = bundle.bundleIdentifier
                let version = info["CFBundleShortVersionString"] as? String
                let build = info["CFBundleVersion"] as? String
                let copyright = info["NSHumanReadableCopyright"] as? String
                let minimumSystemVersion = info["LSMinimumSystemVersion"] as? String

                var metadata: [String: String] = ["path": path]
                if let bundleIdentifier { metadata["bundleIdentifier"] = bundleIdentifier }
                if let version { metadata["version"] = version }
                if let build { metadata["build"] = build }
                if let copyright { metadata["copyright"] = copyright }
                if let minimumSystemVersion { metadata["minimumSystemVersion"] = minimumSystemVersion }

                var details: [String] = []
                if let version { details.append("Version \(version)" + (build.map { " (\($0))" } ?? "")) }
                if let bundleIdentifier { details.append(bundleIdentifier) }
                details.append(path)
                if let copyright { details.append(copyright) }

                items.append(Item(
                    id: "applications:\(path)",
                    title: name,
                    description: details.joined(separator: " · "),
                    icon: .file(path),
                    action: .openApplication(path),
                    metadata: metadata,
                    searchableFields: [name, bundleIdentifier].compactMap { $0 }
                ))
            }
        }

        return items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

private actor ApplicationsCache {
    static let shared = ApplicationsCache()

    private var cachedItems: [Item]?

    func items() async -> [Item] {
        if let cachedItems {
            return cachedItems
        }

        let discoveredItems = await Task.detached(priority: .userInitiated) {
            ApplicationsItemSource.discoverApplications()
        }.value
        cachedItems = discoveredItems
        return discoveredItems
    }
}
