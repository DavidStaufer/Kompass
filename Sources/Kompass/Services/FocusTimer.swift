import Foundation
import Observation

/// Fokus-Timer: misst Lernzeit pro Modul und speichert sie als Lerneinheit.
@MainActor
@Observable
final class FocusTimer {
    var moduleID: UUID?
    var kind: TrackKind = .module
    var categoryID: UUID?
    var taskID: UUID?
    var startedAt: Date?
    var targetMinutes: Int = 50
    var blockID: UUID?
    /// Tickt jede Sekunde, solange der Timer läuft.
    var now = Date()

    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private let store: DataStore
    @ObservationIgnored var sync: SyncService?

    private let defaults = UserDefaults.standard

    init(store: DataStore) {
        self.store = store
        // Laufenden Timer nach Neustart wiederherstellen
        if let ts = defaults.object(forKey: "focus.start") as? Double {
            startedAt = Date(timeIntervalSince1970: ts)
            moduleID = defaults.string(forKey: "focus.module").flatMap(UUID.init(uuidString:))
            kind = defaults.string(forKey: "focus.kind").flatMap(TrackKind.init(rawValue:)) ?? .module
            categoryID = defaults.string(forKey: "focus.category").flatMap(UUID.init(uuidString:))
            taskID = defaults.string(forKey: "focus.task").flatMap(UUID.init(uuidString:))
            targetMinutes = defaults.integer(forKey: "focus.target").nonZero ?? 50
            blockID = defaults.string(forKey: "focus.block").flatMap(UUID.init(uuidString:))
            startTicker()
        }
    }

    var isRunning: Bool { startedAt != nil }
    var elapsed: TimeInterval { startedAt.map { now.timeIntervalSince($0) } ?? 0 }
    var remaining: TimeInterval { Double(targetMinutes) * 60 - elapsed }
    var progress: Double { min(1, elapsed / max(1, Double(targetMinutes) * 60)) }
    var isOvertime: Bool { isRunning && remaining <= 0 }

    var display: String {
        if targetMinutes >= 8 * 60 {
            let e = Int(elapsed)
            return e >= 3600 ? String(format: "%d:%02d:%02d", e / 3600, (e % 3600) / 60, e % 60) : String(format: "%d:%02d", e / 60, e % 60)
        }
        let s = Int(abs(isOvertime ? -remaining : remaining))
        let str = String(format: "%d:%02d", s / 60, s % 60)
        return isOvertime ? "+" + str : str
    }

    var target: TrackTarget { TrackTarget(kind: kind, moduleID: moduleID, categoryID: categoryID) }

    func start(moduleID: UUID, minutes: Int, blockID: UUID? = nil, taskID: UUID? = nil) {
        start(target: .module(moduleID), minutes: minutes, blockID: blockID, taskID: taskID)
    }

    func start(target: TrackTarget, minutes: Int, blockID: UUID? = nil, taskID: UUID? = nil) {
        if isRunning { stop(save: true) }
        self.kind = target.kind
        self.moduleID = target.moduleID
        self.categoryID = target.categoryID
        self.taskID = taskID
        self.targetMinutes = minutes
        self.blockID = blockID
        startedAt = Date()
        now = Date()
        defaults.set(startedAt!.timeIntervalSince1970, forKey: "focus.start")
        defaults.set(target.moduleID?.uuidString, forKey: "focus.module")
        defaults.set(target.kind.rawValue, forKey: "focus.kind")
        defaults.set(target.categoryID?.uuidString, forKey: "focus.category")
        defaults.set(taskID?.uuidString, forKey: "focus.task")
        defaults.set(minutes, forKey: "focus.target")
        defaults.set(blockID?.uuidString, forKey: "focus.block")
        startTicker()
        if minutes < 8 * 60 { sync?.scheduleFocusEnd(at: Date().adding(minutes: minutes), moduleName: store.label(for: target).name) }
    }

    @discardableResult
    func stop(save: Bool) -> Int {
        defer { reset() }
        guard let startedAt, save else { return 0 }
        let minutes = Int((Date().timeIntervalSince(startedAt) / 60).rounded())
        if minutes >= 1 {
            // Passenden Lernblock finden (explizit gestartet oder zeitlich überlappend)
            var blockIndex: Int?
            if kind == .module, let moduleID {
                blockIndex = blockID.flatMap { id in store.blocks.firstIndex { $0.id == id } }
                    ?? store.blocks.firstIndex { $0.moduleID == moduleID && $0.status == .planned && $0.start <= Date() && $0.end >= startedAt }
            }
            let block = blockIndex.map { store.blocks[$0] }
            store.logWork(target, start: startedAt, minutes: minutes, source: .timer, taskID: taskID,
                          blockID: block?.id)
            if let blockIndex, let block {
                store.blocks[blockIndex].status = minutes >= block.minutes / 2 ? .done : .partial
            }
        }
        return minutes
    }

    private func reset() {
        startedAt = nil
        moduleID = nil
        categoryID = nil
        taskID = nil
        kind = .module
        blockID = nil
        ticker?.invalidate()
        ticker = nil
        for k in ["focus.start", "focus.module", "focus.target", "focus.block", "focus.kind", "focus.category", "focus.task"] { defaults.removeObject(forKey: k) }
        sync?.cancelFocusEnd()
    }

    private func startTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }
}

extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}
