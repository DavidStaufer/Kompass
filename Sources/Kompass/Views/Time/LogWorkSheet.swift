import SwiftUI

/// Bezug einer Buchung – wie ein Jira-Ticket.
enum TicketRef: Hashable {
    case none, task(UUID), deadline(UUID)
}

/// „Zeit buchen“ – angelehnt an Jiras „Log work“.
struct LogWorkSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let preset: LogPreset

    @State private var target: TrackTarget = .work
    @State private var activity: ActivityKind = .arbeit
    @State private var durationText = "1h"
    @State private var start = Date().adding(minutes: -60)
    @State private var ticket: TicketRef = .none
    @State private var note = ""
    @State private var newEstimate: Int?
    @State private var loaded = false
    @State private var newCategoryName = ""
    @State private var showNewCategory = false
    @State private var confirmDelete = false

    private var editing: Worklog? { preset.worklogID.flatMap { id in store.worklogs.first { $0.id == id } } }
    private var minutes: Int? { Fmt.parseDuration(durationText) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: editing == nil ? "Zeit buchen" : "Buchung bearbeiten",
                        subtitle: editing.map { "\($0.source.label) · erstellt \(Fmt.dayShort($0.createdAt))" }) { EmptyView() }
            Form {
                Section {
                    LabeledContent("Wofür") {
                        HStack {
                            Picker("Wofür", selection: $target) {
                                Section("Studium") {
                                    ForEach(moduleTargets, id: \.self) { t in Text(store.label(for: t).name).tag(t) }
                                }
                                Section("Arbeit") { Text("Arbeit").tag(TrackTarget.work) }
                                if !store.timeCategories.filter({ !$0.archived }).isEmpty {
                                    Section("Andere") {
                                        ForEach(store.timeCategories.filter { !$0.archived }) { c in Text(c.name).tag(TrackTarget.custom(c.id)) }
                                    }
                                }
                            }
                            .labelsHidden()
                            Button { showNewCategory = true } label: { Label("Neue Kategorie", systemImage: "plus").labelStyle(.iconOnly) }
                                .help("Neue Kategorie (z. B. Sport, Haushalt)")
                                .popover(isPresented: $showNewCategory) { newCategoryPopover.compactPopover() }
                        }
                    }
                    .onChange(of: target) { old, new in
                        if old.kind != new.kind { activity = ActivityKind.defaultFor(new.kind) }
                        if case .task(let id) = ticket, let t = store.tasks.first(where: { $0.id == id }), t.moduleID != nil, t.moduleID != new.moduleID { ticket = .none }
                    }
                    Picker("Art", selection: $activity) {
                        ForEach(activities) { a in Label(a.label, systemImage: a.symbol).tag(a) }
                    }
                }
                Section {
                    LabeledContent("Erfasste Zeit") {
                        VStack(alignment: .trailing, spacing: 2) {
                            TextField("Erfasste Zeit", text: $durationText, prompt: Text("z. B. 1h 30m"))
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 160)
                            Text(minutes.map { "= \(Fmt.duration($0))" } ?? "Format: 2h 30m · 45m · 1,5h · 1:30")
                                .font(.caption)
                                .foregroundStyle(minutes == nil ? .orange : .secondary)
                        }
                    }
                    DatePicker("Beginn", selection: $start)
                    if let minutes {
                        LabeledContent("Ende", value: "\(Fmt.dayShort(start.adding(minutes: minutes))), \(Fmt.time(start.adding(minutes: minutes)))")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Aufgabe / Frist (optional)") {
                    Picker("Bezug", selection: $ticket) {
                        Text("Keiner").tag(TicketRef.none)
                        if !ticketTasks.isEmpty {
                            Section("Aufgaben") { ForEach(ticketTasks) { t in Text(t.title).tag(TicketRef.task(t.id)) } }
                        }
                        if !ticketDeadlines.isEmpty {
                            Section("Fristen") { ForEach(ticketDeadlines) { d in Text("\(d.kind.label): \(d.title)").tag(TicketRef.deadline(d.id)) } }
                        }
                    }
                    ticketInfo
                }
                Section {
                    TextField("Beschreibung", text: $note, prompt: Text("Woran hast du gearbeitet?"), axis: .vertical).lineLimit(2...5)
                }
            }
            .sheetForm()
            .macFrame(height: 430)
            HStack {
                if editing != nil {
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(editing == nil ? "Buchen" : "Sichern", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(minutes == nil)
            }
        }
        .padding(20)
        .macFrame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog("Buchung löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) {
                if let e = editing {
                    store.worklogs.removeAll { $0.id == e.id }
                    if let bid = e.blockID, let i = store.blocks.firstIndex(where: { $0.id == bid }) { store.blocks[i].status = .planned }
                }
                dismiss()
            }
        }
    }

    // MARK: Teile

    private var moduleTargets: [TrackTarget] {
        var mods = store.activeModules.map { TrackTarget.module($0.id) }
        if target.kind == .module, !mods.contains(target) { mods.append(target) }
        return mods
    }

    private var activities: [ActivityKind] {
        switch target.kind {
        case .module: return [.lernen, .vorlesung, .uebung, .tutorium, .seminar, .praktikum, .pruefung, .sonstiges]
        case .work: return [.arbeit, .sonstiges]
        case .custom: return [.sonstiges, .lernen, .arbeit]
        }
    }

    private var ticketTasks: [TaskItem] {
        store.tasks.filter { t in
            (!t.done || ticket == .task(t.id)) && (target.kind != .module || t.moduleID == nil || t.moduleID == target.moduleID)
        }
    }

    private var ticketDeadlines: [Deadline] {
        store.deadlines.filter { d in
            (!d.done || ticket == .deadline(d.id)) && d.kind != .anmeldung && (target.kind != .module || d.moduleID == nil || d.moduleID == target.moduleID)
        }.sorted { $0.date < $1.date }
    }

    @ViewBuilder
    private var ticketInfo: some View {
        let own = editing?.minutes ?? 0
        switch ticket {
        case .task(let id):
            if let t = store.tasks.first(where: { $0.id == id }) {
                let logged = store.logged(taskID: id) - own + (minutes ?? 0)
                TimeTrackingBar(estimate: newEstimate ?? t.estimateMinutes, logged: logged)
                Stepper("Schätzung: \(Fmt.jira(newEstimate ?? t.estimateMinutes))",
                        value: Binding(get: { newEstimate ?? t.estimateMinutes }, set: { newEstimate = max(0, $0) }), step: 15)
            }
        case .deadline(let id):
            if let d = store.deadline(id) {
                let logged = store.logged(deadlineID: id) - own + (minutes ?? 0)
                TimeTrackingBar(estimate: Int(d.effectivePrepHours * 60), logged: logged)
            }
        case .none:
            EmptyView()
        }
    }

    private var newCategoryPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Neue Kategorie").font(.headline)
            TextField("z. B. Sport, Haushalt, Nebenprojekt", text: $newCategoryName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addCategory)
            HStack {
                Spacer()
                Button("Anlegen", action: addCategory).buttonStyle(.borderedProminent).disabled(newCategoryName.trimmed.isEmpty)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func addCategory() {
        let name = newCategoryName.trimmed
        guard !name.isEmpty else { return }
        let used = Set(store.timeCategories.map(\.color))
        let c = TimeCategory(name: name, color: [.teal, .pink, .mint, .brown, .cyan, .yellow, .indigo].first { !used.contains($0) } ?? .teal)
        store.timeCategories.append(c)
        target = .custom(c.id)
        newCategoryName = ""
        showNewCategory = false
    }

    // MARK: Laden & Sichern

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let e = editing {
            target = TrackTarget(e)
            activity = e.activity
            durationText = Fmt.jira(e.minutes)
            start = e.start
            note = e.note
            ticket = e.taskID.map { .task($0) } ?? e.deadlineID.map { .deadline($0) } ?? .none
            return
        }
        if let t = preset.taskID, let task = store.tasks.first(where: { $0.id == t }) {
            ticket = .task(t)
            if preset.target == nil, let m = task.moduleID { target = .module(m) }
        }
        if let d = preset.deadlineID, let dl = store.deadline(d) {
            ticket = .deadline(d)
            if preset.target == nil, let m = dl.moduleID { target = .module(m) }
        }
        if let t = preset.target { target = t } else if case .none = ticket { target = store.trackTargets.first ?? .work }
        activity = preset.activity ?? ActivityKind.defaultFor(target.kind)
        let mins = preset.minutes ?? 60
        durationText = Fmt.jira(mins)
        start = preset.start ?? Date().adding(minutes: -mins)
        note = preset.eventKey == nil ? (preset.title ?? "") : ""
    }

    private func save() {
        guard let minutes else { return }
        var taskID: UUID?, deadlineID: UUID?
        switch ticket {
        case .task(let id): taskID = id
        case .deadline(let id): deadlineID = id
        case .none: break
        }
        if let id = taskID, let est = newEstimate { store.updateTask(id) { $0.estimateMinutes = est } }
        if let e = editing {
            store.updateWorklog(e.id) { w in
                w.kind = target.kind
                w.moduleID = target.moduleID
                w.categoryID = target.categoryID
                w.activity = activity
                w.minutes = minutes
                w.start = start
                w.note = note.trimmed
                w.taskID = taskID
                w.deadlineID = deadlineID
            }
            app.showToast("Buchung gespeichert")
        } else {
            store.logWork(target, activity: activity, start: start, minutes: minutes, source: preset.source ?? .manual,
                          note: note.trimmed, title: preset.title ?? "", taskID: taskID, deadlineID: deadlineID,
                          blockID: preset.blockID, eventKey: preset.eventKey)
            if let bid = preset.blockID, let i = store.blocks.firstIndex(where: { $0.id == bid }) {
                store.blocks[i].status = minutes >= store.blocks[i].minutes / 2 ? .done : .partial
            }
            app.showToast("\(Fmt.duration(minutes)) auf \(store.label(for: target).name) gebucht", symbol: "clock.badge.checkmark")
        }
        dismiss()
    }
}

/// Jira-artige Zeiterfassungs-Leiste: erfasst (blau) vs. Schätzung, Überschreitung orange.
struct TimeTrackingBar: View {
    var estimate: Int
    var logged: Int
    var compact = false

    var body: some View {
        let total = max(estimate, logged, 1)
        let remaining = max(0, estimate - logged)
        let over = max(0, logged - estimate)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.blue).frame(width: geo.size.width * CGFloat(min(logged, estimate > 0 ? estimate : logged)) / CGFloat(total))
                    if over > 0 && estimate > 0 {
                        Rectangle().fill(Color.orange).frame(width: geo.size.width * CGFloat(over) / CGFloat(total))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.1))
                .clipShape(Capsule())
            }
            .frame(height: compact ? 4 : 6)
            if !compact {
                HStack(spacing: 10) {
                    Text("Geschätzt \(estimate > 0 ? Fmt.jira(estimate) : "–")")
                    Text("Erfasst \(Fmt.jira(logged))").foregroundStyle(.blue)
                    if over > 0 && estimate > 0 {
                        Text("\(Fmt.jira(over)) über Schätzung").foregroundStyle(.orange)
                    } else {
                        Text("Verbleibend \(Fmt.jira(remaining))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}
