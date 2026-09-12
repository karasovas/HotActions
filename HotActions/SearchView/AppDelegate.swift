import Cocoa
import SwiftUI

private final class HotkeyState: @unchecked Sendable {
    private let lock = NSLock()
    private var flagsRawValue = CGEventFlags([.maskCommand, .maskShift]).rawValue
    private var keyCode: UInt16 = 3

    func update(flags: CGEventFlags, keyCode: UInt16) {
        lock.lock()
        defer { lock.unlock() }

        flagsRawValue = flags.rawValue
        self.keyCode = keyCode
    }

    func matches(flagsRawValue: UInt64, keyCode: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        return (flagsRawValue & self.flagsRawValue) == self.flagsRawValue
            && keyCode == self.keyCode
    }

    func currentValues() -> (flagsRawValue: UInt64, keyCode: UInt16) {
        lock.lock()
        defer { lock.unlock() }

        return (flagsRawValue, keyCode)
    }
}

private let hotkeyState = HotkeyState()

private final class SearchWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var settingsWindow: NSWindow?
    var window: NSWindow?
    var contextMenu: NSMenu? // Context menu for the status item.

    func loadHotkeyConfig() {
        if let config = loadHotKeyConfig() {
            hotkeyState.update(
                flags: CGEventFlags(rawValue: UInt64(config.modifierFlagsRaw)),
                keyCode: config.keyCode
            )
            print("🔧 Loaded from file: \(modifierFlagsToString(config.modifierFlags)) + \(keyCodeToString(config.keyCode))")
        } else {
            hotkeyState.update(flags: [.maskCommand, .maskShift], keyCode: 3)
            print("🔧 Using default: ⌘⇧ + F")
        }
    }

    func applicationDidFinishLaunching(_ aNotification: Notification) {
        setupStatusBar()
        initHotKey()
    }

    func initHotKey() {
        loadHotkeyConfig()
        setupGlobalHotkey()
    }

    // ---------------------------------------------------------
    // MARK:  STATUS BAR ICON + LEFT/RIGHT CLICK HANDLING
    // ---------------------------------------------------------
    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "HotAction")
            button.image?.isTemplate = true

            // Handle both left- and right-clicks.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // Right-click menu.
        contextMenu = NSMenu()
        contextMenu?.addItem(NSMenuItem(title: "Show",     action: #selector(showSearchWindow),    keyEquivalent: "s"))
        contextMenu?.addItem(NSMenuItem(title: "Settings", action: #selector(showSettingsWindow), keyEquivalent: "o"))
        contextMenu?.addItem(NSMenuItem.separator())
        contextMenu?.addItem(NSMenuItem(title: "Exit",     action: #selector(exitApp),            keyEquivalent: "q"))
    }

    @objc func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right-click opens the menu.
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil // Important: otherwise left-click stops working.
            return
        }

        // Left-click opens the window.
        triggerWindow()
    }

    // ---------------------------------------------------------
    // MARK:  WINDOWS
    // ---------------------------------------------------------
    @objc func showSearchWindow() {
        triggerWindow()
    }

    @objc func showSettingsWindow() {
        if settingsWindow == nil {
            let settingsView = SettingsView(onHotKeyChanged: { [weak self] in
                self?.initHotKey()
            })
            let hostingView = NSHostingView(rootView: settingsView)

            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 760),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )

            settingsWindow?.title = "Settings"
            settingsWindow?.contentView = hostingView
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
            
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func exitApp() {
        NSApp.terminate(nil)
    }

    // ---------------------------------------------------------
    // MARK: HOTKEY
    // ---------------------------------------------------------
    func setupGlobalHotkey() {
        let mask = (1 << CGEventType.keyDown.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, _ in

                guard type == .keyDown else { return Unmanaged.passUnretained(event) }

                let pressedFlags = event.flags.rawValue
                let pressedKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

                if hotkeyState.matches(flagsRawValue: pressedFlags, keyCode: pressedKeyCode) {
                    DispatchQueue.main.async {
                        NSApp.delegate?.perform(#selector(AppDelegate.triggerWindow))
                    }
                }

                return Unmanaged.passUnretained(event)
            },
            userInfo: nil
        )

        if let eventTap = eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }

        let hotkey = hotkeyState.currentValues()
        print("✅ Hotkey is active: \(hotkey.flagsRawValue) + \(hotkey.keyCode)")
    }

    @objc func triggerWindow() {
        if window == nil {
            let contentView = OverlayContent {
                self.window?.orderOut(nil)
            }

            window = SearchWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 500),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )

            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.hasShadow = true
            window?.center()
            window?.isReleasedWhenClosed = false
            window?.level = .floating
            window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window?.contentView = NSHostingView(rootView: contentView)

        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        if let eventTap = eventTap {
            CFMachPortInvalidate(eventTap)
        }
    }
}
