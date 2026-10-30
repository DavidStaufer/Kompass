import Foundation

/// Wo Kompass seine Daten ablegt: lokal oder in einem iCloud-Drive-Ordner,
/// den Mac und iPhone gemeinsam nutzen.
final class StorageLocation: @unchecked Sendable {
    static let shared = StorageLocation()

    enum Mode: String { case local, iCloud }

    private(set) var root: URL
    private(set) var mode: Mode
    /// Hinweis, falls iCloud Drive nicht genutzt werden konnte.
    private(set) var problem: String?
    private var accessing: URL?
    private let defaults = UserDefaults.standard

    static let localRoot: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Kompass", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    #if os(macOS)
    /// iCloud Drive auf dem Mac (nicht-sandboxed direkt erreichbar).
    static var macICloudDrive: URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    #endif

    private init() {
        root = StorageLocation.localRoot
        mode = .local
        if let custom = defaults.string(forKey: "kompass.dataDir"), !custom.isEmpty {
            root = URL(fileURLWithPath: custom, isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            return
        }
        #if os(macOS)
        // Standard auf dem Mac: iCloud Drive/Kompass (falls iCloud Drive aktiv ist)
        let wanted = Mode(rawValue: defaults.string(forKey: "storage.mode") ?? "iCloud") ?? .iCloud
        if wanted == .iCloud, let drive = StorageLocation.macICloudDrive {
            let folder = drive.appendingPathComponent("Kompass", isDirectory: true)
            if StorageLocation.canWrite(folder) {
                StorageLocation.migrateIfNeeded(from: StorageLocation.localRoot, to: folder)
                root = folder
                mode = .iCloud
            } else {
                // Kein Zugriff (z. B. abgelehnt) → sicher lokal weiterarbeiten
                problem = "Kein Zugriff auf iCloud Drive – Kompass speichert vorerst nur auf diesem Mac. Erlaube den Zugriff in den Systemeinstellungen und aktiviere die Synchronisierung erneut."
            }
        }
        #else
        if let data = defaults.data(forKey: "storage.bookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                if url.startAccessingSecurityScopedResource() { accessing = url }
                root = url
                mode = .iCloud
                if stale, let fresh = try? url.bookmarkData() { defaults.set(fresh, forKey: "storage.bookmark") }
            }
        }
        #endif
    }

    var displayPath: String {
        if mode == .iCloud {
            #if os(macOS)
            return "iCloud Drive › \(root.lastPathComponent)"
            #else
            return "iCloud › \(root.lastPathComponent)"
            #endif
        }
        return "Nur auf diesem Gerät"
    }

    /// Prüft, ob ein Ordner angelegt und beschrieben werden kann.
    static func canWrite(_ folder: URL) -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let probe = folder.appendingPathComponent(".kompass-schreibtest")
            try Data("ok".utf8).write(to: probe)
            try? fm.removeItem(at: probe)
            return true
        } catch {
            return false
        }
    }

    #if os(macOS)
    /// Mac: zwischen iCloud Drive und lokal wechseln.
    func setMacMode(_ m: Mode) -> Bool {
        defaults.set(m.rawValue, forKey: "storage.mode")
        if m == .iCloud, let drive = StorageLocation.macICloudDrive {
            let folder = drive.appendingPathComponent("Kompass", isDirectory: true)
            guard StorageLocation.canWrite(folder) else {
                problem = "Kein Zugriff auf iCloud Drive. Bitte in den Systemeinstellungen erlauben."
                defaults.set(Mode.local.rawValue, forKey: "storage.mode")
                return false
            }
            problem = nil
            StorageLocation.migrateIfNeeded(from: root, to: folder)
            root = folder
            mode = .iCloud
            return true
        }
        if m == .local {
            StorageLocation.migrateIfNeeded(from: root, to: StorageLocation.localRoot, overwrite: true)
            root = StorageLocation.localRoot
            mode = .local
            return true
        }
        return false
    }
    #endif

    /// iPhone: vom Nutzer gewählten iCloud-Drive-Ordner verwenden.
    /// - Returns: true, wenn dort bereits Kompass-Daten lagen (z. B. vom Mac).
    @discardableResult
    func useFolder(_ url: URL) throws -> Bool {
        let ok = url.startAccessingSecurityScopedResource()
        if let old = accessing, old != url { old.stopAccessingSecurityScopedResource() }
        accessing = ok ? url : nil
        let bookmark = try url.bookmarkData()
        defaults.set(bookmark, forKey: "storage.bookmark")
        let existing = CoordinatedFile.exists(url.appendingPathComponent("kompass.json"))
        if !existing { StorageLocation.migrateIfNeeded(from: root, to: url) }
        root = url
        mode = .iCloud
        return existing
    }

    func useLocal() {
        StorageLocation.migrateIfNeeded(from: root, to: StorageLocation.localRoot, overwrite: true)
        defaults.removeObject(forKey: "storage.bookmark")
        accessing?.stopAccessingSecurityScopedResource()
        accessing = nil
        root = StorageLocation.localRoot
        mode = .local
    }

    /// Kopiert vorhandene Daten in den neuen Ordner, falls dort noch keine liegen.
    static func migrateIfNeeded(from: URL, to: URL, overwrite: Bool = false) {
        guard from.standardizedFileURL != to.standardizedFileURL else { return }
        let fm = FileManager.default
        let target = to.appendingPathComponent("kompass.json")
        if CoordinatedFile.exists(target) && !overwrite { return }
        guard fm.fileExists(atPath: from.appendingPathComponent("kompass.json").path) else { return }
        let items = (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? []
        for item in items where !item.lastPathComponent.hasPrefix(".") {
            let dest = to.appendingPathComponent(item.lastPathComponent)
            if overwrite { try? fm.removeItem(at: dest) }
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: item, to: dest) }
        }
    }
}

/// Koordinierter Dateizugriff – nötig für iCloud Drive (lädt Platzhalter, verhindert halbe Schreibvorgänge).
enum CoordinatedFile {
    static func exists(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        // Ausgelagerte iCloud-Datei („.name.icloud“)
        let placeholder = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud")
        return fm.fileExists(atPath: placeholder.path)
    }

    static func read(_ url: URL) -> Data? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var result: Data?
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &error) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        var ok = false
        var error: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: .forReplacing, error: &error) { u in
            ok = (try? data.write(to: u, options: .atomic)) != nil
        }
        return ok
    }

    static func modificationDate(_ url: URL) -> Date? {
        var u = url
        u.removeAllCachedResourceValues()
        return (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// iCloud: Liegt in der Cloud eine neuere Fassung, als dieses Gerät hat? Dann wird sie angefordert –
    /// bis sie da ist, darf die alte Kopie nicht überschrieben werden.
    static func needsDownload(_ url: URL) -> Bool {
        var u = url
        u.removeAllCachedResourceValues()
        guard let v = try? u.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]),
              v.isUbiquitousItem == true, let status = v.ubiquitousItemDownloadingStatus, status != .current else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        return true
    }

    /// Fassungen, die iCloud aufbewahrt, wenn zwei Geräte gleichzeitig gespeichert haben.
    static func conflictVersions(_ url: URL) -> [NSFileVersion] {
        NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
    }
}

/// Dreiwege-Zusammenführung zweier Datenstände (lokal vs. anderes Gerät) auf Datensatz-Ebene.
enum DataMerge {
    static func merge(base: [String: Any], local: [String: Any], remote: [String: Any]) -> [String: Any] {
        var out = local
        for key in Set(local.keys).union(remote.keys) {
            let b = base[key], l = local[key], r = remote[key]
            if let la = l as? [Any], let ra = r as? [Any], isRecordArray(la) || isRecordArray(ra) {
                out[key] = mergeArrays(base: (b as? [Any]) ?? [], local: la, remote: ra)
            } else if key == "skipped", let ld = l as? [String: Any], let rd = r as? [String: Any] {
                out[key] = ld.merging(rd) { a, _ in a }
            } else if let ld = l as? [String: Any], let rd = r as? [String: Any] {
                // z. B. Einstellungen: je Schlüssel – lokal unverändert → Stand des anderen Geräts.
                // Geräteabhängige Kalender-IDs bleiben immer lokal.
                let bd = (b as? [String: Any]) ?? [:]
                var m = ld
                let deviceKeys: Set<String> = key == "prefs" ? ["kompassCalendarID", "reminderListID", "workCalendarID", "hiddenCalendarIDs"] : []
                for k in Set(ld.keys).union(rd.keys) where !deviceKeys.contains(k) && equal(ld[k], bd[k]) {
                    m[k] = rd[k]
                }
                out[key] = m
            } else if equal(l, b) {
                out[key] = r
            }
        }
        return out
    }

    /// Schutz vor veralteten Kopien: Verschwindet beim Abgleich auf einen Schlag ein großer Teil der Einträge
    /// (z. B. alle Module), stammt das praktisch immer von einem Gerät mit altem Stand – nicht von echtem Löschen.
    /// Solche „Löschungen“ werden nicht übernommen; geliefert werden der bereinigte Fremdstand und die betroffenen Schlüssel.
    static func blockingMassDeletions(base: [String: Any], local: [String: Any], remote: [String: Any]) -> (remote: [String: Any], blocked: [String]) {
        var out = remote
        var blocked: [String] = []
        for (key, b) in base {
            guard let ba = b as? [Any], isRecordArray(ba), let la = local[key] as? [Any] else { continue }
            let ra = (remote[key] as? [Any]) ?? []
            let baseIDs = Set(ba.compactMap(id))
            let remoteIDs = Set(ra.compactMap(id))
            var localByID: [String: Any] = [:]
            for x in la { if let i = id(x) { localByID[i] = x } }
            let removed = baseIDs.subtracting(remoteIDs).filter { localByID[$0] != nil }
            guard removed.count >= 2, removed.count * 2 >= baseIDs.count else { continue }
            out[key] = ra + removed.sorted().compactMap { localByID[$0] }
            blocked.append(key)
        }
        return (out, blocked.sorted())
    }

    private static func isRecordArray(_ a: [Any]) -> Bool {
        guard let first = a.first as? [String: Any] else { return false }
        return first["id"] != nil
    }

    private static func id(_ any: Any) -> String? { (any as? [String: Any])?["id"] as? String }

    static func mergeArrays(base: [Any], local: [Any], remote: [Any]) -> [Any] {
        var baseByID: [String: Any] = [:]
        for x in base { if let i = id(x) { baseByID[i] = x } }
        var remoteByID: [String: Any] = [:]
        for x in remote { if let i = id(x) { remoteByID[i] = x } }
        let localIDs = Set(local.compactMap(id))

        var result: [Any] = []
        for l in local {
            guard let i = id(l) else { result.append(l); continue }
            if let r = remoteByID[i] {
                // Nur hier geändert → lokal; nur dort geändert → dort; beides → lokal gewinnt
                result.append(equal(l, baseByID[i]) ? r : l)
            } else if let b = baseByID[i], equal(l, b) {
                continue // auf dem anderen Gerät gelöscht
            } else {
                result.append(l)
            }
        }
        for r in remote {
            guard let i = id(r), !localIDs.contains(i) else { continue }
            if baseByID[i] != nil { continue } // hier gelöscht
            result.append(r)                   // dort neu
        }
        return result
    }

    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        default: return (a as AnyObject).isEqual(b as AnyObject)
        }
    }
}
