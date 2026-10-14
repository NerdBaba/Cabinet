import SwiftUI
import AppKit
import CoreText

@main
struct CartridgesApp: App {
    @StateObject private var store = LibraryStore()
    @AppStorage("cartridges.theme") private var theme = "system"
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    init() {
        for name in ["InterVariable", "InterVariable-Italic"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }

    private var colorScheme: ColorScheme? {
        theme == "dark" ? .dark : theme == "light" ? .light : nil
    }

    var body: some Scene {
        Window("Cabinet", id: "main") {
            LibraryView(store: store)
                .frame(minWidth: 720, minHeight: 520)
                .preferredColorScheme(colorScheme)
                .background(WindowConfiguration(theme: theme))
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { openWindow(id: "settings") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Add Game…") { NotificationCenter.default.post(name: .cartridgesAddGame, object: nil) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("Refresh Library") { NotificationCenter.default.post(name: .cartridgesRefresh, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button("Search Games") { NotificationCenter.default.post(name: .cartridgesFocusSearch, object: nil) }
                    .keyboardShortcut("f", modifiers: .command)
            }
        }
        Window("Settings", id: "settings") {
            SettingsView(store: store)
                .preferredColorScheme(colorScheme)
                .background(WindowConfiguration(theme: theme))
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 520, height: 400)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, let window = sender.windows.first(where: { $0.identifier?.rawValue == "main" }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

struct WindowConfiguration: NSViewRepresentable {
    let theme: String
    func makeNSView(context: Context) -> ConfiguredWindowView { ConfiguredWindowView() }
    func updateNSView(_ view: ConfiguredWindowView, context: Context) { view.theme = theme; view.applyAppearance() }
    final class ConfiguredWindowView: NSView {
        var theme = "system"
        func applyAppearance() {
            window?.appearance = theme == "dark" ? NSAppearance(named: .darkAqua) : theme == "light" ? NSAppearance(named: .aqua) : nil
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            applyAppearance()
            window.setFrameAutosaveName(window.title.contains("Settings") ? "CartridgesSwiftSettings" : "CartridgesSwiftMain")
        }
    }
}
