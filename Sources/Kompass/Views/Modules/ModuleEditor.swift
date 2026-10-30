import SwiftUI

struct ModuleEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let moduleID: UUID?

    @State private var m = Module(name: "")
    @State private var goalTouched = false
    @State private var addExam = false
    @State private var examDate = Date().adding(days: 100).at(minutes: 10 * 60)
    @State private var loaded = false
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: moduleID == nil ? "Neues Modul" : "Modul bearbeiten") { EmptyView() }
            Form {
                    Section {
                        TextField("Name", text: $m.name, prompt: Text("z. B. Analysis I"))
                        TextField("Kürzel", text: $m.code, prompt: Text("optional, z. B. ANA1"))
                        LabeledContent("Farbe") {
                            FlowLayout(spacing: 6) {
                                ForEach(ModuleColor.allCases) { c in
                                    Button { m.color = c } label: {
                                        Circle().fill(c.color).frame(width: 18, height: 18)
                                            .overlay(Circle().strokeBorder(Color.primary.opacity(m.color == c ? 0.8 : 0), lineWidth: 2).padding(-3))
                                    }
                                    .buttonStyle(.pressable)
                                    .help(c.label)
                                }
                            }
                        }
                        Stepper("ECTS: \(m.ects.formatted())", value: $m.ects, in: 0...30, step: 1)
                            .onChange(of: m.ects) { _, v in if !goalTouched { m.weeklyGoalHours = Module.suggestedWeeklyHours(ects: v) } }
                        LabeledContent("Selbststudium pro Woche") {
                            Stepper("\(m.weeklyGoalHours.formatted()) h", value: Binding(get: { m.weeklyGoalHours }, set: { m.weeklyGoalHours = $0; goalTouched = true }), in: 0...30, step: 0.5)
                        }
                        .help("Richtwert: ca. 1 ECTS ≈ 30 h Arbeit pro Semester. Der Planer verteilt diese Zeit jede Woche.")
                        TextField("Dozent/in", text: $m.lecturer)
                        Picker("Semester", selection: $m.termID) {
                            Text("Ohne Semester").tag(UUID?.none)
                            ForEach(store.terms) { t in Text(t.name).tag(Optional(t.id)) }
                        }
                    }
                    Section {
                        ForEach($m.sessions) { $s in
                            SessionEditorRow(session: $s) { m.sessions.removeAll { $0.id == s.id } }
                        }
                        Button {
                            m.sessions.append(CourseSession(kind: m.sessions.isEmpty ? .vorlesung : .uebung))
                        } label: { Label("Veranstaltung hinzufügen", systemImage: "plus") }
                    } header: {
                        Text("Wöchentliche Veranstaltungen")
                    } footer: {
                        Text("Werden als Serie bis zum Vorlesungsende in Apple Kalender eingetragen.").font(.caption).foregroundStyle(.secondary)
                    }
                    if moduleID == nil {
                        Section("Klausur") {
                            Toggle("Klausurtermin schon bekannt", isOn: $addExam)
                            if addExam {
                                DatePicker("Termin", selection: $examDate, displayedComponents: [.date, .hourAndMinute])
                            }
                        }
                    }
                    Section("Notizen") {
                        TextField("z. B. Bonuspunkte, Zulassungsvoraussetzungen …", text: $m.notes, axis: .vertical).lineLimit(2...6)
                    }
                }
                .sheetForm()
            .macFrame(height: 540)
            HStack {
                if moduleID != nil {
                    Button("Löschen …", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(moduleID == nil ? "Anlegen" : "Sichern", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(m.name.trimmed.isEmpty)
            }
        }
        .padding(20)
        .macFrame(width: 600)
        .onAppear(perform: load)
        .confirmationDialog("„\(m.name)“ löschen?", isPresented: $confirmDelete) {
            Button("Modul löschen", role: .destructive) {
                for s in m.sessions { app.sync.removeSession(s) }
                for b in store.blocks where b.moduleID == m.id && b.status == .planned { app.sync.removeBlock(b) }
                store.deleteModule(m.id)
                app.selection = .today
                dismiss()
            }
        } message: {
            Text("Materialien, Karteikarten, Quizze, Dokumente und Lernzeiten dieses Moduls werden gelöscht. Tipp: Archivieren behält alles für später.")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let moduleID, let existing = store.module(moduleID) {
            m = existing
            goalTouched = true
        } else {
            m.termID = store.currentTerm?.id
            let used = Set(store.activeModules.map(\.color))
            m.color = ModuleColor.allCases.first { !used.contains($0) } ?? .blue
            m.weeklyGoalHours = Module.suggestedWeeklyHours(ects: m.ects)
            if let t = store.currentTerm { examDate = (t.lectureEnd ?? t.end).adding(days: 10).at(minutes: 10 * 60) }
        }
    }

    private func save() {
        m.name = m.name.trimmed
        m.code = m.code.trimmed
        if let moduleID, let old = store.module(moduleID) {
            let keep = Set(m.sessions.map(\.id))
            for s in old.sessions where !keep.contains(s.id) { app.sync.removeSession(s) }
            store.updateModule(moduleID) { $0 = m }
            app.sync.syncSessions(moduleID: moduleID)
            // Titel von Fristen-Terminen aktualisieren (Kürzel könnte sich geändert haben)
            if old.code != m.code || old.name != m.name {
                for d in store.deadlines where d.moduleID == moduleID { app.sync.sync(deadlineID: d.id) }
            }
        } else {
            store.modules.append(m)
            app.sync.syncSessions(moduleID: m.id)
            if addExam {
                app.saveDeadline(Deadline(title: "Klausur \(m.name)", kind: .klausur, moduleID: m.id, date: examDate, durationMinutes: 90,
                                          reminderOffsets: DeadlineKind.klausur.defaultOffsets))
            }
            app.openModule(m.id, tab: .overview)
            app.showToast("Modul „\(m.name)“ angelegt")
        }
        dismiss()
    }
}

struct SessionEditorRow: View {
    @Binding var session: CourseSession
    var onDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                kind.frame(width: 110)
                weekday.frame(width: 64)
                times
                TextField("Raum", text: $session.room).frame(width: 80)
                biweekly
                deleteButton
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack { kind; weekday; Spacer(); deleteButton }
                times
                HStack { TextField("Raum", text: $session.room); biweekly }
            }
        }
    }

    private var kind: some View {
        Picker("Art", selection: $session.kind) { ForEach(SessionKind.allCases) { Text($0.label).tag($0) } }.labelsHidden()
    }
    private var weekday: some View {
        Picker("Wochentag", selection: $session.weekday) { ForEach(1...7, id: \.self) { Text(Fmt.weekday($0, short: true)).tag($0) } }.labelsHidden()
    }
    private var times: some View {
        HStack {
            DatePicker("Beginn", selection: minutesBinding($session.startMinutes), displayedComponents: .hourAndMinute).labelsHidden()
                .onChange(of: session.startMinutes) { old, new in
                    if session.endMinutes <= new { session.endMinutes = new + 90 }
                    else if old < session.endMinutes { session.endMinutes = min(24 * 60 - 1, session.endMinutes + (new - old)) }
                }
            Text("–").accessibilityHidden(true)
            DatePicker("Ende", selection: minutesBinding($session.endMinutes), displayedComponents: .hourAndMinute).labelsHidden()
        }
    }
    private var biweekly: some View {
        Toggle("14-tägl.", isOn: $session.biweekly).checkboxStyle().fixedSize()
    }
    private var deleteButton: some View {
        Button(role: .destructive, action: onDelete) {
            Label("Termin entfernen", systemImage: "minus.circle.fill").labelStyle(.iconOnly).foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Kleinere Editoren

struct TaskEditor: View {
    @Environment(DataStore.self) private var store
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let taskID: UUID?
    let moduleID: UUID?
    @State private var t = TaskItem(title: "")
    @State private var hasDue = true
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: taskID == nil ? "Neue Aufgabe" : "Aufgabe") { EmptyView() }
            Form {
                TextField("Titel", text: $t.title, prompt: Text("z. B. Übungsblatt 5 rechnen"))
                Picker("Modul", selection: $t.moduleID) {
                    Text("Keins").tag(UUID?.none)
                    ForEach(store.activeModules) { m in Text(m.name).tag(Optional(m.id)) }
                }
                Toggle("Fällig", isOn: $hasDue)
                if hasDue {
                    DatePicker("Bis", selection: Binding(get: { t.due ?? Date().endOfDay.adding(minutes: -1) }, set: { t.due = $0 }), displayedComponents: [.date, .hourAndMinute])
                }
                Stepper("Geschätzt: \(Fmt.duration(t.estimateMinutes))", value: $t.estimateMinutes, in: 0...6000, step: 15)
                if taskID != nil {
                    LabeledContent("Zeiterfassung") {
                        VStack(alignment: .trailing, spacing: 6) {
                            TimeTrackingBar(estimate: t.estimateMinutes, logged: store.logged(taskID: t.id)).frame(width: 260)
                            Button("Zeit buchen …") {
                                if let i = store.tasks.firstIndex(where: { $0.id == t.id }) { store.tasks[i] = t }
                                app.sheet = .logWork(LogPreset(taskID: t.id))
                            }
                            .controlSize(.small)
                        }
                    }
                }
                TextField("Notizen", text: $t.notes, axis: .vertical).lineLimit(2...5)
            }
            .sheetForm()
            HStack {
                if taskID != nil {
                    Button("Löschen", role: .destructive) { store.tasks.removeAll { $0.id == t.id }; dismiss() }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    if !hasDue { t.due = nil } else if t.due == nil { t.due = Date().endOfDay.adding(minutes: -1) }
                    t.title = t.title.trimmed
                    if let i = store.tasks.firstIndex(where: { $0.id == t.id }) { store.tasks[i] = t } else { store.tasks.append(t) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(t.title.trimmed.isEmpty)
            }
        }
        .padding(20).macFrame(width: 460)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let taskID, let existing = store.tasks.first(where: { $0.id == taskID }) { t = existing; hasDue = existing.due != nil }
            else { t.moduleID = moduleID; t.due = Date().endOfDay.adding(minutes: -1) }
        }
    }
}

struct TermEditor: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let termID: UUID?
    @State private var t = Term.suggested()
    @State private var hasLectureEnd = true
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: termID == nil ? "Neues Semester" : "Semester bearbeiten") { EmptyView() }
            Form {
                TextField("Name", text: $t.name, prompt: Text("z. B. WiSe 26/27"))
                DatePicker("Beginn", selection: $t.start, displayedComponents: .date)
                DatePicker("Ende", selection: $t.end, in: t.start..., displayedComponents: .date)
                Toggle("Vorlesungsende angeben", isOn: $hasLectureEnd)
                if hasLectureEnd {
                    DatePicker("Vorlesungsende", selection: $t.lectureEndOrEnd, in: t.start...t.end, displayedComponents: .date)
                }
            }
            .sheetForm()
            Text("Module, Fristen und Lernzeiten bleiben semesterübergreifend erhalten. Über die Seitenleiste wechselst du zwischen Semestern.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let termID, store.terms.count > 1 {
                    Button("Löschen", role: .destructive) {
                        store.terms.removeAll { $0.id == termID }
                        for i in store.modules.indices where store.modules[i].termID == termID { store.modules[i].termID = nil }
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    if !hasLectureEnd { t.lectureEnd = nil }
                    if let i = store.terms.firstIndex(where: { $0.id == t.id }) { store.terms[i] = t } else { store.terms.append(t) }
                    store.prefs.currentTermID = t.id
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(t.name.trimmed.isEmpty)
            }
        }
        .padding(20).macFrame(width: 440)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let termID, let existing = store.term(termID) { t = existing; hasLectureEnd = existing.lectureEnd != nil }
            else if let last = store.terms.sorted(by: { $0.end > $1.end }).first {
                t = Term.suggested(for: last.end.adding(days: 2))
            }
        }
    }
}
