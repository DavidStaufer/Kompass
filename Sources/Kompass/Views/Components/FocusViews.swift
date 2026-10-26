import SwiftUI

/// Auswahl Modul + Dauer und Start des Fokus-Timers.
struct FocusStarter: View {
    @Environment(DataStore.self) private var store
    @Environment(FocusTimer.self) private var timer
    @State private var target: TrackTarget?
    @State private var minutes = 50
    var preselected: UUID?
    var onStart: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Timer starten").font(.headline)
            Picker("Wofür?", selection: $target) {
                ForEach(store.trackTargets, id: \.self) { t in
                    let l = store.label(for: t)
                    Text(l.name).tag(Optional(t))
                }
            }
            .labelsHidden()
            Picker("Dauer", selection: $minutes) {
                Text("25 min").tag(25)
                Text("50 min").tag(50)
                Text("90 min").tag(90)
                Text("Offen").tag(8 * 60)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Button {
                if let target { timer.start(target: target, minutes: minutes); onStart() }
            } label: {
                Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(target == nil)
            .keyboardShortcut(.defaultAction)
            Text("Die Zeit wird beim Beenden automatisch gebucht.").font(.caption).foregroundStyle(.secondary)
        }
        .onAppear {
            minutes = store.prefs.defaultFocusMinutes
            target = preselected.map { .module($0) } ?? target ?? store.trackTargets.first
        }
    }
}

struct FocusRunningView: View {
    @Environment(DataStore.self) private var store
    @Environment(FocusTimer.self) private var timer
    var compact = false

    var body: some View {
        let l = store.label(for: timer.target)
        let task = store.tasks.first { $0.id == timer.taskID }
        HStack(spacing: 12) {
            ZStack {
                ProgressRing(value: timer.targetMinutes >= 8 * 60 ? 0 : timer.progress, color: l.color, lineWidth: compact ? 3 : 4, size: compact ? 30 : 40)
                Image(systemName: timer.isOvertime ? "checkmark" : (timer.kind == .module ? "brain.head.profile" : l.symbol))
                    .font(.system(size: compact ? 11 : 14, weight: .semibold))
                    .foregroundStyle(l.color)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(task?.title ?? l.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(timer.display)
                    .font(.system(size: compact ? 15 : 20, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isOvertime ? .green : .primary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
            Button {
                timer.stop(save: true)
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.borderless)
            .help("Beenden und Lernzeit speichern")
        }
    }
}

struct FocusMiniCard: View {
    var body: some View {
        FocusRunningView(compact: true)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FocusToolbarButton: View {
    @Environment(FocusTimer.self) private var timer
    @Environment(AppModel.self) private var app
    @State private var show = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            if timer.isRunning {
                Label(timer.display, systemImage: "timer").labelStyle(.titleAndIcon).monospacedDigit()
            } else {
                Label("Fokus", systemImage: "timer")
            }
        }
        .help("Fokus-Timer")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            Group {
                if timer.isRunning {
                    VStack(alignment: .leading, spacing: 12) {
                        FocusRunningView()
                        HStack {
                            Button("Verwerfen", role: .destructive) { timer.stop(save: false); show = false }
                            Spacer()
                            Button("Beenden & speichern") { timer.stop(save: true); show = false }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    FocusStarter(preselected: currentModule) { show = false }
                }
            }
            .padding(16)
            .frame(width: 300)
            .compactPopover()
        }
    }

    private var currentModule: UUID? {
        if case .module(let id) = app.selection { return id }
        return nil
    }
}

#if os(macOS)
// MARK: - Menüleiste

struct MenuBarLabel: View {
    let timer: FocusTimer
    var body: some View {
        if timer.isRunning {
            Text(timer.display).monospacedDigit()
        } else {
            Image(systemName: "safari")
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(FocusTimer.self) private var timer
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if timer.isRunning {
                FocusRunningView()
            } else {
                FocusStarter()
            }
            Divider()
            let now = Date()
            let upcoming = calendar.allEvents(from: now, to: now.endOfDay.adding(days: 1)).filter { !$0.isAllDay && $0.end > now }.prefix(4)
            VStack(alignment: .leading, spacing: 6) {
                Text("Als Nächstes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if upcoming.isEmpty {
                    Text("Keine Termine mehr heute").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(Array(upcoming)) { e in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2).fill(e.moduleID.map { store.color(for: $0) } ?? e.calendarColor).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(e.title).font(.callout).lineLimit(1)
                            Text("\(e.start.isToday ? "" : "Morgen, ")\(Fmt.time(e.start))–\(Fmt.time(e.end))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let d = store.upcomingDeadlines.first {
                Divider()
                HStack {
                    Image(systemName: d.kind.symbol).foregroundStyle(d.kind.tint)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(d.title).font(.callout).lineLimit(1)
                        Text("\(d.kind.label) \(Fmt.relative(d.date))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            HStack {
                Button("Kompass öffnen") {
                    openWindow(id: "main")
                    Platform.activateApp()
                }
                Spacer()
                Button("Beenden") { NSApp.terminate(nil) }.foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(16)
        .frame(width: 300)
    }
}
#endif
