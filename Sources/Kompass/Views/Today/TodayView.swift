import SwiftUI

struct TodayView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !calendar.eventsAuthorized { CalendarAccessCard() }
                if showReviewBanner { WeekReviewBanner() }
                ConfirmCard()
                if store.activeModules.isEmpty { FirstStepsCard() }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { AgendaCard(); TasksCard() }
                            .frame(minWidth: 400)
                        VStack(spacing: 20) { DeadlineCountdownCard(); WeekProgressCard() }
                            .frame(width: 330)
                    }
                    VStack(spacing: 20) {
                        AgendaCard(); DeadlineCountdownCard(); TasksCard(); WeekProgressCard()
                    }
                }
            }
            .pagePadding()
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Heute")
        .inlineNavigationTitle()
    }

    private var header: some View {
        let h = Date().minutesSinceMidnight / 60
        let greet = h < 11 ? "Guten Morgen" : (h < 17 ? "Hallo" : "Guten Abend")
        let name = store.prefs.userName.isEmpty ? "" : ", \(store.prefs.userName)"
        return PageTitle(title: "\(greet)\(name)", subtitle: "\(Fmt.dayLong(Date())) · KW \(Date().weekNumber)")
    }

    private var showReviewBanner: Bool {
        let now = Date()
        let isSunday = now.isoWeekday == 7
        let isMondayMorning = now.isoWeekday == 1 && now.minutesSinceMidnight < 12 * 60
        guard isSunday || isMondayMorning else { return false }
        let reviewWeek = isSunday ? now.startOfWeek : now.startOfWeek.adding(weeks: -1)
        return store.prefs.lastReviewDismissedWeek.map { !$0.isSameDay(reviewWeek) } ?? true
    }
}

// MARK: - Karten

struct CalendarAccessCard: View {
    @Environment(CalendarService.self) private var calendar
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { icon; text; Spacer(); button }
            VStack(alignment: .leading, spacing: 10) { HStack(alignment: .top, spacing: 12) { icon; text }; button }
        }
        .card()
    }

    private var icon: some View {
        Image(systemName: "calendar.badge.exclamationmark").scaledFont(size: 26).foregroundStyle(.orange)
            .accessibilityHidden(true)
    }
    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Kalenderzugriff fehlt").font(.headline)
            Text("Ohne Zugriff kann Kompass deine Woche nicht mit Apple Kalender abgleichen.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var button: some View {
        Button("Zugriff erlauben") {
            if calendar.eventStatus == .notDetermined { Task { await calendar.requestAccess() } } else { calendar.openPrivacySettings() }
        }
        .buttonStyle(.borderedProminent)
    }
}

struct FirstStepsCard: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Los geht's", symbol: "sparkles")
            Text("Lege deine Module an – mit Vorlesungszeiten, Klausurterminen und Materialien. Den Rest plant Kompass mit dir.")
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                Button { app.sheet = .newModule } label: { Label("Erstes Modul anlegen", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                Button { app.assistant.ask("Hilf mir, mein Semester einzurichten. Frag mich nach meinen Modulen, Vorlesungszeiten, Klausuren und Arbeitszeiten und trag alles ein.", scope: nil) } label: {
                    Label("Mit dem Assistenten einrichten", systemImage: "sparkles")
                }
            }
        }
        .card()
    }
}

struct WeekReviewBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        let ws = Date().isoWeekday == 7 ? Date().startOfWeek : Date().startOfWeek.adding(weeks: -1)
        let r = WeekReport.make(weekStart: ws, store: store, calendar: calendar)
        let info = HStack(spacing: 14) {
            ProgressRing(value: r.completion, color: .accentColor, lineWidth: 6, size: 58, showLabel: true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Wochenrückblick KW \(ws.weekNumber)").scaledFont(size: 16, weight: .semibold)
                Text("\(Fmt.hours(r.totalLogged)) von \(Fmt.hours(r.totalGoal)) gelernt · \(r.tasksDone.count) Aufgaben erledigt · \(r.deadlines.filter(\.done).count)/\(r.deadlines.count) Fristen")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        let close = Button {
            withAnimation(Motion.standard) { store.prefs.lastReviewDismissedWeek = ws }
        } label: { Label("Ausblenden", systemImage: "xmark").labelStyle(.iconOnly).scaledFont(size: 10, weight: .bold) }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Für diese Woche ausblenden")
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                info
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Rückblick öffnen") { app.selection = .week }.buttonStyle(.borderedProminent)
                    Button("Nächste Woche planen") { app.sheet = .planner(ws.adding(weeks: 1)) }
                }
                close
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) { info; Spacer(); close }
                HStack {
                    Button("Rückblick öffnen") { app.selection = .week }.buttonStyle(.borderedProminent)
                    Button("Nächste Woche planen") { app.sheet = .planner(ws.adding(weeks: 1)) }
                }
            }
        }
        .card(padding: 18)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1))
    }
}

struct AgendaCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        let now = Date()
        let events = calendar.events(from: now.startOfDay, to: now.endOfDay)
        let allDay = events.filter(\.isAllDay)
        let timed = events.filter { !$0.isAllDay }
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Heute", symbol: "calendar") {
                Button { app.selection = .calendar } label: { Text("Kalender").font(.callout) }.buttonStyle(.borderless)
            }
            if !allDay.isEmpty {
                FlowLayout {
                    ForEach(allDay) { e in Pill(text: e.title, color: e.moduleID.map { store.color(for: $0) } ?? e.calendarColor) }
                }
            }
            if timed.isEmpty {
                HStack {
                    Image(systemName: "sun.haze").foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(calendar.eventsAuthorized ? "Keine Termine heute." : "Kalender nicht verbunden.").foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(timed) { e in
                        let isNow = e.start <= now && e.end > now
                        let past = e.end <= now
                        AgendaRow(event: e, isNow: isNow, past: past)
                    }
                }
            }
        }
        .card()
    }
}

struct AgendaRow: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(FocusTimer.self) private var timer
    var event: CalEvent
    var isNow: Bool
    var past: Bool

    var body: some View {
        let color = event.moduleID.map { store.color(for: $0) } ?? event.calendarColor
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(Fmt.time(event.start)).scaledFont(size: 12, weight: .semibold).monospacedDigit()
                Text(Fmt.time(event.end)).scaledFont(size: 11).monospacedDigit().foregroundStyle(.secondary)
            }
            .frame(width: 44, alignment: .trailing)
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title).scaledFont(size: 13, weight: .medium).lineLimit(1)
                    if isNow { Pill(text: "Jetzt", color: .red) }
                }
                Text([event.location.nilIfEmpty, event.calendarTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if event.link?.kind == .block, let mid = event.moduleID, !past, !timer.isRunning {
                Button {
                    timer.start(moduleID: mid, minutes: max(15, Int(event.end.timeIntervalSince(max(Date(), event.start)) / 60)), blockID: event.link?.id)
                } label: { Label("Fokus", systemImage: "play.fill") }
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 7)
        .opacity(past ? 0.5 : 1)
    }
}

struct TasksCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @State private var newTitle = ""
    @FocusState private var focused: Bool

    var body: some View {
        let limit = Date().adding(days: 3).endOfDay
        let open = store.tasks.filter { !$0.done && ($0.due.map { $0 <= limit } ?? true) }
            .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        let doneToday = store.tasks.filter { $0.done && ($0.doneAt?.isToday ?? false) }
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Aufgaben", symbol: "checklist") {
                Button { app.sheet = .task(nil, moduleID: nil) } label: { Label("Neue Aufgabe", systemImage: "plus").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Neue Aufgabe")
            }
            ForEach(open.prefix(10)) { t in TaskRow(task: t) }
            ForEach(doneToday) { t in TaskRow(task: t) }
            HStack {
                Image(systemName: "plus.circle").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Neue Aufgabe – Enter zum Speichern", text: $newTitle)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(add)
            }
            .padding(.top, 2)
        }
        .card()
        .animation(Motion.standard, value: store.tasks)
    }

    private func add() {
        let t = newTitle.trimmed
        guard !t.isEmpty else { return }
        store.tasks.append(TaskItem(title: t, due: Date().endOfDay.adding(minutes: -1)))
        newTitle = ""
        focused = true
    }
}

struct TaskRow: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    var task: TaskItem

    var body: some View {
        let m = store.module(task.moduleID)
        HStack(spacing: 10) {
            Button {
                withAnimation(Motion.momentum) { store.toggleTask(task.id) }
            } label: {
                Label(task.done ? "Als offen markieren" : "Erledigt", systemImage: task.done ? "checkmark.circle.fill" : "circle")
                    .labelStyle(.iconOnly)
                    .scaledFont(size: 16)
                    .foregroundStyle(task.done ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).strikethrough(task.done).foregroundStyle(task.done ? .secondary : .primary).lineLimit(2)
                HStack(spacing: 6) {
                    if let m { ModuleDot(color: m.color.color, size: 6); Text(m.name) }
                    if let d = task.due {
                        Text(Fmt.relative(d)).foregroundStyle(d < Date() && !task.done ? .red : .secondary)
                    }
                    let logged = store.logged(taskID: task.id)
                    if logged > 0 {
                        Text("\(Fmt.jira(logged)) / \(Fmt.jira(task.estimateMinutes))")
                            .foregroundStyle(task.estimateMinutes > 0 && logged > task.estimateMinutes ? .orange : .blue)
                    } else if task.estimateMinutes > 0 { Text("~\(Fmt.duration(task.estimateMinutes))") }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.sheet = .task(task.id, moduleID: nil) }
        .accessibilityAction(named: "Bearbeiten") { app.sheet = .task(task.id, moduleID: nil) }
        .contextMenu {
            Button("Bearbeiten …") { app.sheet = .task(task.id, moduleID: nil) }
            Button("Zeit buchen …") { app.sheet = .logWork(LogPreset(taskID: task.id)) }
            if let mid = task.moduleID {
                Button("Timer starten") {
                    app.timer.start(target: .module(mid), minutes: max(15, task.estimateMinutes - store.logged(taskID: task.id)), taskID: task.id)
                }
            }
            Divider()
            Button("Löschen", role: .destructive) { store.tasks.removeAll { $0.id == task.id } }
        }
    }
}

struct DeadlineCountdownCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store

    var body: some View {
        let list = store.upcomingDeadlines.prefix(5)
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Fristen", symbol: "flag") {
                Button { app.sheet = .deadline(nil, moduleID: nil, kind: nil) } label: { Label("Neue Frist", systemImage: "plus").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Neue Frist")
            }
            if list.isEmpty {
                Text("Keine offenen Fristen.").foregroundStyle(.secondary).font(.callout)
            }
            ForEach(Array(list)) { d in
                let days = Date().daysUntil(d.date)
                Button { app.sheet = .deadline(d.id, moduleID: nil, kind: nil) } label: {
                    HStack(spacing: 12) {
                        VStack(spacing: -2) {
                            Text(days <= 0 ? "!" : "\(days)")
                                .scaledFont(size: 20, weight: .bold, design: .rounded).monospacedDigit()
                            Text(days == 1 ? "Tag" : (days <= 0 ? "heute" : "Tage")).scaledFont(size: 9, weight: .semibold)
                        }
                        .foregroundStyle(urgency(days))
                        .frame(width: 42, height: 42)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(urgency(days).opacity(0.12)))
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 5) {
                                Image(systemName: d.kind.symbol).scaledFont(size: 10).foregroundStyle(d.kind.tint)
                                Text(d.title).scaledFont(size: 13, weight: .medium).lineLimit(1)
                            }
                            Text([store.module(d.moduleID)?.name, Fmt.dateTime(d.date, allDay: d.allDay)].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .buttonStyle(.pressable)
            }
        }
        .card()
    }

    private func urgency(_ days: Int) -> Color {
        days <= 2 ? .red : (days <= 7 ? .orange : .accentColor)
    }
}

struct WeekProgressCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar

    var body: some View {
        let r = WeekReport.make(weekStart: Date().startOfWeek, store: store, calendar: calendar)
        let elapsed = min(1, Date().timeIntervalSince(Date().startOfWeek) / (7 * 86400))
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Diese Woche", symbol: "chart.bar") {
                Button { app.selection = .week } label: { Text("Details").font(.callout) }.buttonStyle(.borderless)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.hours(r.totalLogged)).scaledFont(size: 26, weight: .bold, design: .rounded).tracking(-0.5)
                Text("von \(Fmt.hours(r.totalGoal))").foregroundStyle(.secondary)
            }
            BarMeter(value: r.completion, color: .accentColor, height: 8, marker: elapsed)
            ForEach(r.lines) { l in
                Button { app.openModule(l.id) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            ModuleDot(color: l.color, size: 7)
                            Text(l.name).font(.caption).lineLimit(1)
                            Spacer()
                            Text("\(Fmt.hours(l.logged)) / \(Fmt.hours(l.goal))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        BarMeter(value: l.goal > 0 ? Double(l.logged) / Double(l.goal) : 0, color: l.color, height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
            Button { app.sheet = .logWork(LogPreset()) } label: { Label("Zeit buchen", systemImage: "plus") }
                .buttonStyle(.borderless).font(.callout)
        }
        .card()
    }
}
