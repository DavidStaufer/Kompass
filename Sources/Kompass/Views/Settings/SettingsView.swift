import SwiftUI
import EventKit

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        #if os(macOS)
        TabView {
            GeneralSettings().tabItem { Label("Allgemein", systemImage: "person.crop.circle") }
            StudySettings().tabItem { Label("Lernzeiten", systemImage: "clock") }
            WorkSettings().tabItem { Label("Arbeit", systemImage: "briefcase") }
            TimeSettings().tabItem { Label("Zeiten", systemImage: "clock") }
            CalendarSettings().tabItem { Label("Kalender", systemImage: "calendar") }
            ReminderSettings().tabItem { Label("Erinnerungen", systemImage: "bell") }
            AISettings().tabItem { Label("KI", systemImage: "sparkles") }
            DataSettings().tabItem { Label("Daten & Sync", systemImage: "icloud") }
        }
        .frame(width: 640, height: 540)
        #else
        NavigationStack {
            List {
                Section {
                    link("Allgemein", "person.crop.circle", .gray) { GeneralSettings() }
                    link("Daten & iCloud-Sync", "icloud", .blue) { DataSettings() }
                }
                Section {
                    link("Lernzeiten", "clock", .green) { StudySettings() }
                    link("Arbeit", "briefcase", .brown) { WorkSettings() }
                    link("Zeiterfassung", "clock.badge.checkmark", .teal) { TimeSettings() }
                }
                Section {
                    link("Kalender", "calendar", .red) { CalendarSettings() }
                    link("Erinnerungen", "bell", .orange) { ReminderSettings() }
                    link("KI-Assistent", "sparkles", .indigo) { AISettings() }
                }
            }
            .navigationTitle("Einstellungen")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Fertig") { app.showSettings = false } }
            }
        }
        #endif
    }

    #if os(iOS)
    private func link<V: View>(_ title: String, _ symbol: String, _ color: Color, @ViewBuilder _ dest: () -> V) -> some View {
        NavigationLink {
            dest().navigationTitle(title).toolbarTitleDisplayMode(.inline)
        } label: {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
            }
        }
    }
    #endif
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            TextField("Dein Vorname", text: $store.prefs.userName)
            Section("Semester") {
                ForEach(store.terms.sorted { $0.start > $1.start }) { t in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(t.name).font(.body.weight(t.id == store.currentTerm?.id ? .semibold : .regular))
                            Text("\(Fmt.dayShort(t.start)) – \(Fmt.dayShort(t.end))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if t.id == store.currentTerm?.id { Pill(text: "Aktuell", color: .accentColor) }
                        else { Button("Aktivieren") { store.prefs.currentTermID = t.id } }
                        Button("Bearbeiten") { app.presentFromSettings(.term(t.id)) }
                    }
                }
                Button("Neues Semester …") { app.presentFromSettings(.term(nil)) }
            }
            Section("Archivierte Module") {
                let archived = store.modules.filter(\.archived)
                if archived.isEmpty { Text("Keine").foregroundStyle(.secondary) }
                ForEach(archived) { m in
                    HStack {
                        ModuleDot(color: m.color.color)
                        Text(m.name)
                        Text(store.term(m.termID)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Wiederherstellen") { store.updateModule(m.id) { $0.archived = false } }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StudySettings: View {
    @Environment(DataStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                DatePicker("Frühester Lernbeginn", selection: minutesBinding($store.prefs.studyDayStart), displayedComponents: .hourAndMinute)
                DatePicker("Spätestes Lernende", selection: minutesBinding($store.prefs.studyDayEnd), displayedComponents: .hourAndMinute)
                Stepper("Max. Lernzeit pro Tag: \(Fmt.hours(store.prefs.maxStudyMinutesPerDay))", value: $store.prefs.maxStudyMinutesPerDay, in: 60...720, step: 30)
                Toggle("Abends ab 19 Uhr freihalten", isOn: $store.prefs.protectedEvenings)
            } header: { Text("Lernfenster") } footer: {
                Text("Der Planer legt Lernblöcke nur in dieses Fenster – um Vorlesungen, Arbeit und Termine herum.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Blöcke") {
                Stepper("Blocklänge: \(store.prefs.blockMinutes) min", value: $store.prefs.blockMinutes, in: 25...180, step: 5)
                Stepper("Mindestlänge: \(store.prefs.minBlockMinutes) min", value: $store.prefs.minBlockMinutes, in: 15...120, step: 5)
                Stepper("Pause zwischen Blöcken: \(store.prefs.breakMinutes) min", value: $store.prefs.breakMinutes, in: 0...60, step: 5)
                Stepper("Puffer um Termine: \(store.prefs.bufferMinutes) min", value: $store.prefs.bufferMinutes, in: 0...60, step: 5)
                    .help("z. B. für Wege zur Uni oder zur Arbeit")
                Stepper("Fokus-Timer Standard: \(store.prefs.defaultFocusMinutes) min", value: $store.prefs.defaultFocusMinutes, in: 15...120, step: 5)
            }
            Section("Wochenende") {
                Toggle("Am Wochenende lernen", isOn: $store.prefs.studyOnWeekends)
                if store.prefs.studyOnWeekends {
                    Stepper("Max. pro Wochenendtag: \(Fmt.hours(store.prefs.weekendMaxMinutes))", value: $store.prefs.weekendMaxMinutes, in: 30...600, step: 30)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct WorkSettings: View {
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach($store.workBlocks) { $w in
                    WorkBlockEditorRow(block: $w) { store.workBlocks.removeAll { $0.id == w.id } }
                }
                Button { store.workBlocks.append(WorkBlock()) } label: { Label("Arbeitszeit hinzufügen", systemImage: "plus") }
            } header: { Text("Feste Arbeitszeiten") } footer: {
                Text("Wiederkehrende Werkstudenten-Zeiten. Sie blockieren den Planer und erscheinen grau im Kalender.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Arbeitskalender", selection: Binding(get: { store.prefs.workCalendarID }, set: { id in
                    store.prefs.workCalendarID = id
                    store.prefs.workCalendarTitle = id.flatMap { calendar.calendar($0)?.title }
                })) {
                    Text("Keiner").tag(String?.none)
                    ForEach(calendar.calendars, id: \.calendarIdentifier) { c in
                        Text("\(c.title) (\(c.source.title))").tag(Optional(c.calendarIdentifier))
                    }
                }
            } header: { Text("Wechselnde Schichten") } footer: {
                Text("Trägst du Schichten in einen eigenen Kalender ein? Dann wählt Kompass ihn hier aus und rechnet die Zeiten als Arbeit.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct TimeSettings: View {
    @Environment(DataStore.self) private var store
    @State private var newName = ""

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                ForEach($store.timeCategories) { $c in
                    HStack {
                        Menu {
                            ForEach(ModuleColor.allCases) { col in
                                Button { c.color = col } label: { Label(col.label, systemImage: c.color == col ? "checkmark.circle.fill" : "circle.fill") }
                            }
                        } label: { Circle().fill(c.color.color).frame(width: 12, height: 12) }
                            .plainMenu()
                        TextField("", text: $c.name)
                        Toggle("Archiviert", isOn: $c.archived).checkboxStyle()
                        Button { store.timeCategories.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                            .disabled(store.worklogs.contains { $0.categoryID == c.id })
                            .help(store.worklogs.contains { $0.categoryID == c.id } ? "Hat Buchungen – stattdessen archivieren" : "Löschen")
                    }
                }
                HStack {
                    TextField("Neue Kategorie, z. B. Sport", text: $newName).onSubmit(add)
                    Button("Hinzufügen", action: add).disabled(newName.trimmed.isEmpty)
                }
            } header: { Text("Eigene Kategorien") } footer: {
                Text("Für alles außer Studium und Arbeit – Sport, Haushalt, Ehrenamt, Nebenprojekte …").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if store.categoryRules.isEmpty { Text("Noch keine").foregroundStyle(.secondary) }
                ForEach(store.categoryRules) { r in
                    HStack {
                        Text("„\(r.title)“")
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(store.label(for: TrackTarget(kind: r.kind, moduleID: r.moduleID, categoryID: r.categoryID)).name)
                        Text(r.activity.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { store.categoryRules.removeAll { $0.key == r.key } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                    }
                }
            } header: { Text("Gemerkte Zuordnungen") } footer: {
                Text("Entstehen, wenn du einen privaten Termin bestätigst und „merken“ aktiv lässt. Solche Termine erscheinen danach automatisch unter „Noch zu bestätigen“.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Werkstudent") {
                Stepper("Max. Arbeitszeit pro Woche: \(Fmt.hours(Int(store.prefs.workWeeklyLimitHours * 60)))", value: $store.prefs.workWeeklyLimitHours, in: 0...40, step: 1)
                Toggle("Grenze nur in der Vorlesungszeit prüfen", isOn: $store.prefs.workLimitLectureOnly)
                Text("Werkstudierende dürfen in der Vorlesungszeit in der Regel max. 20 h/Woche arbeiten. Kompass warnt dich in der Zeiterfassung.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Erinnerung") {
                Toggle("Abends an unbestätigte Termine erinnern", isOn: $store.prefs.confirmReminderEnabled)
                if store.prefs.confirmReminderEnabled {
                    DatePicker("Uhrzeit", selection: minutesBinding($store.prefs.confirmReminderMinutes), displayedComponents: .hourAndMinute)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func add() {
        let n = newName.trimmed
        guard !n.isEmpty else { return }
        store.timeCategories.append(TimeCategory(name: n, color: ModuleColor.allCases.reversed()[store.timeCategories.count % ModuleColor.allCases.count]))
        newName = ""
    }
}

struct CalendarSettings: View {
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        Form {
            Section("Zugriff") {
                LabeledContent("Kalender") { status(calendar.eventsAuthorized) }
                LabeledContent("Erinnerungen") { status(calendar.remindersAuthorized) }
                if !calendar.eventsAuthorized || !calendar.remindersAuthorized {
                    Button("Zugriff anfragen") { Task { await calendar.requestAccess() } }
                    Button("Systemeinstellungen öffnen") { calendar.openPrivacySettings() }
                }
                if let c = calendar.kompassCalendar {
                    LabeledContent("Kompass-Kalender", value: "\(c.title) · \(c.source.title)")
                }
                if let e = calendar.lastError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section {
                ForEach(groupedSources, id: \.0) { source, cals in
                    Text(source).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(cals, id: \.calendarIdentifier) { c in
                        Toggle(isOn: visibility(c.calendarIdentifier)) {
                            HStack {
                                Circle().fill(Color(cgColor: c.cgColor)).frame(width: 9, height: 9)
                                Text(c.title)
                                if !c.allowsContentModifications { Text("schreibgeschützt").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            } header: { Text("In Kompass anzeigen") } footer: {
                Text("Ausgeblendete Kalender werden trotzdem bei der Planung berücksichtigt, damit nichts doppelt belegt wird.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var groupedSources: [(String, [EKCalendar])] {
        Dictionary(grouping: calendar.calendars, by: { $0.source.title }).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func visibility(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !store.prefs.hiddenCalendarIDs.contains(id) },
            set: { on in
                if on { store.prefs.hiddenCalendarIDs.removeAll { $0 == id } } else if !store.prefs.hiddenCalendarIDs.contains(id) { store.prefs.hiddenCalendarIDs.append(id) }
            }
        )
    }

    private func status(_ ok: Bool) -> some View {
        Label(ok ? "Erlaubt" : "Nicht erlaubt", systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? .green : .orange)
    }
}

struct ReminderSettings: View {
    @Environment(DataStore.self) private var store

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                Toggle("macOS-Mitteilungen", isOn: $store.prefs.notifyLocal)
                Toggle("Erinnerungen-App (iPhone & Watch)", isOn: $store.prefs.useRemindersApp)
                Toggle("Alarm am Kalendereintrag", isOn: $store.prefs.useCalendarAlarms)
            } header: { Text("Kanäle für Fristen") } footer: {
                Text("Die Vorlaufzeiten stellst du je Frist ein (Standard: Klausur 14/7/3/1 Tage, Abgabe 3/1 Tage + 3 Std.).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Lernblöcke") {
                Picker("Erinnerung vor Lernblöcken", selection: $store.prefs.blockAlarmMinutes) {
                    Text("Keine").tag(0)
                    Text("5 min").tag(5)
                    Text("10 min").tag(10)
                    Text("15 min").tag(15)
                }
            }
            Section("Überblick") {
                Toggle("Wochenrückblick am Sonntag", isOn: $store.prefs.weeklyReviewEnabled)
                if store.prefs.weeklyReviewEnabled {
                    Stepper("Um \(store.prefs.weeklyReviewHour):00 Uhr", value: $store.prefs.weeklyReviewHour, in: 8...22)
                }
                Toggle("Tagesüberblick am Morgen", isOn: $store.prefs.dailyBriefingEnabled)
                if store.prefs.dailyBriefingEnabled {
                    DatePicker("Uhrzeit", selection: minutesBinding($store.prefs.dailyBriefingMinutes), displayedComponents: .hourAndMinute)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AISettings: View {
    @Environment(DataStore.self) private var store
    @State private var key = Secrets.deepSeekKey ?? ""
    @State private var testing = false
    @State private var status: String?
    @State private var reveal = false

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                HStack {
                    if reveal { TextField("API-Key", text: $key, prompt: Text("sk-…")) } else { SecureField("API-Key", text: $key, prompt: Text("sk-…")) }
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }.buttonStyle(.borderless)
                }
                HStack {
                    Link("Key auf platform.deepseek.com erstellen ↗", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    Spacer()
                    if testing { ProgressView().controlSize(.small) }
                    Button("Speichern & testen") { save() }.disabled(testing)
                }
                if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            } header: { Text("DeepSeek") } footer: {
                Text("Der Key liegt verschlüsselt im Schlüsselbund. Materialtexte werden nur für deine Anfragen an DeepSeek gesendet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Modell") {
                Picker("Modell", selection: $store.prefs.aiModel) {
                    Text("deepseek-chat (schnell, empfohlen)").tag("deepseek-chat")
                    Text("deepseek-reasoner (denkt länger nach)").tag("deepseek-reasoner")
                    if !["deepseek-chat", "deepseek-reasoner"].contains(store.prefs.aiModel) { Text(store.prefs.aiModel).tag(store.prefs.aiModel) }
                }
                TextField("Eigener Modellname", text: $store.prefs.aiModel)
                TextField("API-Adresse", text: $store.prefs.aiBaseURL)
                LabeledContent("Kreativität") {
                    HStack { Slider(value: $store.prefs.aiTemperature, in: 0...1.3, step: 0.1); Text(String(format: "%.1f", store.prefs.aiTemperature)).monospacedDigit().frame(width: 30) }
                }
            }
            Section("Sicherheit") {
                Toggle("Vor Änderungen an fremden Kalendern nachfragen", isOn: $store.prefs.aiConfirmExternalEdits)
                Text("Löschen fragt immer nach.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        Secrets.deepSeekKey = key
        NotificationCenter.default.post(name: .kompassKeyChanged, object: nil)
        guard !key.trimmed.isEmpty, let client = DeepSeekClient.fromSettings(store.prefs) else { status = "Key entfernt."; return }
        testing = true
        status = nil
        Task {
            do {
                let r = try await client.test()
                status = "Verbunden ✓ (\(client.model) antwortet: „\(r)“)"
            } catch {
                status = (error as? AIError)?.message ?? error.localizedDescription
            }
            testing = false
        }
    }
}

struct DataSettings: View {
    @Environment(DataStore.self) private var store
    @Environment(AppModel.self) private var app
    @State private var confirmReset = false
    @State private var mode = StorageLocation.shared.mode
    @State private var picking = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                #if os(macOS)
                Toggle("In iCloud Drive speichern (mit iPhone synchronisieren)", isOn: Binding(
                    get: { mode == .iCloud },
                    set: { on in app.setMacStorage(iCloud: on); mode = StorageLocation.shared.mode }))
                    .disabled(StorageLocation.macICloudDrive == nil)
                if StorageLocation.macICloudDrive == nil {
                    Text("iCloud Drive ist auf diesem Mac nicht aktiv (Systemeinstellungen → Apple-ID → iCloud).").font(.caption).foregroundStyle(.orange)
                }
                #else
                if mode == .iCloud {
                    Label("Verbunden: \(StorageLocation.shared.displayPath)", systemImage: "checkmark.icloud.fill").foregroundStyle(.green)
                    Button("Anderen Ordner wählen …") { picking = true }
                    Button("Nur auf diesem iPhone speichern", role: .destructive) { app.useLocalStorage(); mode = StorageLocation.shared.mode }
                } else {
                    Text("Wähle in iCloud Drive den Ordner „Kompass“, den dein Mac angelegt hat – dann teilen iPhone und Mac dieselben Module, Materialien, Zeiten und Karteikarten.")
                        .font(.callout)
                    Button { picking = true } label: { Label("iCloud-Ordner verbinden …", systemImage: "icloud.and.arrow.down") }
                }
                #endif
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
                if let problem = StorageLocation.shared.problem { Text(problem).font(.caption).foregroundStyle(.orange) }
                if let t = store.lastRemoteSync {
                    LabeledContent("Zuletzt Änderungen übernommen", value: "\(Fmt.dayShort(t)), \(Fmt.time(t))")
                }
            } header: { Text("Synchronisierung") } footer: {
                Text("Termine, Fristen und Erinnerungen laufen zusätzlich über Apple Kalender und Erinnerungen (iCloud). Änderungen auf beiden Geräten werden zusammengeführt.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Speicherort") {
                LabeledContent("Ordner", value: StorageLocation.shared.displayPath)
                HStack {
                    #if os(macOS)
                    Button("Im Finder zeigen") { Platform.reveal(Paths.dataFile) }
                    #endif
                    Button("Jetzt sichern") {
                        store.saveNow()
                        let url = Paths.backups.appendingPathComponent("kompass-manuell-\(Int(Date().timeIntervalSince1970)).json")
                        try? FileManager.default.copyItem(at: Paths.dataFile, to: url)
                    }
                }
                Text("Kompass legt täglich automatisch eine Sicherung an (die letzten 30 bleiben erhalten).").font(.caption).foregroundStyle(.secondary)
            }
            Section("Statistik") {
                LabeledContent("Module", value: "\(store.modules.count)")
                LabeledContent("Materialien", value: "\(store.modules.reduce(0) { $0 + $1.materials.count })")
                LabeledContent("Karteikarten", value: "\(store.flashcards.count)")
                LabeledContent("Selbststudium gesamt", value: Fmt.hours(store.minutes(from: .distantPast, to: .distantFuture)))
                LabeledContent("Zeitbuchungen", value: "\(store.worklogs.count)")
            }
            Section {
                Button("Einrichtung erneut starten") {
                    store.prefs.onboardingDone = false
                    AppModel.shared.presentFromSettings(.onboarding)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                message = app.useStorageFolder(url)
                mode = StorageLocation.shared.mode
            }
        }
    }
}

/// Zeile für einen festen Arbeitsblock – nebeneinander auf dem Mac, zweizeilig auf dem iPhone.
struct WorkBlockEditorRow: View {
    @Binding var block: WorkBlock
    var onDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                weekday.frame(width: 130)
                times
                TextField("Bezeichnung", text: $block.label).frame(width: 110)
                deleteButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { weekday; Spacer(); deleteButton }
                times
            }
        }
    }

    private var weekday: some View {
        Picker("", selection: $block.weekday) { ForEach(1...7, id: \.self) { Text(Fmt.weekday($0)).tag($0) } }.labelsHidden()
    }
    private var times: some View {
        HStack {
            DatePicker("", selection: minutesBinding($block.startMinutes), displayedComponents: .hourAndMinute).labelsHidden()
            Text("–")
            DatePicker("", selection: minutesBinding($block.endMinutes), displayedComponents: .hourAndMinute).labelsHidden()
        }
    }
    private var deleteButton: some View {
        Button(action: onDelete) { Image(systemName: "minus.circle.fill").foregroundStyle(.secondary) }
            .buttonStyle(.borderless)
    }
}
