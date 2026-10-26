import SwiftUI
import EventKit

struct EventEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(\.dismiss) private var dismiss

    let eventID: String?
    @State private var title = ""
    @State private var start: Date
    @State private var end: Date
    @State private var allDay = false
    @State private var calendarID: String?
    @State private var moduleID: UUID?
    @State private var location = ""
    @State private var notes = ""
    @State private var alarm = 0
    @State private var repeatWeekly = false
    @State private var asStudyBlock = false
    @State private var futureEvents = false
    @State private var isRecurring = false
    @State private var loaded = false
    @State private var error: String?
    @State private var confirmDelete = false

    init(eventID: String?, start: Date, end: Date, moduleID: UUID?) {
        self.eventID = eventID
        _start = State(initialValue: start)
        _end = State(initialValue: end)
        _moduleID = State(initialValue: moduleID)
    }

    private var isNew: Bool { eventID == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: isNew ? "Neuer Termin" : "Termin bearbeiten") { EmptyView() }
            Form {
                TextField("Titel", text: $title, prompt: Text("z. B. Lerngruppe Analysis"))
                Toggle("Ganztägig", isOn: $allDay)
                DatePicker("Beginn", selection: $start, displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                    .onChange(of: start) { old, new in end = end.addingTimeInterval(new.timeIntervalSince(old)) }
                DatePicker("Ende", selection: $end, in: start..., displayedComponents: allDay ? [.date] : [.date, .hourAndMinute])
                Picker("Kalender", selection: $calendarID) {
                    ForEach(calendar.editableCalendars, id: \.calendarIdentifier) { c in
                        HStack { Circle().fill(Color(cgColor: c.cgColor)).frame(width: 8, height: 8); Text(c.title) }
                            .tag(Optional(c.calendarIdentifier))
                    }
                }
                Picker("Modul", selection: $moduleID) {
                    Text("Keins").tag(UUID?.none)
                    ForEach(store.activeModules) { m in Text(m.name).tag(Optional(m.id)) }
                }
                if isNew && moduleID != nil {
                    Toggle("Als Lernblock zählen", isOn: $asStudyBlock)
                        .help("Lernblöcke fließen in Fortschritt und Wochenrückblick ein.")
                }
                TextField("Ort", text: $location)
                Picker("Erinnerung", selection: $alarm) {
                    Text("Keine").tag(0)
                    Text("5 Minuten vorher").tag(5)
                    Text("15 Minuten vorher").tag(15)
                    Text("30 Minuten vorher").tag(30)
                    Text("1 Stunde vorher").tag(60)
                    Text("1 Tag vorher").tag(1440)
                }
                if isNew {
                    Toggle("Wöchentlich wiederholen", isOn: $repeatWeekly)
                } else if isRecurring {
                    Picker("Änderung gilt für", selection: $futureEvents) {
                        Text("Nur diesen Termin").tag(false)
                        Text("Alle zukünftigen").tag(true)
                    }
                }
                TextField("Notizen", text: $notes, axis: .vertical).lineLimit(3...6)
            }
            .sheetForm()
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                if !isNew {
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Erstellen" : "Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(title.trimmed.isEmpty)
            }
        }
        .padding(20)
        .macFrame(width: 480)
        .onAppear(perform: load)
        .confirmationDialog("Termin löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { delete() }
        } message: { Text("Der Termin wird aus Apple Kalender entfernt.") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        calendarID = calendar.kompassCalendar?.calendarIdentifier ?? calendar.editableCalendars.first?.calendarIdentifier
        guard let eventID, let e = calendar.ekEvent(id: eventID) else { return }
        title = e.title ?? ""
        start = e.startDate
        end = e.endDate
        allDay = e.isAllDay
        calendarID = e.calendar?.calendarIdentifier
        location = e.location ?? ""
        notes = e.notes ?? ""
        alarm = Int(-(e.alarms?.first?.relativeOffset ?? 0) / 60)
        isRecurring = e.hasRecurrenceRules
        moduleID = KompassLink(url: e.url)?.moduleID
    }

    private func save() {
        do {
            if let eventID {
                guard let e = calendar.ekEvent(id: eventID) else { throw CalendarError.notFound }
                e.title = title.trimmed
                e.isAllDay = allDay
                e.startDate = allDay ? start.startOfDay : start
                e.endDate = allDay ? end.startOfDay : end
                e.location = location.nilIfEmpty
                e.notes = notes.nilIfEmpty
                if let calendarID, let c = calendar.calendar(calendarID), c.calendarIdentifier != e.calendar?.calendarIdentifier { e.calendar = c }
                e.alarms = alarm > 0 ? [EKAlarm(relativeOffset: -Double(alarm) * 60)] : nil
                var link = KompassLink(url: e.url)
                if let moduleID {
                    if link == nil { link = KompassLink(kind: .event, moduleID: moduleID) } else { link?.moduleID = moduleID }
                } else if link?.kind == .event { link = nil }
                e.url = link?.url
                try calendar.save(e, span: futureEvents ? .futureEvents : .thisEvent)
                app.sync.reconcile()
            } else {
                var d = CalendarService.EventDraft(title: title.trimmed, start: start, end: end)
                d.allDay = allDay
                d.calendarID = calendarID
                d.location = location
                d.notes = notes
                d.alarmMinutes = alarm > 0 ? [alarm] : []
                let blockID = UUID()
                if let moduleID {
                    d.link = asStudyBlock ? KompassLink(kind: .block, id: blockID, moduleID: moduleID) : KompassLink(kind: .event, moduleID: moduleID)
                }
                if repeatWeekly {
                    d.recurrence = EKRecurrenceRule(recurrenceWith: .weekly, interval: 1, end: store.currentTerm.map { EKRecurrenceEnd(end: $0.end) })
                }
                let e = try calendar.create(d)
                if asStudyBlock, let moduleID, !repeatWeekly {
                    store.blocks.append(PlannedBlock(id: blockID, moduleID: moduleID, start: start, end: end, eventIdentifier: e.eventIdentifier))
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete() {
        guard let eventID, let e = calendar.ekEvent(id: eventID) else { dismiss(); return }
        do {
            try calendar.deleteEvent(e, futureEvents: futureEvents)
            app.sync.reconcile()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
