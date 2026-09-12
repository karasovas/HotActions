import SwiftUI

enum KeyPress {
    case upArrow, downArrow, returnKey
}

struct KeyHandlingModifier: ViewModifier {
    var onKey: (KeyPress) -> Void

    func body(content: Content) -> some View {
        content.background(KeyHandlingView(onKey: onKey))
    }
}

struct KeyHandlingView: NSViewRepresentable {
    var onKey: (KeyPress) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSEventView()
        view.onKey = onKey
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class NSEventView: NSView {
    var onKey: ((KeyPress) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: onKey?(.downArrow)
        case 126: onKey?(.upArrow)
        case 36:  onKey?(.returnKey)
        default: break
        }
    }

    override func viewDidMoveToWindow() {
        window?.makeFirstResponder(self)
    }
}

extension View {
    func onKeyDown(perform: @escaping (KeyPress) -> Void) -> some View {
        modifier(KeyHandlingModifier(onKey: perform))
    }
}
