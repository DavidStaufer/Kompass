import SwiftUI
import Charts
import UniformTypeIdentifiers

enum TimePeriod: String, CaseIterable, Identifiable {
    case week, month, term, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .week: return "Woche"
        case .month: return "Monat"
        case .term: return "Semester"
        case .custom: return "Zeitraum"
        }
    }
}

enum ActivityFilter: String, CaseIterable, Identifiable {
    case all, selfStudy, courses, work, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "Alles"
        case .selfStudy: return "Gelernt"
        case .courses: return "Veranstaltungen"
        case .work: return "Arbeit"
        case .other: return "Andere"
        }
    }
    func includes(_ w: Worklog) -> Bool {
        switch self {
        case .all: return true
        case .selfStudy: return w.kind == .module && w.activity.isSelfStudy
        case .courses: return w.kind == .module && (w.activity.isCourse || w.activity == .pruefung)
        case .work: return w.kind == .work
        case .other: return w.kind == .custom
        }
    }
}

enum TimeTab: String, CaseIterable, Identifiable {
    case sheet, logs, tickets
    var id: String { rawValue }
    var label: String { self == .sheet ? "Stundenzettel" : (self == .logs ? "Buchungen" : "Aufgaben & Fristen") }
}

/// Zeiterfassung im Stil von Jira/Tempo: Stundenzettel, Buchungen, Schätzungen.
struct TimeTrackerView: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @AppStorage("time.period") private var period = TimePeriod.week
    @AppStorage("time.tab") private var tab = TimeTab.sheet
    @State private var anchor = Date()
    @State private var customStart = Date().startOfMonth
    @State private var customEnd = Date()
    @State private var excluded: Set<String> = []
    @State private var activityFilter: ActivityFilter = .all
    @State private var exporting = false
    @State private var exportDoc: TextFileDocument?
    @State private var exportCount = 0

    // MARK: Zeitraum

    private var range: DateInterval {
        switch period {
        case .week:
            return DateInterval(start: anchor.startOfWeek, end: anchor.startOfWeek.adding(days: 7))
        case .month:
            return DateInterval(start: anchor.startOfMonth, end: anchor.startOfMonth.adding(months: 1))
        case .term:
            let t = store.terms.first { $0.contains(anchor) } ?? store.currentTerm
            if let t { return DateInterval(start: t.start.startOfDay, end: t.end.endOfDay) }
            return DateInterval(start: anchor.startOfMonth.adding(months: -5), end: anchor.endOfDay)
        case .custom:
            let s = min(customStart, customEnd).startOfDay
            return DateInterval(start: s, end: max(customStart, customEnd).endOfDay)
        }
    }

    private var rangeTitle: String {
        switch period {
        case .week: return "KW \(anchor.weekNumber) · \(Fmt.weekRange(anchor.startOfWeek))"
        case .month: return Fmt.monthYear(anchor)
        case .term: return store.terms.first { $0.contains(anchor) }?.name ?? store.currentTerm?.name ?? "Semester"
        case .custom: return "\(Fmt.dayShort(range.start)) – \(Fmt.dayShort(range.end.adding(days: -1)))"
        }
    }

    /// Spalten: Tage (bis ~5 Wochen) oder Kalenderwochen.
    private var columns: [DateInterval] {
        let days = Calendar.kompass.dateComponents([.day], from: range.start, to: range.end).day ?? 7
        if days <= 35 {
            return (0..<max(1, days)).map { DateInterval(start: range.start.adding(days: $0), end: range.start.adding(days: $0 + 1)) }
        }
        var out: [DateInterval] = []
        var w = range.start.startOfWeek
        while w < range.end {
            out.append(DateInterval(start: max(w, range.start), end: min(w.adding(days: 7), range.end)))
            w = w.adding(weeks: 1)
        }
        return out
    }

    // MARK: Daten

    private var logs: [Worklog] {
        store.worklogs.filter { w in
            w.start >= range.start && w.start < range.end && !excluded.contains(TrackTarget(w).key) && activityFilter.includes(w)
        }
    }

    // MARK: Body

    var body: some View {
        let logs = self.logs
        let cols = columns
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                filterBar
                // Karten als eigene Views: Fensterbreite und Popover des Stundenzettels
                // berechnen nicht mehr die ganze Auswertung neu.
                TimeSummary(logs: logs, range: range, period: period)
                WorkLimitBanner(range: range)
                TimeChartCard(logs: logs, cols: cols)
                Picker("Ansicht", selection: $tab.animation(Motion.standard)) {
                    ForEach(TimeTab.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 460)
                switch tab {
                case .sheet: TimesheetCard(logs: logs, cols: cols, activityFilter: activityFilter)
                case .logs: WorklogList(logs: logs)
                case .tickets: TicketsList()
                }
            }
            .pagePadding()
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Zeiten")
        .inlineNavigationTitle()
        .fileExporter(isPresented: $exporting, document: exportDoc, contentType: .commaSeparatedText,
                      defaultFilename: "Zeiten \(rangeTitle.replacingOccurrences(of: "/", with: "-")).csv") { result in
            if case .success = result { app.showToast("\(exportCount) Buchungen exportiert", symbol: "square.and.arrow.up") }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                PageTitle(title: "Zeiterfassung", subtitle: rangeTitle).fixedSize()
                Spacer()
                Button { app.sheet = .logWork(LogPreset()) } label: { Label(compact ? "Buchen" : "Zeit buchen", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            let periodRow = (compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10)))
            periodRow {
                Picker("Zeitraum", selection: $period.animation(Motion.standard)) {
                    ForEach(TimePeriod.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
                if period == .custom {
                    DatePicker("Von", selection: $customStart, displayedComponents: .date).labelsHidden().fixedSize()
                    Text("–").accessibilityHidden(true)
                    DatePicker("Bis", selection: $customEnd, displayedComponents: .date).labelsHidden().fixedSize()
                } else {
                    HStack(spacing: 2) {
                        Button { step(-1) } label: { Label("Zurück", systemImage: "chevron.left").labelStyle(.iconOnly) }
                            .help("Zurück")
                        Button("Heute") { withAnimation(Motion.standard) { anchor = Date() } }
                        Button { step(1) } label: { Label("Weiter", systemImage: "chevron.right").labelStyle(.iconOnly) }
                            .help("Weiter")
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func step(_ d: Int) {
        withAnimation(Motion.standard) {
            switch period {
            case .week: anchor = anchor.adding(weeks: d)
            case .month: anchor = anchor.adding(months: d)
            case .term:
                let sorted = store.terms.sorted { $0.start < $1.start }
                if let i = sorted.firstIndex(where: { $0.contains(anchor) }), sorted.indices.contains(i + d) {
                    anchor = sorted[i + d].start.adding(days: 1)
                } else {
                    anchor = anchor.adding(months: 6 * d)
                }
            case .custom: break
            }
        }
    }

    private var filterBar: some View {
        let categoryMenu = Menu {
            Button("Alle anzeigen") { excluded = [] }
            Button("Nur Studium") { excluded = Set(allTargets.filter { $0.kind != .module }.map(\.key)) }
            Button("Nur Arbeit") { excluded = Set(allTargets.filter { $0.kind != .work }.map(\.key)) }
            Divider()
            ForEach(allTargets, id: \.self) { t in
                Toggle(store.label(for: t).name, isOn: Binding(
                    get: { !excluded.contains(t.key) },
                    set: { on in if on { excluded.remove(t.key) } else { excluded.insert(t.key) } }))
            }
        } label: {
            Label(excluded.isEmpty ? "Alle Kategorien" : "\(allTargets.count - excluded.count) von \(allTargets.count) Kategorien",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .fixedSize()
        let activityPicker = Picker("Art", selection: $activityFilter) {
            ForEach(ActivityFilter.allCases) { a in Text(compact && a == .courses ? "Kurse" : a.label).tag(a) }
        }
        .pickerStyle(.segmented).labelsHidden()
        let csv = Button { exportCSV() } label: { Label("CSV", systemImage: "square.and.arrow.up") }
            .help("Gefilterte Buchungen als CSV (z. B. für deinen Arbeitgeber)")
        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { categoryMenu; Spacer(); csv }
                    activityPicker
                }
            } else {
                HStack(spacing: 10) {
                    categoryMenu
                    activityPicker.frame(maxWidth: 420)
                    Spacer(minLength: 0)
                    csv
                }
            }
        }
    }

    private var allTargets: [TrackTarget] {
        var seen = Set<String>()
        let fromLogs = store.worklogs.map(TrackTarget.init)
        return (store.trackTargets + fromLogs).filter { seen.insert($0.key).inserted }
    }

    // MARK: Export

    private func exportCSV() {
        let logs = self.logs.sorted { $0.start < $1.start }
        func esc(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Datum;Beginn;Ende;Dauer (h);Kategorie;Bereich;Art;Aufgabe/Frist;Titel;Beschreibung;Quelle"]
        for w in logs {
            let t = TrackTarget(w)
            let area = w.kind == .module ? "Studium" : (w.kind == .work ? "Arbeit" : "Andere")
            let ticket = w.taskID.flatMap { id in store.tasks.first { $0.id == id }?.title } ?? w.deadlineID.flatMap { store.deadline($0)?.title } ?? ""
            let hours = String(format: "%.2f", Double(w.minutes) / 60).replacingOccurrences(of: ".", with: ",")
            lines.append([Fmt.machineDay.string(from: w.start), Fmt.time(w.start), Fmt.time(w.end), hours,
                          esc(store.label(for: t).name), area, w.activity.label, esc(ticket), esc(w.title), esc(w.note), w.source.label].joined(separator: ";"))
        }
        // BOM, damit Excel Umlaute korrekt erkennt
        exportDoc = TextFileDocument(text: lines.joined(separator: "\n"), bom: true)
        exportCount = logs.count
        exporting = true
    }
}

// MARK: - Auswertung

/// Eine Zeile des Stundenzettels: Minuten je Spalte für eine Kategorie.
struct SheetRow: Identifiable {
    let id: String
    let target: TrackTarget
    let name: String
    let color: Color
    var cells: [Int]
    var total: Int { cells.reduce(0, +) }

    @MainActor
    static func rows(for kind: TrackKind, logs: [Worklog], cols: [DateInterval], store: DataStore) -> [SheetRow] {
        var map: [String: SheetRow] = [:]
        for w in logs where w.kind == kind {
            let t = TrackTarget(w)
            guard let ci = cols.firstIndex(where: { $0.start <= w.start && w.start < $0.end }) else { continue }
            if map[t.key] == nil {
                let l = store.label(for: t)
                map[t.key] = SheetRow(id: t.key, target: t, name: l.name, color: l.color, cells: Array(repeating: 0, count: cols.count))
            }
            map[t.key]!.cells[ci] += w.minutes
        }
        return map.values.sorted { $0.total > $1.total }
    }
}

extension [DateInterval] {
    /// Spalten sind Kalenderwochen statt einzelner Tage.
    var areWeeks: Bool { (first?.duration ?? 86400) > 86400 * 1.5 }

    func label(for c: DateInterval) -> String {
        areWeeks ? "KW\(c.start.weekNumber)" : "\(Fmt.weekday(c.start.isoWeekday, short: true)) \(Calendar.kompass.component(.day, from: c.start))"
    }
}

private struct TimeSummary: View {
    @Environment(DataStore.self) private var store
    let logs: [Worklog]
    let range: DateInterval
    let period: TimePeriod

    var body: some View {
        let total = logs.reduce(0) { $0 + $1.minutes }
        let study = logs.filter { $0.kind == .module }
        let studyMin = study.reduce(0) { $0 + $1.minutes }
        let selfStudy = study.filter { $0.activity.isSelfStudy }.reduce(0) { $0 + $1.minutes }
        let work = logs.filter { $0.kind == .work }.reduce(0) { $0 + $1.minutes }
        let other = logs.filter { $0.kind == .custom }.reduce(0) { $0 + $1.minutes }
        let weeks = max(1, range.duration / (7 * 86400))
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
            StatTile(value: Fmt.hours(total), label: "Gesamt", detail: "\(logs.count) Buchungen", progress: nil, color: .accentColor)
            StatTile(value: Fmt.hours(studyMin), label: "Studium",
                     detail: "\(Fmt.hours(selfStudy)) gelernt · \(Fmt.hours(studyMin - selfStudy)) Veranst.",
                     progress: total > 0 ? Double(studyMin) / Double(total) : nil, color: .blue)
            StatTile(value: Fmt.hours(work), label: "Arbeit",
                     detail: period == .week ? "Grenze \(Fmt.hours(Int(store.prefs.workWeeklyLimitHours * 60)))" : "Ø \(Fmt.hours(Int(Double(work) / weeks)))/Woche",
                     progress: period == .week ? min(1, Double(work) / max(1, store.prefs.workWeeklyLimitHours * 60)) : (total > 0 ? Double(work) / Double(total) : nil),
                     color: .gray)
            StatTile(value: Fmt.hours(other), label: "Andere", detail: "\(store.timeCategories.count) Kategorien",
                     progress: total > 0 ? Double(other) / Double(total) : nil, color: .teal)
        }
    }
}

private struct WorkLimitBanner: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let range: DateInterval

    var body: some View {
        let limit = Int(store.prefs.workWeeklyLimitHours * 60)
        let over = app.workMinutesByWeek(from: range.start, to: range.end)
            .filter { $0.minutes > limit && app.isLectureWeek($0.week) }
        if limit > 0 && !over.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Über deiner Arbeitsgrenze von \(Fmt.hours(limit)) pro Woche").font(.callout.weight(.semibold))
                    Text(over.map { "KW \($0.week.weekNumber): \(Fmt.hours($0.minutes))" }.joined(separator: " · ")
                         + (store.prefs.workLimitLectureOnly ? " (Vorlesungszeit)" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.1)))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: Diagramm

private struct TimeChartCard: View {
    @Environment(DataStore.self) private var store
    let logs: [Worklog]
    let cols: [DateInterval]

    private struct ChartPoint: Identifiable {
        let column: String
        let order: Int
        let name: String
        let hours: Double
        /// Stabil über Neuberechnungen hinweg (keine zufällige UUID).
        var id: String { "\(name)|\(order)" }
    }

    var body: some View {
        let all = [TrackKind.module, .work, .custom].flatMap { SheetRow.rows(for: $0, logs: logs, cols: cols, store: store) }
        var points: [ChartPoint] = []
        for r in all {
            for (i, c) in cols.enumerated() where r.cells[i] > 0 {
                points.append(ChartPoint(column: cols.label(for: c), order: i, name: r.name, hours: Double(r.cells[i]) / 60))
            }
        }
        let names = all.map(\.name)
        let colors = all.map(\.color)
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Verlauf", symbol: "chart.bar.xaxis")
            if points.isEmpty {
                Text("In diesem Zeitraum ist noch nichts gebucht. Bestätige Termine im Kalender, nutze den Timer oder buche Zeit manuell.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
            } else {
                Chart(points) { p in
                    BarMark(x: .value("Zeitraum", p.column), y: .value("Stunden", p.hours))
                        .foregroundStyle(by: .value("Kategorie", p.name))
                        .cornerRadius(2)
                        .accessibilityLabel("\(p.column), \(p.name)")
                        .accessibilityValue(Fmt.hours(Int(p.hours * 60)))
                }
                .chartXScale(domain: cols.map { cols.label(for: $0) })
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartLegend(position: .bottom, alignment: .leading)
                .frame(height: 200)
            }
        }
        .card()
    }
}

// MARK: Stundenzettel

/// Eigener Zustand für Breite und offenes Popover – ändert sich oft, betrifft nur die Tabelle.
private struct TimesheetCard: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(DataStore.self) private var store
    let logs: [Worklog]
    let cols: [DateInterval]
    let activityFilter: ActivityFilter
    @State private var cellPopover: String?
    @State private var sheetWidth: CGFloat = 900

    var body: some View {
        let byWeek = cols.areWeeks
        let nameW: CGFloat = compact ? 120 : 230, totalW: CGFloat = compact ? 52 : 70
        let minCell: CGFloat = byWeek ? 54 : (cols.count > 7 ? 42 : 64)
        let cellW = max(minCell, min(140, (sheetWidth - nameW - totalW - 16) / CGFloat(max(1, cols.count))))
        let groups: [(String, [SheetRow])] = [
            ("Studium", SheetRow.rows(for: .module, logs: logs, cols: cols, store: store)),
            ("Arbeit", SheetRow.rows(for: .work, logs: logs, cols: cols, store: store)),
            ("Andere", SheetRow.rows(for: .custom, logs: logs, cols: cols, store: store))
        ].filter { !$0.1.isEmpty }
        let colTotals = cols.indices.map { i in groups.flatMap(\.1).reduce(0) { $0 + $1.cells[i] } }
        let indexed = Array(cols.enumerated())

        VStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                ContentUnavailableView("Keine Buchungen", systemImage: "clock",
                                       description: Text("Bestätige Termine als wahrgenommen oder buche Zeit über „Zeit buchen“."))
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Kopf
                        HStack(spacing: 0) {
                            Text("Kategorie").frame(width: nameW, alignment: .leading)
                            ForEach(indexed, id: \.element) { _, c in
                                Text(cols.label(for: c))
                                    .foregroundStyle(!byWeek && c.start.isToday ? Color.red : (!byWeek && c.start.isWeekend ? .secondary : .primary))
                                    .frame(width: cellW)
                            }
                            Text("Summe").frame(width: totalW, alignment: .trailing)
                        }
                        .scaledFont(size: 11, weight: .semibold)
                        .padding(.vertical, 8)
                        Divider()
                        ForEach(groups, id: \.0) { title, rows in
                            groupHeader(title, rows: rows, nameW: nameW, cellW: cellW, totalW: totalW)
                            ForEach(rows) { r in
                                sheetRow(r, nameW: nameW, cellW: cellW, totalW: totalW)
                                Divider().opacity(0.5)
                            }
                        }
                        // Summenzeile
                        HStack(spacing: 0) {
                            Text("Summe").frame(width: nameW, alignment: .leading)
                            ForEach(indexed, id: \.element) { i, _ in
                                Text(Fmt.decimalHours(colTotals[i])).frame(width: cellW)
                            }
                            Text(Fmt.hours(colTotals.reduce(0, +))).frame(width: totalW, alignment: .trailing)
                        }
                        .scaledFont(size: 12, weight: .bold).monospacedDigit()
                        .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 4)
                }
                Text("Werte in Stunden. Klick auf eine Zelle zeigt die Buchungen.").font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { sheetWidth = g.size.width }
                .onChange(of: g.size.width) { _, w in sheetWidth = w }
        })
        .card()
    }

    private func groupHeader(_ title: String, rows: [SheetRow], nameW: CGFloat, cellW: CGFloat, totalW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text(title.uppercased()).scaledFont(size: 10, weight: .bold).tracking(0.6).foregroundStyle(.secondary)
                .frame(width: nameW, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            ForEach(Array(cols.enumerated()), id: \.element) { i, _ in
                Text(Fmt.decimalHours(rows.reduce(0) { $0 + $1.cells[i] })).foregroundStyle(.secondary).frame(width: cellW)
            }
            Text(Fmt.hours(rows.reduce(0) { $0 + $1.total })).frame(width: totalW, alignment: .trailing)
        }
        .scaledFont(size: 11, weight: .semibold).monospacedDigit()
        .padding(.vertical, 6)
        .background(Color.subtleFill)
    }

    private func sheetRow(_ r: SheetRow, nameW: CGFloat, cellW: CGFloat, totalW: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                ModuleDot(color: r.color)
                Text(r.name).lineLimit(1)
            }
            .scaledFont(size: 12.5, weight: .medium)
            .frame(width: nameW, alignment: .leading)
            ForEach(Array(cols.enumerated()), id: \.element) { i, c in
                let key = "\(r.id)|\(i)"
                Button {
                    cellPopover = key
                } label: {
                    Text(Fmt.decimalHours(r.cells[i]))
                        .scaledFont(size: 12).monospacedDigit()
                        .frame(width: cellW - 4, height: 26)
                        .background(RoundedRectangle(cornerRadius: 5).fill(r.cells[i] > 0 ? r.color.opacity(min(0.45, 0.1 + Double(r.cells[i]) / 600)) : Color.clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .frame(width: cellW)
                .accessibilityLabel("\(r.name), \(cols.label(for: c))")
                .accessibilityValue(Fmt.hours(r.cells[i]))
                .popover(isPresented: Binding(get: { cellPopover == key }, set: { if !$0 && cellPopover == key { cellPopover = nil } })) {
                    CellLogsPopover(target: r.target, interval: c, activityFilter: activityFilter) { cellPopover = nil }
                        .compactPopover()
                }
            }
            Text(Fmt.hours(r.total)).scaledFont(size: 12, weight: .semibold).monospacedDigit().frame(width: totalW, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }
}

// MARK: Buchungen

private struct WorklogList: View {
    let logs: [Worklog]

    var body: some View {
        let days = Dictionary(grouping: logs) { $0.start.startOfDay }.sorted { $0.key > $1.key }
        VStack(alignment: .leading, spacing: 16) {
            if days.isEmpty {
                ContentUnavailableView("Keine Buchungen", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity, minHeight: 200)
            }
            ForEach(days, id: \.key) { day, items in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(Fmt.dayLong(day)).scaledFont(size: 13, weight: .semibold)
                        Spacer()
                        Text(Fmt.jira(items.reduce(0) { $0 + $1.minutes })).font(.callout.monospacedDigit().weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                    let sorted = items.sorted { $0.start < $1.start }
                    VStack(spacing: 0) {
                        ForEach(sorted) { w in
                            WorklogRow(log: w)
                            if w.id != sorted.last?.id { Divider().padding(.leading, 34) }
                        }
                    }
                    .card(padding: 6)
                }
            }
        }
    }
}

// MARK: Aufgaben (Jira-Tickets)

private struct TicketsList: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store

    private struct TicketLine: Identifiable {
        let id: String
        let title: String
        let done: Bool
        let moduleID: UUID?
        let due: Date?
        let estimate: Int
        let logged: Int
        let preset: LogPreset
    }

    var body: some View {
        let tasks = store.tasks.filter { $0.estimateMinutes > 0 || store.logged(taskID: $0.id) > 0 }
            .sorted { ($0.done ? 1 : 0, $0.due ?? .distantFuture) < ($1.done ? 1 : 0, $1.due ?? .distantFuture) }
        let deadlines = store.deadlines.filter { $0.kind != .anmeldung && ($0.effectivePrepHours > 0 || store.logged(deadlineID: $0.id) > 0) }
            .sorted { ($0.done ? 1 : 0, $0.date) < ($1.done ? 1 : 0, $1.date) }
        VStack(alignment: .leading, spacing: 16) {
            Text("Wie in Jira: Schätzung, erfasste und verbleibende Zeit. Buche Zeit direkt auf eine Aufgabe oder Frist – so lernst du, deinen Aufwand realistisch einzuschätzen.")
                .font(.callout).foregroundStyle(.secondary)
            ticketSection("Aufgaben", items: tasks.map { t in
                TicketLine(id: "t-\(t.id)", title: t.title, done: t.done, moduleID: t.moduleID, due: t.due,
                           estimate: t.estimateMinutes, logged: store.logged(taskID: t.id), preset: LogPreset(taskID: t.id))
            })
            ticketSection("Fristen", items: deadlines.map { d in
                TicketLine(id: "d-\(d.id)", title: "\(d.kind.label): \(d.title)", done: d.done, moduleID: d.moduleID, due: d.date,
                           estimate: Int(d.effectivePrepHours * 60), logged: store.logged(deadlineID: d.id), preset: LogPreset(deadlineID: d.id))
            })
        }
    }

    @ViewBuilder
    private func ticketSection(_ title: String, items: [TicketLine]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).scaledFont(size: 15, weight: .semibold).accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(items) { t in
                        AdaptiveStack(spacing: compact ? 8 : 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.callout.weight(.medium)).strikethrough(t.done).lineLimit(1)
                                HStack(spacing: 6) {
                                    if let m = store.module(t.moduleID) { ModuleDot(color: m.color.color, size: 6); Text(m.name) }
                                    if let d = t.due { Text(Fmt.relative(d)) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(width: compact ? nil : 280, alignment: .leading)
                            TimeTrackingBar(estimate: t.estimate, logged: t.logged)
                            Button { app.sheet = .logWork(t.preset) } label: { Label("Buchen", systemImage: "plus") }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 10)
                        if t.id != items.last?.id { Divider() }
                    }
                }
                .card(padding: 4)
            }
        }
    }
}

/// Buchungen einer Stundenzettel-Zelle.
struct CellLogsPopover: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let target: TrackTarget
    let interval: DateInterval
    let activityFilter: ActivityFilter
    var close: () -> Void

    var body: some View {
        let logs = store.worklogs.filter { TrackTarget($0).key == target.key && $0.start >= interval.start && $0.start < interval.end && activityFilter.includes($0) }
            .sorted { $0.start < $1.start }
        VStack(alignment: .leading, spacing: 10) {
            Text("\(store.label(for: target).name) · \(interval.duration > 90000 ? "KW \(interval.start.weekNumber)" : Fmt.dayShort(interval.start))")
                .font(.headline)
            if logs.isEmpty { Text("Keine Buchungen").foregroundStyle(.secondary).font(.callout) }
            ForEach(logs) { w in
                HStack {
                    Image(systemName: w.source.symbol).foregroundStyle(.secondary).frame(width: 16).accessibilityLabel(w.source.label)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("\(Fmt.time(w.start))–\(Fmt.time(w.end)) · \(w.activity.label)").font(.callout)
                        if !(w.note.isEmpty && w.title.isEmpty) {
                            Text(w.note.isEmpty ? w.title : w.note).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Text(Fmt.jira(w.minutes)).font(.callout.monospacedDigit())
                    Button { app.sheet = .logWork(LogPreset(worklogID: w.id)); close() } label: {
                        Label("Bearbeiten", systemImage: "pencil").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                }
            }
            Divider()
            Button {
                let start = interval.duration > 90000 ? interval.start.at(minutes: 9 * 60) : interval.start.at(minutes: 9 * 60)
                app.sheet = .logWork(LogPreset(target: target, start: start))
                close()
            } label: { Label("Zeit buchen", systemImage: "plus") }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

struct WorklogRow: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let log: Worklog

    var body: some View {
        let l = store.label(for: TrackTarget(log))
        let ticket = log.taskID.flatMap { id in store.tasks.first { $0.id == id }?.title } ?? log.deadlineID.flatMap { store.deadline($0)?.title }
        HStack(spacing: 10) {
            Image(systemName: log.activity.symbol).foregroundStyle(l.color).frame(width: 20).accessibilityHidden(true)
            Text("\(Fmt.time(log.start))–\(Fmt.time(log.end))").font(.callout.monospacedDigit()).frame(width: 96, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(l.name).font(.callout.weight(.medium))
                    Text(log.activity.label).font(.caption).foregroundStyle(.secondary)
                    if let ticket { Pill(text: ticket, color: .blue, symbol: "link") }
                }
                let detail = [log.title.nilIfEmpty, log.note.nilIfEmpty].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            Image(systemName: log.source.symbol).font(.caption).foregroundStyle(.tertiary).help(log.source.label).accessibilityLabel(log.source.label)
            Text(Fmt.jira(log.minutes)).font(.callout.monospacedDigit().weight(.semibold)).frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { app.sheet = .logWork(LogPreset(worklogID: log.id)) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Bearbeiten") { app.sheet = .logWork(LogPreset(worklogID: log.id)) }
        .contextMenu {
            Button("Bearbeiten …") { app.sheet = .logWork(LogPreset(worklogID: log.id)) }
            Button("Duplizieren") {
                var copy = log
                copy.id = UUID(); copy.eventKey = nil; copy.blockID = nil; copy.source = .manual; copy.createdAt = Date()
                store.worklogs.append(copy)
            }
            Divider()
            Button("Löschen", role: .destructive) {
                store.worklogs.removeAll { $0.id == log.id }
                if let bid = log.blockID, let i = store.blocks.firstIndex(where: { $0.id == bid }) { store.blocks[i].status = .planned }
            }
        }
    }
}
