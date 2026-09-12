//
//  SettingsView.swift
//  HotActions
//
//  Created by Alexander Karasov on 21.04.2025.
//

import SwiftUI
import ServiceManagement

extension Notification.Name {
    static let itemsConfigDidChange = Notification.Name("itemsConfigDidChange")
}

struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }
        textView.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text = textView.string
        }
    }
}

struct HotKeyConfig: Codable {
    var modifierFlagsRaw: UInt
    var keyCode: UInt16

    var modifierFlags: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlagsRaw)
    }

    init(modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) {
        self.modifierFlagsRaw = modifierFlags.rawValue
        self.keyCode = keyCode
    }
}

func saveHotKeyConfig(_ config: HotKeyConfig) {
    let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("HotActions")
        .appendingPathComponent("hotkey_config.json")
    
    print(url)

    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

    if let data = try? JSONEncoder().encode(config) {
        try? data.write(to: url)
    }
}

func loadHotKeyConfig() -> HotKeyConfig? {
    let url = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first!
        .appendingPathComponent("HotActions")
        .appendingPathComponent("hotkey_config.json")

    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(HotKeyConfig.self, from: data)
}

func modifierFlagsToString(_ flags: NSEvent.ModifierFlags) -> String {
    var result = ""
    if flags.contains(.command) { result += "⌘" }
    if flags.contains(.option)  { result += "⌥" }
    if flags.contains(.control) { result += "⌃" }
    if flags.contains(.shift)   { result += "⇧" }
    return result
}

func keyCodeToString(_ keyCode: UInt16) -> String {
    let keyMap: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0", 30: "]",
        31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "\"", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
        46: "M", 47: ".", 50: "`",
        36: "↩︎", 48: "⇥", 49: "␣", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4",
        96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12",
        105: "F13", 107: "F14", 113: "F15", 106: "F16",
        64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    return keyMap[keyCode] ?? "KeyCode(\(keyCode))"
}

struct SettingsView: View {
    var onHotKeyChanged: () -> Void

    @State private var isAutostartEnabled = false
    @AppStorage("overlayFontScale") private var overlayFontScale = 2.0
    @AppStorage("overlaySpacingScale") private var overlaySpacingScale = 2.0
    @AppStorage("overlayOpacity") private var overlayOpacity = 1.0
    @AppStorage("searchApplications") private var searchApplications = true
    @State private var showHotKeyCapture = false
    @State private var capturedHotKey: HotKeyConfig? = loadHotKeyConfig()
    @State private var keyCaptureMonitor: Any? = nil
    @State private var itemsConfigText = ""
    @State private var configStatus = ""
    @State private var displayedHotKey: String = {
        if let config = loadHotKeyConfig() {
            return "\(modifierFlagsToString(config.modifierFlags))\(keyCodeToString(config.keyCode))"
        } else {
            return "Not set"
        }
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                if let appIcon = NSImage(named: "AppIcon") {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: 48, height: 48)
                        .cornerRadius(10)
                }

                VStack(alignment: .leading) {
                    Text("HotActions")
                        .font(.title)
                        .bold()
                    Text("Version \(appVersion)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Settings")
                    .font(.title2.bold())

                Toggle("Autostart", isOn: $isAutostartEnabled)
                    .onChange(of: isAutostartEnabled) { newValue in
                        updateAutostartStatus(enable: newValue)
                    }

                Toggle("Search applications", isOn: $searchApplications)

                settingSlider(
                    title: "Search font size",
                    value: $overlayFontScale,
                    range: 1.0...2.5
                )

                settingSlider(
                    title: "Spacing",
                    value: $overlaySpacingScale,
                    range: 0.5...2.5
                )

                settingSlider(
                    title: "Window opacity",
                    value: $overlayOpacity,
                    range: 0.3...1.0
                )

                HStack {
                    Text("Hot key:")
                    Spacer()
                    Text(displayedHotKey)
                        .padding(6)
                        .background(Color.gray.opacity(0.2))
                        .cornerRadius(6)
                        .onTapGesture {
                            showHotKeyCapture = true
                        }
                }

                if showHotKeyCapture {
                    Text("Press a key combination...")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Actions configuration")
                    .font(.title3.bold())

                Text(itemsConfigURL.path)
                    .font(.body.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                PlainTextEditor(text: $itemsConfigText)
                    .frame(minHeight: 240)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25))
                    }

                HStack {
                    Button("Save") {
                        saveItemsConfigText()
                    }
                    .keyboardShortcut("s", modifiers: .command)

                    Spacer()

                    Text(configStatus)
                        .font(.body)
                        .foregroundStyle(configStatus.hasPrefix("Saved") ? .green : .secondary)
                }
            }
        }
        .font(.body)
        .padding(24)
        .frame(width: 640, height: 760)
        .onAppear {
            fetchAutostartStatus()
            loadItemsConfigText()
        }
        .onChange(of: showHotKeyCapture) { isCapturing in
            if isCapturing {
                keyCaptureMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let config = HotKeyConfig(modifierFlags: event.modifierFlags, keyCode: event.keyCode)
                    capturedHotKey = config
                    saveHotKeyConfig(config)
                    displayedHotKey = "\(modifierFlagsToString(config.modifierFlags))\(keyCodeToString(config.keyCode))"
                    showHotKeyCapture = false
                    onHotKeyChanged()
                    return nil
                }
            } else if let monitor = keyCaptureMonitor {
                NSEvent.removeMonitor(monitor)
                keyCaptureMonitor = nil
            }
        }
    }

    private func settingSlider(
        title: LocalizedStringKey,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: range, step: 0.1)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
        }
    }

    var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private func loadItemsConfigText() {
        do {
            let data = try loadOrCreateItemsConfigData()
            itemsConfigText = String(decoding: data, as: UTF8.self)
            configStatus = "Loaded"
        } catch {
            itemsConfigText = "[]\n"
            configStatus = "Could not create file: \(error.localizedDescription)"
        }
    }

    private func saveItemsConfigText() {
        do {
            let data = Data(itemsConfigText.utf8)
            _ = try JSONDecoder().decode([ConfigItem].self, from: data)

            if FileManager.default.fileExists(atPath: itemsConfigURL.path) {
                let backupURL = itemsConfigURL
                    .deletingLastPathComponent()
                    .appendingPathComponent("items.json.backup")
                try? FileManager.default.removeItem(at: backupURL)
                try FileManager.default.copyItem(at: itemsConfigURL, to: backupURL)
            }

            try data.write(to: itemsConfigURL, options: .atomic)
            itemsConfigText = try String(contentsOf: itemsConfigURL, encoding: .utf8)
            configStatus = "Saved"
            NotificationCenter.default.post(name: .itemsConfigDidChange, object: nil)
        } catch {
            configStatus = "Not saved: \(error.localizedDescription)"
        }
    }

    private func updateAutostartStatus(enable: Bool) {
        do {
            let service = try SMAppService.mainApp
            if enable {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            print("Failed to update launch-at-login status: \(error)")
        }
    }

    private func fetchAutostartStatus() {
        do {
            let service = try SMAppService.mainApp
            isAutostartEnabled = service.status == .enabled
        } catch {
            print("Failed to retrieve launch-at-login status: \(error)")
            isAutostartEnabled = false
        }
    }

}
