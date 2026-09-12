# HotActions

HotActions is a lightweight macOS menu-bar launcher for quickly finding applications and running custom actions. Open it with a global keyboard shortcut, search with typo-tolerant fuzzy matching, and press Return to launch the selected result.

## Features

- Search and open installed macOS applications
- Run custom shell commands
- Copy predefined or transformed text to the clipboard
- Insert the current clipboard value with the `<clipboard>` placeholder
- Fuzzy matching with typo tolerance
- Automatic correction between English and Russian keyboard layouts
- Full keyboard navigation with Up, Down, Return, and Escape
- Configurable global hotkey (default: `⌘⇧F`)
- Optional launch at login
- Adjustable font size, spacing, and window opacity
- Menu-bar interface with Liquid Glass on macOS 26 and a material fallback on earlier versions
- Automatic reload when the actions configuration changes

## Requirements

- macOS 15.0 or later
- Xcode 16 or later
- Swift 5

## Build and run

1. Clone the repository:

   ```sh
   git clone git@github.com:karasovas/HotActions.git
   cd HotActions
   ```

2. Open `HotActions.xcodeproj` in Xcode.
3. Select the **HotActions** scheme and your Mac as the run destination.
4. If necessary, choose your development team under **Signing & Capabilities**.
5. Build and run with `⌘R`.

HotActions runs as a menu-bar app, so it does not appear in the Dock. Click the lightning-bolt icon to show the launcher, or right-click it to open Settings or quit.

## Permissions

The global shortcut uses a macOS keyboard event tap. On first launch, macOS may ask you to allow HotActions under **System Settings → Privacy & Security → Input Monitoring** or **Accessibility**.

After granting permission, restart HotActions if the shortcut does not respond. You can always open the launcher by clicking its menu-bar icon.

## Custom actions

HotActions stores its action list at:

```text
~/items.json
```

The file is created automatically with example actions. You can edit it from **Settings → Actions configuration** or in any text editor. Changes are detected automatically.

Each item has four fields:

```json
[
  {
    "title": "Copy a greeting",
    "icon": "👋",
    "value": "Hello from HotActions!",
    "type": "clipboard"
  },
  {
    "title": "Open a website",
    "icon": "🌐",
    "value": "open 'https://example.com'",
    "type": "sh"
  }
]
```

| Field | Description |
| --- | --- |
| `title` | Name shown in search results |
| `icon` | Text or emoji displayed beside the action |
| `value` | Text to copy or shell command to execute |
| `type` | `clipboard` to copy text, or `sh` to run a command with `/bin/zsh` |

Use `<clipboard>` anywhere in `value` to substitute the current clipboard contents at runtime:

```json
{
  "title": "Add a prefix",
  "icon": "📋",
  "value": "Selected text: <clipboard>",
  "type": "clipboard"
}
```

When saving from Settings, HotActions validates the JSON and keeps the previous file as `~/items.json.backup`.

> [!CAUTION]
> Shell actions execute their `value` directly through `/bin/zsh -c`. Only add commands you understand and trust. Clipboard content substituted into a shell action is not escaped automatically.

## Usage

1. Press `⌘⇧F` or click the menu-bar icon.
2. Start typing to search applications and actions.
3. Use Up and Down to change the selection.
4. Press Return to run the selected item.
5. Press Escape to close the launcher.

Open **Settings** from the menu-bar icon's right-click menu to change the shortcut, appearance, application search, launch-at-login behavior, or action configuration.

## Project structure

```text
HotActions/
├── SearchView/
│   ├── AppDelegate.swift     # Menu bar, windows, and global shortcut
│   ├── ItemSources.swift     # Custom actions and application discovery
│   ├── SearchView.swift      # Search ranking and launcher interface
│   ├── KeyPress.swift        # Keyboard event handling
│   └── MainView.swift        # App entry point
└── Settings/
    └── SettingsView.swift    # Preferences and action editor
```

## Contributing

Issues and pull requests are welcome. For changes:

1. Create a branch.
2. Make a focused change.
3. Build the **HotActions** scheme in Xcode.
4. Open a pull request describing the behavior and how it was tested.

## License

HotActions is available under the [MIT License](LICENSE).
