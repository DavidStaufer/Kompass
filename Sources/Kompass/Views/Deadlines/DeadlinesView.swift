import SwiftUI

struct DeadlinesView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @State private var filter: DeadlineKind?
    @State private var showDone = false

    var body: some View {
        let now = Date()
        let all = store.deadlines.filter { filter == nil || $0.kind == filter }.sorted { $0.date < $1.date }
        let open = all.filter { !$0.done }
        let overdue = open.filter { $0.date < now.startOfDay }
        let thisWeek = open.filter { $0.date >= now.startOfDay && $0.date < now.startOfWeek.adding(days: 7) }
        let next = open.filter { $0.date >= now.startOfWeek.adding(days: 7) && $0.date < now.adding(days: 35) }
        let later = open.filter { $0.date >= now.adding(days: 35) }
        let done = all.filter(\.done).reversed()

        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "Fristen", subtitle: "Klausuren, Abgaben, Präsentationen und alles mit Datum") {
                    Menu {
                        ForEach(DeadlineKind.allCases) { k in
                            Button { app.sheet = .deadline(nil, moduleID: nil, kind: k) } label: { Label(k.label, systemImage: k.symbol) }
                        }
                    } label: {
                        Label("Neue Frist", systemImage: "plus")
                    } primaryAction: {
                        app.sheet = .deadline(nil, moduleID: nil, kind: nil)
                    }
                    .fixedSize()
                }
                FlowLayout(spacing: 6) {
                    FilterChip(label: "Alle", selected: filter == nil) { filter = nil }
                    ForEach(DeadlineKind.allCases) { k in
                        FilterChip(label: k.label, symbol: k.symbol, selected: filter == k) { filter = (filter == k ? nil : k) }
                    }
                }

                if open.isEmpty && done.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Fristen", systemImage: "flag")
                    } description: {
                        Text("Trag Klausuren, Abgaben und Präsentationen ein – Kompass erinnert dich rechtzeitig über Mitteilungen, die Erinnerungen-App und deinen Kalender.")
                    } actions: {
                        Button("Frist anlegen") { app.sheet = .deadline(nil, moduleID: nil, kind: nil) }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                }

                group("Überfällig", overdue, tint: .red)
                group("Diese Woche", thisWeek)
                group("Nächste Wochen", next)
                group("Später", later)

                if !done.isEmpty {
                    DisclosureGroup(isExpanded: $showDone) {
                        VStack(spacing: 0) { ForEach(Array(done)) { DeadlineRow(deadline: $0) } }
                            .padding(.top, 6)
                    } label: {
                        Text("Erledigt (\(done.count))").scaledFont(size: 15, weight: .semibold)
                    }
                }
            }
            .pagePadding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .animation(Motion.standard, value: store.deadlines)
        .navigationTitle("Fristen")
        .inlineNavigationTitle()
    }

    @ViewBuilder
    private func group(_ title: String, _ items: [Deadline], tint: Color = .primary) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).scaledFont(size: 15, weight: .semibold).foregroundStyle(tint)
                VStack(spacing: 0) {
                    ForEach(items) { d in
                        DeadlineRow(deadline: d)
                        if d.id != items.last?.id { Divider().padding(.leading, 52) }
                    }
                }
                .card(padding: 6)
            }
        }
    }
}

struct FilterChip: View {
    var label: String
    var symbol: String?
    var selected: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).scaledFont(size: 10).accessibilityHidden(true) }
                Text(label)
            }
            .scaledFont(size: 12, weight: .medium)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(selected ? Color.accentColor : Color.subtleFill))
            .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct DeadlineRow: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    var deadline: Deadline

    var body: some View {
        let d = deadline
        let m = store.module(d.moduleID)
        HStack(spacing: 12) {
            Button {
                withAnimation(Motion.momentum) { app.toggleDeadline(d.id) }
            } label: {
                Label(d.done ? "Als offen markieren" : "Als erledigt markieren", systemImage: d.done ? "checkmark.circle.fill" : "circle")
                    .labelStyle(.iconOnly)
                    .scaledFont(size: 18)
                    .foregroundStyle(d.done ? .green : .secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .help(d.done ? "Als offen markieren" : "Als erledigt markieren")

            Button { app.sheet = .deadline(d.id, moduleID: nil, kind: nil) } label: {
                DeadlineRowContent(deadline: d, module: m)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .contextMenu {
            Button("Bearbeiten …") { app.sheet = .deadline(d.id, moduleID: nil, kind: nil) }
            Button("Zeit buchen …") { app.sheet = .logWork(LogPreset(deadlineID: d.id)) }
            if let s = d.sourceURL, let url = URL(string: s) {
                Button("In WueCampus öffnen") { Platform.open(url) }
            }
            if let m, d.kind == .klausur {
                Button("Lernplan bis zur Klausur erstellen") { app.sheet = .generator(.studyPlan, m.id, []) }
            }
            Button(d.done ? "Als offen markieren" : "Erledigt") { app.toggleDeadline(d.id) }
            Divider()
            Button("Löschen", role: .destructive) { app.deleteDeadline(d.id) }
        }
    }
}

/// Inhalt einer Fristzeile (ohne Abhak-Knopf) – Label des Bearbeiten-Buttons.
private struct DeadlineRowContent: View {
    @Environment(DataStore.self) private var store
    let deadline: Deadline
    let module: Module?

    var body: some View {
        let d = deadline
        let days = Date().daysUntil(d.date)
        HStack(spacing: 12) {
            Image(systemName: d.kind.symbol)
                .scaledFont(size: 13)
                .foregroundStyle(d.kind.tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(d.kind.tint.opacity(0.12)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(d.title).scaledFont(size: 13, weight: .semibold).strikethrough(d.done)
                HStack(spacing: 6) {
                    Text(d.kind.label)
                    if let m = module { Text("·"); ModuleDot(color: m.color.color, size: 6); Text(m.name) }
                    if !d.location.isEmpty { Text("· \(d.location)") }
                    if d.sourceKey != nil { Text("· WueCampus") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.dateTime(d.date, allDay: d.allDay)).scaledFont(size: 12, weight: .medium)
                let logged = store.logged(deadlineID: d.id)
                if logged > 0 {
                    Text("\(Fmt.jira(logged)) von \(Fmt.jira(Int(d.effectivePrepHours * 60))) vorbereitet")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.blue)
                }
                if !d.done {
                    Text(Fmt.relative(d.date))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(days < 0 ? .red : (days <= 3 ? .orange : .secondary))
                }
            }
            HStack(spacing: 3) {
                if d.eventIdentifier != nil { Image(systemName: "calendar").help("Im Kalender").accessibilityLabel("Im Kalender") }
                if d.reminderIdentifier != nil { Image(systemName: "checklist").help("In Erinnerungen").accessibilityLabel("In Erinnerungen") }
            }
            .scaledFont(size: 10).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }
}

struct DeadlineEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let deadlineID: UUID?
    let presetModule: UUID?
    let presetKind: DeadlineKind?

    @State private var d = Deadline(title: "", kind: .abgabe, date: Date().adding(days: 7).at(minutes: 23 * 60 + 59))
    @State private var loaded = false
    @State private var customOffsets = false
    @State private var confirmDelete = false

    private static let offsetChoices: [Int] = [28 * 1440, 14 * 1440, 7 * 1440, 3 * 1440, 2 * 1440, 1440, 180, 60, 15]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: deadlineID == nil ? "Neue Frist" : d.title.isEmpty ? "Frist" : d.title) { EmptyView() }
            Form {
                Picker("Art", selection: $d.kind) {
                    ForEach(DeadlineKind.allCases) { k in Label(k.label, systemImage: k.symbol).tag(k) }
                }
                .onChange(of: d.kind) { _, k in
                    if !customOffsets { d.reminderOffsets = k.defaultOffsets }
                    if k == .klausur && d.durationMinutes == 0 { d.durationMinutes = 90 }
                }
                TextField("Titel", text: $d.title, prompt: Text(placeholder))
                Picker("Modul", selection: $d.moduleID) {
                    Text("Keins").tag(UUID?.none)
                    ForEach(store.activeModules) { m in Text(m.name).tag(Optional(m.id)) }
                }
                Toggle("Ganztägig", isOn: $d.allDay)
                DatePicker("Datum", selection: $d.date, displayedComponents: d.allDay ? [.date] : [.date, .hourAndMinute])
                if d.kind == .klausur || d.kind == .praesentation || d.kind == .testat {
                    Stepper("Dauer: \(d.durationMinutes) min", value: $d.durationMinutes, in: 0...300, step: 15)
                }
                TextField("Ort / Raum", text: $d.location)
                if d.kind != .anmeldung {
                    LabeledContent("Vorbereitung") {
                        HStack {
                            Slider(value: $d.effectivePrepHours, in: 0...60, step: 1)
                            Text("\(Int(d.effectivePrepHours)) h").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                    .help("Der Wochenplaner reserviert entsprechend Lernzeit vor der Frist.")
                }
                Section("Erinnerungen") {
                    FlowLayout(spacing: 6) {
                        ForEach(Self.offsetChoices, id: \.self) { off in
                            let on = d.reminderOffsets.contains(off)
                            FilterChip(label: Fmt.offsetLabel(off) + " vorher", selected: on) {
                                customOffsets = true
                                if on { d.reminderOffsets.removeAll { $0 == off } } else { d.reminderOffsets.append(off); d.reminderOffsets.sort(by: >) }
                            }
                        }
                    }
                    Text(channels).font(.caption).foregroundStyle(.secondary)
                }
                TextField("Notizen", text: $d.notes, axis: .vertical).lineLimit(2...5)
            }
            .sheetForm()
            HStack {
                if deadlineID != nil {
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    d.title = d.title.trimmed.isEmpty ? d.kind.label : d.title.trimmed
                    if d.allDay { d.date = d.date.startOfDay }
                    app.saveDeadline(d)
                    app.showToast("\(d.kind.label) gespeichert – Erinnerungen sind eingerichtet")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .macFrame(width: 520)
        .onAppear(perform: load)
        .confirmationDialog("„\(d.title)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { app.deleteDeadline(d.id); dismiss() }
        } message: { Text("Auch Kalendereintrag, Erinnerung und Mitteilungen werden entfernt.") }
    }

    private var placeholder: String {
        switch d.kind {
        case .klausur: return "z. B. Klausur Analysis I"
        case .abgabe: return "z. B. Übungsblatt 4"
        case .praesentation: return "z. B. Referat Kapitel 3"
        case .testat: return "z. B. Praktikumstestat"
        case .anmeldung: return "z. B. Prüfungsanmeldung"
        case .sonstiges: return "Titel"
        }
    }

    private var channels: String {
        let p = store.prefs
        var c: [String] = []
        if p.notifyLocal { c.append("Mitteilungen") }
        if p.useRemindersApp { c.append("Erinnerungen-App") }
        if p.useCalendarAlarms { c.append("Kalender-Alarm (bis 3 Tage vorher)") }
        return c.isEmpty ? "Alle Erinnerungskanäle sind in den Einstellungen deaktiviert." : "Über: " + c.joined(separator: ", ")
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let deadlineID, let existing = store.deadline(deadlineID) {
            d = existing
            customOffsets = !existing.reminderOffsets.isEmpty
            if d.reminderOffsets.isEmpty { d.reminderOffsets = d.kind.defaultOffsets }
        } else {
            d.kind = presetKind ?? .abgabe
            d.moduleID = presetModule
            d.reminderOffsets = d.kind.defaultOffsets
            if d.kind == .klausur { d.date = Date().adding(days: 30).at(minutes: 10 * 60); d.durationMinutes = 90 }
        }
    }
}
