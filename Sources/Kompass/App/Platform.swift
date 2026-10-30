import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformImage = NSImage
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformImage = UIImage
#endif

/// Kleine Plattform-Schicht, damit derselbe Code auf Mac und iPhone läuft.
enum Platform {
    static var isMac: Bool {
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// Zeigt eine Datei im Finder (nur Mac).
    static func reveal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    static func activateApp() {
        #if os(macOS)
        NSApp.activate()
        #endif
    }

    /// Öffnet die Datenschutz-Einstellungen (Mac) bzw. die App-Einstellungen (iPhone).
    static func openPrivacySettings(reminders: Bool = false) {
        #if os(macOS)
        let anchor = reminders ? "Privacy_Reminders" : "Privacy_Calendars"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }

    static func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }
}

extension Color {
    /// Hintergrund von Karten (leicht vom Fenster abgesetzt).
    static var cardBackground: Color {
        #if os(macOS)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }

    /// Fensterhintergrund.
    static var appBackground: Color {
        #if os(macOS)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color(uiColor: .systemGroupedBackground)
        #endif
    }

    init(platform: PlatformColor) {
        #if os(macOS)
        self.init(nsColor: platform)
        #else
        self.init(uiColor: platform)
        #endif
    }
}

// MARK: - Kompakte Darstellung (iPhone)

// Bewusst ohne `@Entry`: Der Build mit den Command Line Tools (build.sh) hat kein SwiftUI-Makro-Plugin.
private struct CompactLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// true auf dem iPhone (schmale Breite) – Layouts stapeln dann statt nebeneinander.
    var isCompactLayout: Bool {
        get { self[CompactLayoutKey.self] }
        set { self[CompactLayoutKey.self] = newValue }
    }
}

/// Setzt `isCompactLayout` aus der Size-Class (nur iOS).
struct CompactLayoutReader: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.isCompactLayout, sizeClass == .compact)
        #else
        content
        #endif
    }
}

// MARK: - Plattformabhängige Modifier

/// Seitenrand: großzügig auf dem Mac, kompakt auf dem iPhone.
struct PagePadding: ViewModifier {
    @Environment(\.isCompactLayout) private var compact
    func body(content: Content) -> some View {
        content.padding(compact ? 16 : 28)
    }
}

extension View {
    func pagePadding() -> some View { modifier(PagePadding()) }
}

extension View {
    /// Feste Größe nur auf dem Mac (Sheets füllen auf dem iPhone den Bildschirm).
    @ViewBuilder
    func macFrame(width: CGFloat? = nil, height: CGFloat? = nil) -> some View {
        #if os(macOS)
        self.frame(width: width, height: height)
        #else
        self
        #endif
    }

    /// Gruppiertes Formular in Sheets (auf dem iPhone ohne doppelten Seitenrand).
    @ViewBuilder
    func sheetForm() -> some View {
        #if os(iOS)
        self.formStyle(.grouped).contentMargins(.horizontal, 0, for: .scrollContent)
        #else
        self.formStyle(.grouped)
        #endif
    }

    /// Hintergrund von Sheets passend zu gruppierten Formularen (iPhone).
    @ViewBuilder
    func sheetBackground() -> some View {
        #if os(iOS)
        self.presentationBackground(Color.appBackground)
        #else
        self
        #endif
    }

    /// Checkbox auf dem Mac, Schalter auf dem iPhone.
    @ViewBuilder
    func checkboxStyle() -> some View {
        #if os(macOS)
        self.toggleStyle(.checkbox)
        #else
        self.toggleStyle(.switch)
        #endif
    }

    /// Schlichtes Menü ohne Rahmen (optional mit Pfeil).
    @ViewBuilder
    func plainMenu(indicator: Bool = false) -> some View {
        #if os(macOS)
        self.menuStyle(.button).buttonStyle(.borderless).menuIndicator(indicator ? .visible : .hidden).fixedSize()
        #else
        self.menuIndicator(indicator ? .visible : .hidden).fixedSize()
        #endif
    }

    /// Liste mit Rahmen und abwechselnden Zeilen (Mac), sonst Standard.
    @ViewBuilder
    func borderedList() -> some View {
        #if os(macOS)
        self.listStyle(.bordered(alternatesRowBackgrounds: true))
        #else
        self.listStyle(.plain)
        #endif
    }

    /// Popover bleibt auch auf dem iPhone ein Popover (statt Vollbild-Sheet).
    @ViewBuilder
    func compactPopover() -> some View {
        #if os(iOS)
        self.presentationCompactAdaptation(.popover)
        #else
        self
        #endif
    }

    /// Mauszeiger beim Überfahren (nur Mac).
    @ViewBuilder
    func resizeCursor() -> some View {
        #if os(macOS)
        if #available(macOS 15, *) {
            self.pointerStyle(.frameResize(position: .bottom))
        } else {
            self.onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
        #else
        self
        #endif
    }

    /// Inline-Titel auf dem iPhone, da die Seiten eigene große Titel haben.
    @ViewBuilder
    func inlineNavigationTitle() -> some View {
        #if os(iOS)
        self.toolbarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

/// Öffnet die Einstellungen (Mac: eigenes Fenster, iPhone: Sheet).
struct OpenSettingsButton: View {
    var title = "Einstellungen"
    #if os(iOS)
    @Environment(AppModel.self) private var app
    #endif
    var body: some View {
        #if os(macOS)
        SettingsLink { Text(title) }
        #else
        Button(title) { app.showSettings = true }
        #endif
    }
}

// MARK: - Export (Mac & iPhone)

/// Textdatei für `fileExporter` (CSV, Markdown).
struct TextFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    var text: String
    var bom = false

    init(text: String, bom: Bool = false) { self.text = text; self.bom = bom }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var data = Data(text.utf8)
        if bom { data = Data([0xEF, 0xBB, 0xBF]) + data }
        return FileWrapper(regularFileWithContents: data)
    }
}
