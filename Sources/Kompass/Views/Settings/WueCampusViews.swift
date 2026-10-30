import SwiftUI

/// Einstellungen → WueCampus: Anmeldung, Kurse, Umfang und Automatik.
struct WueCampusSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(WueCampusSync.self) private var wue
    @State private var manualToken = ""
    @State private var connecting = false

    var body: some View {
        @Bindable var store = store
        @Bindable var wue = wue
        Form {
            Section {
                if let account = wue.account, wue.isConnected {
                    Label("Verbunden als \(account)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Button("Abmelden", role: .destructive) { wue.disconnect() }
                } else {
                    Text("Melde dich einmal mit deinem Uni-Login (JMU-Account) an. Das Passwort gibst du nur auf der Uni-Seite ein – Kompass erhält lediglich einen Zugangsschlüssel, der im Schlüsselbund dieses Geräts liegt.")
                        .font(.callout)
                    HStack {
                        Button {
                            connecting = true
                            Task { await wue.connect(); connecting = false }
                        } label: { Label("Mit WueCampus anmelden", systemImage: "person.badge.key") }
                            .buttonStyle(.borderedProminent)
                            .disabled(connecting)
                        if connecting { ProgressView().controlSize(.small) }
                    }
                    DisclosureGroup("Anmeldung klappt nicht?") {
                        Text("Öffne WueCampus im Browser → oben rechts dein Profilbild → Einstellungen → Sicherheitsschlüssel. Kopiere den Schlüssel bei „Moodle mobile web service“ (erscheint, nachdem du dich einmal mit der Moodle-App angemeldet hast) und füge ihn hier ein.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            SecureField("Schlüssel", text: $manualToken)
                            Button("Verbinden") {
                                connecting = true
                                Task { await wue.connect(manualToken: manualToken); connecting = false; manualToken = "" }
                            }
                            .disabled(manualToken.trimmed.isEmpty || connecting)
                        }
                    }
                }
                if let e = wue.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
            } header: { Text("WueCampus") } footer: {
                Text("Kompass nutzt dieselbe Schnittstelle wie die offizielle Moodle-App und liest nur deine eigenen Kurse.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if wue.isConnected {
                Section("Kurse") {
                    let linked = wue.linkedModules
                    if linked.isEmpty {
                        Text("Noch keine Kurse zugeordnet.").foregroundStyle(.secondary)
                    }
                    ForEach(linked) { m in
                        HStack {
                            ModuleDot(color: m.color.color)
                            Text(m.name)
                            Spacer()
                            Text(m.wueCourseName ?? "Kurs \(m.wueCourseID ?? 0)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Button("Kurse auswählen & zuordnen …") { app.presentFromSettings(.wueCourses) }
                }

                Section("Übernehmen") {
                    Toggle("Dateien (Folien, Übungen, Altklausuren …)", isOn: $store.prefs.wueSyncFiles)
                    Toggle("Abgabetermine aus Aufgaben", isOn: $store.prefs.wueSyncAssignments)
                    Toggle("Weitere Termine (Tests, Kurstermine …)", isOn: $store.prefs.wueSyncEvents)
                    Stepper("Dateien bis \(store.prefs.wueMaxFileMB) MB", value: $store.prefs.wueMaxFileMB, in: 10...500, step: 10)
                    Text("Videos und Archive werden übersprungen. Was du in Kompass löschst, wird nicht erneut geladen.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Synchronisieren") {
                    Toggle("Automatisch auf diesem Gerät (beim Start und alle 3 Stunden)", isOn: $wue.autoSync)
                    HStack {
                        Button {
                            Task { await wue.sync(manual: true) }
                        } label: { Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath") }
                            .disabled(wue.isSyncing || wue.linkedModules.isEmpty)
                        if wue.isSyncing { ProgressView().controlSize(.small) }
                    }
                    if let s = wue.status { Text(s).font(.caption).foregroundStyle(.secondary) }
                    if let r = wue.lastReport { Text("Zuletzt: \(r.summary)").font(.caption).foregroundStyle(.secondary) }
                    if let t = store.prefs.wueLastSync {
                        LabeledContent("Letzter Abgleich", value: "\(Fmt.dayShort(t)), \(Fmt.time(t))")
                    }
                    if !store.prefs.wueIgnoredKeys.isEmpty {
                        Button("\(store.prefs.wueIgnoredKeys.count) gelöschte Einträge wieder laden") { store.prefs.wueIgnoredKeys = [] }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { if wue.isConnected && wue.courses.isEmpty { await wue.loadCourses() } }
    }
}

/// Einmalige Auswahl: welche WueCampus-Kurse zu welchem Modul gehören.
struct WueCourseSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(WueCampusSync.self) private var wue
    @Environment(\.dismiss) private var dismiss

    /// Kurs-ID → Ziel (nil = nicht übernehmen, UUID() mit Sonderwert = neues Modul)
    @State private var included: Set<Int> = []
    @State private var target: [Int: UUID] = [:]
    @State private var showAll = false
    @State private var loaded = false
    private static let newModuleID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: "WueCampus-Kurse", subtitle: "Wähle deine Kurse und ordne sie einem Modul zu") {
                if wue.loadingCourses { ProgressView().controlSize(.small) }
            }
            if !wue.isConnected {
                Label("Bitte zuerst in den Einstellungen mit WueCampus anmelden.", systemImage: "person.badge.key").foregroundStyle(.orange)
            } else if wue.courses.isEmpty && !wue.loadingCourses {
                ContentUnavailableView("Keine aktuellen Kurse gefunden", systemImage: "books.vertical",
                                       description: Text(wue.lastError ?? "In WueCampus bist du derzeit in keinem laufenden Kurs eingeschrieben."))
            }
            List {
                ForEach(wue.courses) { c in
                    WueCourseRow(course: c, newModuleID: Self.newModuleID,
                                 isIncluded: $included[contains: c.id],
                                 target: $target[c.id, or: Self.newModuleID])
                }
            }
            .borderedList()
            .macFrame(height: 380)
            HStack {
                Text("\(included.count) Kurse ausgewählt").foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen & synchronisieren", action: apply)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!wue.isConnected)
            }
        }
        .padding(20)
        .macFrame(width: 620)
        .task {
            if wue.courses.isEmpty { await wue.loadCourses() }
            preselect()
        }
    }

    /// Bereits verknüpfte Kurse markieren und für neue Kurse passende Module vorschlagen.
    private func preselect() {
        guard !loaded else { return }
        loaded = true
        for c in wue.courses {
            if let m = store.modules.first(where: { $0.wueCourseID == c.id }) {
                included.insert(c.id)
                target[c.id] = m.id
            } else if let m = store.activeModules.first(where: { m in
                m.wueCourseID == nil && (c.displayName.localizedCaseInsensitiveContains(m.name) || m.name.localizedCaseInsensitiveContains(c.displayName)
                                         || (!m.code.isEmpty && c.displayName.localizedCaseInsensitiveContains(m.code)))
            }) {
                target[c.id] = m.id
            }
        }
    }

    private func apply() {
        // Verknüpfungen von abgewählten Kursen lösen
        for i in store.modules.indices {
            if let cid = store.modules[i].wueCourseID, !included.contains(cid) {
                store.modules[i].wueCourseID = nil
                store.modules[i].wueCourseName = nil
            }
        }
        let used = Set(store.activeModules.map(\.color))
        var freeColors = ModuleColor.allCases.filter { !used.contains($0) }
        for c in wue.courses where included.contains(c.id) {
            let t = target[c.id] ?? Self.newModuleID
            if t != Self.newModuleID, store.module(t) != nil {
                store.updateModule(t) { $0.wueCourseID = c.id; $0.wueCourseName = c.displayName }
            } else if !store.modules.contains(where: { $0.wueCourseID == c.id }) {
                var m = Module(name: c.displayName)
                m.code = c.shortname.map { String($0.prefix(12)) } ?? ""
                m.termID = store.currentTerm?.id
                m.color = freeColors.isEmpty ? .blue : freeColors.removeFirst()
                m.weeklyGoalHours = Module.suggestedWeeklyHours(ects: m.ects)
                m.wueCourseID = c.id
                m.wueCourseName = c.displayName
                store.modules.append(m)
            }
        }
        dismiss()
        Task { await wue.sync(manual: true) }
    }
}

/// Eine Zeile der Kursauswahl: übernehmen ja/nein und Ziel-Modul.
private struct WueCourseRow: View {
    @Environment(DataStore.self) private var store
    let course: MoodleClient.Course
    let newModuleID: UUID
    @Binding var isIncluded: Bool
    @Binding var target: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                CheckToggle(isOn: $isIncluded)
                    .accessibilityLabel("\(course.displayName) übernehmen")
                VStack(alignment: .leading, spacing: 1) {
                    Text(course.displayName).font(.callout.weight(.medium))
                    if let s = course.shortname, !s.isEmpty { Text(s).font(.caption).foregroundStyle(.secondary) }
                    if !isIncluded, target != newModuleID, let m = store.module(target) {
                        Text("Passt zu deinem Modul „\(m.name)“").font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
            }
            if isIncluded {
                Picker("Modul", selection: $target) {
                    Text("Neues Modul anlegen").tag(newModuleID)
                    ForEach(store.activeModules) { m in Text(m.name).tag(m.id) }
                }
                .padding(.leading, 30)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Hinweis im Materialien-Reiter eines Moduls.
struct WueModuleBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(WueCampusSync.self) private var wue
    let module: Module

    var body: some View {
        if module.wueCourseID != nil {
            HStack(spacing: 10) {
                Image(systemName: "graduationcap.circle.fill").font(.title3).foregroundStyle(.blue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Verknüpft mit WueCampus").font(.callout.weight(.medium))
                    Text(module.wueCourseName ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if wue.isSyncing {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await wue.sync(manual: true, onlyModule: module.id) }
                    } label: { Label("Aktualisieren", systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!wue.isConnected)
                }
            }
            .card(padding: 12)
        } else if wue.isConnected {
            Button { app.sheet = .wueCourses } label: {
                Label("Mit einem WueCampus-Kurs verknüpfen", systemImage: "link")
            }
            .buttonStyle(.borderless)
        }
    }
}
