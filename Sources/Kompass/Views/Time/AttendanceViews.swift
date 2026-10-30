import SwiftUI

/// „Wahrgenommen?“-Bereich im Termin-Popover: ein Klick bucht genau dieses Vorkommen.
struct AttendanceSection: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let item: TrackItem
    var onDone: () -> Void = {}

    @State private var target: TrackTarget?
    @State private var activity: ActivityKind = .sonstiges
    @State private var durationText = ""
    @State private var remember = true
    @State private var expanded = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let log = app.confirmedLog(for: item) {
                let l = store.label(for: TrackTarget(log))
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        .symbolEffect(.bounce, value: log.id)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Wahrgenommen · \(Fmt.duration(log.minutes))").font(.callout.weight(.semibold))
                        Text("\(l.name) · \(log.activity.label)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Bearbeiten") { app.sheet = .logWork(LogPreset(worklogID: log.id)); onDone() }
                    Button("Rückgängig") { withAnimation(Motion.standard) { app.unconfirm(item) } }
                }
                .controlSize(.small)
            } else if app.isConfirmed(item) {
                HStack {
                    Label("Als erledigt markiert", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Rückgängig") { withAnimation(Motion.standard) { app.unconfirm(item) } }.controlSize(.small)
                }
            } else if app.isSkipped(item) {
                HStack {
                    Label("Nicht wahrgenommen", systemImage: "xmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Doch wahrgenommen") { withAnimation(Motion.standard) { app.unconfirm(item) } }.controlSize(.small)
                }
            } else if !item.hasStarted {
                Label("Nach Beginn kannst du den Termin als wahrgenommen markieren.", systemImage: "clock")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if item.needsCategory || expanded {
                    Picker("Kategorie", selection: $target) {
                        if item.needsCategory && target == nil { Text("Bitte wählen …").tag(TrackTarget?.none) }
                        ForEach(store.trackTargets, id: \.self) { t in Text(store.label(for: t).name).tag(Optional(t)) }
                    }
                    .onChange(of: target) { old, new in
                        if let new, old?.kind != new.kind { activity = ActivityKind.defaultFor(new.kind) }
                    }
                    if expanded {
                        Picker("Art", selection: $activity) {
                            ForEach(ActivityKind.allCases) { a in Text(a.label).tag(a) }
                        }
                        HStack {
                            Text("Dauer")
                            TextField("1h 30m", text: $durationText).textFieldStyle(.roundedBorder).frame(width: 90)
                            if let m = Fmt.parseDuration(durationText) { Text("= \(Fmt.duration(m))").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    if item.needsCategory {
                        Toggle("Für „\(item.title)“ merken", isOn: $remember)
                            .checkboxStyle().font(.caption)
                    }
                } else {
                    let l = store.label(for: item.target)
                    HStack(spacing: 6) {
                        Circle().fill(l.color).frame(width: 7, height: 7)
                        Text("\(l.name) · \(item.activity.label) · \(Fmt.duration(item.minutes))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Button {
                        withAnimation(Motion.momentum) {
                            _ = app.confirm(item, target: target, activity: activity,
                                            minutes: Fmt.parseDuration(durationText) ?? item.minutes,
                                            remember: item.needsCategory && remember)
                        }
                    } label: {
                        Label("Wahrgenommen", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(item.needsCategory && target == nil)
                    Button("Nicht") { withAnimation(Motion.standard) { app.skip(item) } }
                    Spacer()
                    if !expanded {
                        Button { withAnimation(Motion.standard) { expanded = true } } label: { Text("Anpassen …") }
                            .buttonStyle(.borderless)
                    }
                }
                .controlSize(.small)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            target = item.needsCategory ? nil : item.target
            activity = item.activity
            durationText = Fmt.jira(item.minutes)
        }
    }
}

/// Popover für feste Arbeitsblöcke im Kalender.
struct WorkBlockPopover: View {
    @Environment(AppModel.self) private var app
    let item: TrackItem
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(item.title, systemImage: "briefcase").font(.headline)
            Text("\(Fmt.dayShort(item.start)), \(Fmt.time(item.start))–\(Fmt.time(item.end)) · feste Arbeitszeit")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            AttendanceSection(item: item)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}

/// Heute-Ansicht: vergangene Termine, die noch bestätigt werden wollen.
struct ConfirmCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.isCompactLayout) private var compact

    var body: some View {
        let items = app.pendingConfirmations()
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Noch zu bestätigen", symbol: "calendar.badge.checkmark") {
                    Button {
                        withAnimation(Motion.standard) {
                            let n = app.confirmAll(items)
                            app.showToast("\(n) Einträge gebucht", symbol: "clock.badge.checkmark")
                        }
                    } label: { Label(compact ? "Alle" : "Alle wahrgenommen", systemImage: "checkmark.circle") }
                        .controlSize(.small)
                }
                Text("Hast du diese Termine wahrgenommen? Bestätigte Zeiten landen automatisch in deiner Zeiterfassung.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(items.prefix(8)) { item in
                    let l = store.label(for: item.target)
                    HStack(spacing: 10) {
                        Image(systemName: item.source == .workBlock ? "briefcase" : item.activity.symbol)
                            .foregroundStyle(l.color).frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).scaledFont(size: 13, weight: .medium).lineLimit(1)
                            Text("\(item.start.isToday ? "Heute" : Fmt.dayShort(item.start)), \(Fmt.time(item.start))–\(Fmt.time(item.end)) · \(l.name)")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !compact { Text(Fmt.jira(item.minutes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                        Button { withAnimation(Motion.momentum) { _ = app.confirm(item) } } label: {
                            Label("Wahrgenommen", systemImage: "checkmark").labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .help("Wahrgenommen")
                        Button { withAnimation(Motion.standard) { app.skip(item) } } label: {
                            Label("Nicht wahrgenommen", systemImage: "xmark").labelStyle(.iconOnly)
                        }
                        .help("Nicht wahrgenommen")
                        Menu {
                            Button("Mit anderer Dauer buchen …") {
                                app.sheet = .logWork(LogPreset(target: item.target, activity: item.activity, deadlineID: item.deadlineID,
                                                               start: item.start, minutes: item.minutes, title: item.title,
                                                               eventKey: item.key, blockID: item.blockID, source: item.source))
                            }
                        } label: { Label("Weitere Aktionen", systemImage: "ellipsis").labelStyle(.iconOnly) }
                            .plainMenu()
                    }
                    .controlSize(.small)
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if items.count > 8 {
                    Button("+ \(items.count - 8) weitere in der Zeiterfassung") { app.selection = .time }.buttonStyle(.borderless).font(.caption)
                }
            }
            .card()
        }
    }
}
