import SwiftUI
import UserNotifications
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main
struct KompassApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    @State private var model = AppModel.shared

    var body: some Scene {
        #if os(iOS)
        WindowGroup {
            RootView()
                .withKompassEnvironment(model)
                .onOpenURL { model.handle(url: $0) }
        }
        #else
        Window("Kompass", id: "main") {
            RootView()
                .withKompassEnvironment(model)
                .frame(minWidth: 1000, minHeight: 660)
                .onOpenURL { model.handle(url: $0) }
        }
        .defaultSize(width: 1320, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { KompassCommands(model: model) }

        Settings {
            SettingsView()
                .withKompassEnvironment(model)
        }

        MenuBarExtra {
            MenuBarView()
                .withKompassEnvironment(model)
        } label: {
            MenuBarLabel(timer: model.timer)
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}

extension View {
    func withKompassEnvironment(_ model: AppModel) -> some View {
        self
            .environment(model)
            .environment(model.store)
            .environment(model.calendar)
            .environment(model.timer)
            .environment(model.assistant)
    }
}

#if os(macOS)
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        DemoSupport.runSelfTestIfRequested()
        if Paths.isDemo, let path = UserDefaults.standard.string(forKey: "kompass.snapshot") {
            let delay = UserDefaults.standard.double(forKey: "kompass.snapshotDelay")
            DispatchQueue.main.asyncAfter(deadline: .now() + (delay > 0 ? delay : 3)) {
                Self.snapshot(to: path)
                if UserDefaults.standard.bool(forKey: "kompass.snapshotQuit") { exit(0) }
            }
        }
    }

    /// Demo-Modus: speichert ein Bild des Hauptfensters (inkl. offener Sheets).
    static func snapshot(to path: String) {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let fn = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage").map { unsafeBitCast($0, to: CreateImage.self) }
        for (i, window) in NSApp.windows.filter({ $0.isVisible && $0.frame.width > 300 }).enumerated() {
            let url = URL(fileURLWithPath: i == 0 ? path : path.replacingOccurrences(of: ".png", with: "-\(i).png"))
            // 1 = optionIncludingWindow, 1|8 = boundsIgnoreFraming|bestResolution
            if let fn, let img = fn(.null, 1 << 3, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() {
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
                continue
            }
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppModel.shared.store.saveNow()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            let app = AppModel.shared
            Platform.activateApp()
            if let open = info["open"] as? String {
                app.selection = open == "week" ? .week : (open == "time" ? .time : .today)
            } else if let id = (info["deadline"] as? String).flatMap(UUID.init(uuidString:)) {
                app.selection = .deadlines
                app.sheet = .deadline(id, moduleID: nil, kind: nil)
            }
        }
        completionHandler()
    }
}
#else
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        DemoSupport.runSelfTestIfRequested()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        Task { @MainActor in
            let app = AppModel.shared
            Platform.activateApp()
            if let open = info["open"] as? String {
                app.selection = open == "week" ? .week : (open == "time" ? .time : .today)
            } else if let id = (info["deadline"] as? String).flatMap(UUID.init(uuidString:)) {
                app.selection = .deadlines
                app.sheet = .deadline(id, moduleID: nil, kind: nil)
            }
        }
        completionHandler()
    }
}
#endif

enum DemoSupport {
    static func runSelfTestIfRequested() {
        guard Paths.isDemo, UserDefaults.standard.bool(forKey: "kompass.selftest") else { return }
            let cases: [(String, Int?)] = [("1h 30m", 90), ("90m", 90), ("1,5h", 90), ("1.5", 90), ("2", 120), ("45", 45), ("1:30", 90),
                                            ("2d", 960), ("1w", 2400), ("3 Std.", 180), ("20 min", 20), ("abc", nil), ("", nil), ("1h abc", nil)]
            var failed = 0
            for (input, expected) in cases {
                let got = Fmt.parseDuration(input)
                if got != expected { failed += 1; print("FAIL parseDuration(\"\(input)\") = \(String(describing: got)), erwartet \(String(describing: expected))") }
            }
            for m in [0, 45, 60, 90, 125] { print("jira(\(m)) = \(Fmt.jira(m))") }
            // Dreiwege-Zusammenführung (iCloud-Sync)
            func rec(_ id: String, _ v: String) -> [String: Any] { ["id": id, "name": v] }
            func names(_ any: Any?) -> [String] { ((any as? [Any]) ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String } }
            let base: [String: Any] = ["modules": [rec("a", "A"), rec("b", "B")], "prefs": ["userName": "D", "kompassCalendarID": "mac", "aiModel": "x"]]
            let local: [String: Any] = ["modules": [rec("a", "A-lokal"), rec("b", "B")], "prefs": ["userName": "D", "kompassCalendarID": "mac", "aiModel": "x"]]
            let remote: [String: Any] = ["modules": [rec("a", "A"), rec("b", "B"), rec("c", "C")], "prefs": ["userName": "David", "kompassCalendarID": "iphone", "aiModel": "x"]]
            let m1 = DataMerge.merge(base: base, local: local, remote: remote)
            let p1 = m1["prefs"] as? [String: Any] ?? [:]
            let checks: [(String, Bool)] = [
                ("lokale Änderung + neues Element vom anderen Gerät", names(m1["modules"]) == ["A-lokal", "B", "C"]),
                ("Einstellung vom anderen Gerät übernommen", (p1["userName"] as? String) == "David"),
                ("Kalender-ID bleibt geräte-lokal", (p1["kompassCalendarID"] as? String) == "mac"),
                ("lokal gelöscht bleibt gelöscht", names(DataMerge.merge(base: base, local: ["modules": [rec("a", "A")]], remote: base)["modules"]) == ["A"]),
                ("dort gelöscht wird übernommen", names(DataMerge.merge(base: base, local: base, remote: ["modules": [rec("b", "B")]])["modules"]) == ["B"]),
                ("beide bearbeitet → lokal gewinnt", names(DataMerge.merge(base: base, local: ["modules": [rec("a", "L"), rec("b", "B")]], remote: ["modules": [rec("a", "R"), rec("b", "B")]])["modules"]) == ["L", "B"]),
                ("nur dort bearbeitet → übernommen", names(DataMerge.merge(base: base, local: base, remote: ["modules": [rec("a", "R"), rec("b", "B")]])["modules"]) == ["R", "B"])
            ]
            for (name, ok) in checks where !ok { failed += 1; print("FAIL Merge: \(name)") }
            print(failed == 0 ? "SELFTEST OK" : "SELFTEST: \(failed) Fehler")
            exit(failed == 0 ? 0 : 1)
    }
}

#if os(macOS)
struct KompassCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Neuer Termin") { model.sheet = .newEvent(start: Date().at(minutes: (Date().minutesSinceMidnight / 30 + 1) * 30), end: Date().at(minutes: (Date().minutesSinceMidnight / 30 + 3) * 30), moduleID: nil) }
                .keyboardShortcut("n", modifiers: [.command])
            Button("Neue Frist …") { model.sheet = .deadline(nil, moduleID: nil, kind: nil) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Neues Modul …") { model.sheet = .newModule }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Neue Aufgabe …") { model.sheet = .task(nil, moduleID: nil) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Zeit buchen …") { model.sheet = .logWork(LogPreset()) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandMenu("Gehe zu") {
            Button("Heute") { model.selection = .today }.keyboardShortcut("1", modifiers: .command)
            Button("Kalender") { model.selection = .calendar }.keyboardShortcut("2", modifiers: .command)
            Button("Wochenplan") { model.selection = .week }.keyboardShortcut("3", modifiers: .command)
            Button("Fristen") { model.selection = .deadlines }.keyboardShortcut("4", modifiers: .command)
            Button("Karteikarten") { model.selection = .cards }.keyboardShortcut("5", modifiers: .command)
            Button("Zeiten") { model.selection = .time }.keyboardShortcut("6", modifiers: .command)
            Divider()
            Button(model.showAssistant ? "Assistent ausblenden" : "Assistent einblenden") {
                withAnimation(Motion.standard) { model.showAssistant.toggle() }
            }
            .keyboardShortcut("j", modifiers: .command)
            Button("Nächste Woche planen …") { model.sheet = .planner(Date().startOfWeek.adding(weeks: 1)) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
#endif
