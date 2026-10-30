import SwiftUI
import EventKit

enum CalendarMode: String, CaseIterable, Identifiable {
    case day, week, month
    var id: String { rawValue }
    var label: String { self == .day ? "Tag" : (self == .week ? "Woche" : "Monat") }
}

struct CalendarScreen: View {
    @Environment(AppModel.self) private var app
    @Environment(CalendarService.self) private var calendar
    @AppStorage("calendar.mode") private var regularMode = CalendarMode.week
    @AppStorage("calendar.mode.compact") private var compactMode = CalendarMode.day
    @State private var direction: Edge = .trailing
    @Environment(\.accessibilityReduceMotion) private var reduce
    @Environment(\.isCompactLayout) private var compact

    /// iPhone und Mac merken sich ihre Ansicht getrennt.
    private var modeBinding: Binding<CalendarMode> { compact ? $compactMode : $regularMode }
    private var mode: CalendarMode { modeBinding.wrappedValue }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            header
            Divider()
            if !calendar.canShowEvents {
                ContentUnavailableView {
                    Label("Kein Zugriff auf Apple Kalender", systemImage: "calendar.badge.exclamationmark")
                } description: {
                    Text("Erlaube Kompass den Kalenderzugriff, um deine Termine zu sehen und Lernblöcke einzuplanen.")
                } actions: {
                    Button("Zugriff erlauben") {
                        if calendar.eventStatus == .notDetermined { Task { await calendar.requestAccess() } } else { calendar.openPrivacySettings() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Group {
                    switch mode {
                    case .day: TimeGridView(days: [app.calendarDate.startOfDay])
                    case .week: TimeGridView(days: (0..<7).map { app.calendarDate.startOfWeek.adding(days: $0) })
                    case .month: MonthGridView(month: app.calendarDate.startOfMonth) { day in
                        app.calendarDate = day
                        withAnimation(Motion.standard) { modeBinding.wrappedValue = .week }
                    }
                    }
                }
                // Feste Raster: Text wächst mit, aber nur bis die Zellen noch lesbar bleiben.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .id("\(mode.rawValue)-\(periodKey)")
                .simultaneousGesture(swipeToPage, including: compact ? .all : .subviews)
                .transition(reduce ? .opacity : .asymmetric(insertion: .move(edge: direction).combined(with: .opacity),
                                                             removal: .move(edge: direction == .trailing ? .leading : .trailing).combined(with: .opacity)))
            }
        }
        .clipped()
        .navigationTitle("Kalender")
        .inlineNavigationTitle()
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
    }

    private var periodKey: String {
        switch mode {
        case .day: return Fmt.machineDay.string(from: app.calendarDate)
        case .week: return Fmt.machineDay.string(from: app.calendarDate.startOfWeek)
        case .month: return Fmt.machineDay.string(from: app.calendarDate.startOfMonth)
        }
    }

    /// Horizontal wischen blättert (nicht während ein Termin gezogen wird).
    private var swipeToPage: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { v in
                guard !app.eventDragActive else { return }
                let dx = v.translation.width, dy = v.translation.height
                let projected = dx + v.velocity.width * 0.2
                guard abs(dx) > abs(dy) * 1.5, abs(projected) > 80 else { return }
                step(projected < 0 ? 1 : -1)
            }
    }

    @ViewBuilder
    private var header: some View {
        if compact { compactHeader } else { regularHeader }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.monthYear(app.calendarDate)).scaledFont(size: 22, weight: .bold).tracking(-0.4)
                    Text(subtitle).scaledFont(size: 12, weight: .medium).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: openPlanner) {
                    Label("Lernblöcke planen", systemImage: "wand.and.stars")
                }
                Button(action: newEvent) {
                    Label("Neuer Termin", systemImage: "plus")
                }
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            HStack(spacing: 8) {
                Picker("Ansicht", selection: modeBinding.animation(Motion.standard)) {
                    ForEach(CalendarMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button("Heute") { direction = app.calendarDate > Date() ? .leading : .trailing; withAnimation(Motion.standard) { app.calendarDate = Date() } }
                    .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var regularHeader: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.monthYear(app.calendarDate))
                    .scaledFont(size: 22, weight: .bold).tracking(-0.4)
                Text(subtitle).scaledFont(size: 12, weight: .medium).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openPlanner) {
                Label("Lernblöcke planen", systemImage: "wand.and.stars")
            }
            Button(action: newEvent) {
                Label("Neuer Termin", systemImage: "plus").labelStyle(.iconOnly)
            }
            .help("Neuer Termin (⌘N)")
            Picker("Ansicht", selection: modeBinding.animation(Motion.standard)) {
                ForEach(CalendarMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            HStack(spacing: 2) {
                Button { step(-1) } label: { Label("Zurück", systemImage: "chevron.left").labelStyle(.iconOnly) }
                    .help("Zurück (←)")
                Button("Heute") { direction = app.calendarDate > Date() ? .leading : .trailing; withAnimation(Motion.standard) { app.calendarDate = Date() } }
                Button { step(1) } label: { Label("Weiter", systemImage: "chevron.right").labelStyle(.iconOnly) }
                    .help("Weiter (→)")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var subtitle: String {
        switch mode {
        case .day: return Fmt.dayLong(app.calendarDate)
        case .week: return "KW \(app.calendarDate.weekNumber) · \(Fmt.weekRange(app.calendarDate.startOfWeek))"
        case .month: return "KW \(app.calendarDate.startOfMonth.weekNumber)–\(app.calendarDate.startOfMonth.adding(months: 1).adding(days: -1).weekNumber)"
        }
    }

    private func openPlanner() {
        app.sheet = .planner(max(app.calendarDate.startOfWeek, Date().startOfWeek))
    }

    private func newEvent() {
        let s = app.calendarDate.isToday ? Date().at(minutes: (Date().minutesSinceMidnight / 30 + 1) * 30) : app.calendarDate.at(minutes: 10 * 60)
        app.sheet = .newEvent(start: s, end: s.adding(minutes: 60), moduleID: nil)
    }

    private func step(_ dir: Int) {
        direction = dir > 0 ? .trailing : .leading
        withAnimation(Motion.pick(reduce)) {
            switch mode {
            case .day: app.calendarDate = app.calendarDate.adding(days: dir)
            case .week: app.calendarDate = app.calendarDate.adding(weeks: dir)
            case .month: app.calendarDate = app.calendarDate.adding(months: dir)
            }
        }
    }
}

// MARK: - Zeitraster (Tag/Woche)

struct EventSegment: Identifiable {
    let event: CalEvent
    let day: Int
    let startMin: Int
    let endMin: Int
    var col = 0
    var cols = 1
    var id: String { "\(event.id)#\(day)" }
}

struct TimeGridView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    let days: [Date]

    @Environment(\.isCompactLayout) private var compact
    private let hourHeight: CGFloat = 48
    private var gutter: CGFloat { compact ? 44 : 54 }
    /// Vorschau beim Aufziehen eines neuen Termins – liegt in einem eigenen Objekt,
    /// damit nur die Vorschau neu zeichnet und nicht das ganze Raster.
    @State private var draft = GridDraft()
    @State private var selected: String?
    @State private var scrolled = false

    var body: some View {
        let start = days.first!.startOfDay
        let end = days.last!.endOfDay
        let events = calendar.events(from: start, to: end)
        let segments = layout(events.filter { !$0.isAllDay })
        let allDay = events.filter(\.isAllDay)

        GeometryReader { geo in
            let colW = max(40, (geo.size.width - gutter) / CGFloat(days.count))
            VStack(spacing: 0) {
                dayHeader(colW: colW)
                allDayRow(allDay, colW: colW)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        grid(segments: segments, colW: colW)
                    }
                    .onAppear {
                        guard !scrolled else { return }
                        scrolled = true
                        let nowHour = Date().minutesSinceMidnight / 60
                        let p = store.prefs
                        let inWindow = nowHour >= p.studyDayStart / 60 && nowHour < p.studyDayEnd / 60
                        let target = days.contains(where: \.isToday) && inWindow ? max(0, nowHour - 2) : max(0, p.studyDayStart / 60 - 1)
                        proxy.scrollTo("h\(target)", anchor: .top)
                    }
                }
            }
        }
    }

    // MARK: Kopf

    private func dayHeader(colW: CGFloat) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter, height: 34)
            ForEach(days, id: \.self) { d in
                HStack(spacing: 6) {
                    Text(Fmt.weekday(d.isoWeekday, short: true)).foregroundStyle(.secondary)
                        .accessibilityLabel(Fmt.dayLong(d))
                    Text("\(Calendar.kompass.component(.day, from: d))")
                        .foregroundStyle(d.isToday ? Color.white : Color.primary)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Circle().fill(d.isToday ? Color.red : Color.clear))
                }
                .scaledFont(size: 13, weight: .semibold)
                .frame(width: colW, height: 34)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { app.calendarDate = d }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { app.calendarDate = d }
                .contextMenu {
                    if d.startOfDay <= Date() {
                        Button("Alle Termine als wahrgenommen bestätigen") {
                            let items = app.trackables(from: d.startOfDay, to: min(d.endOfDay, Date()))
                                .filter { $0.end <= Date() && !app.isSkipped($0) }
                            let n = app.confirmAll(items)
                            app.showToast(n == 0 ? "Nichts mehr zu bestätigen" : "\(n) Termine gebucht", symbol: "clock.badge.checkmark")
                        }
                    }
                    Button("Zeit buchen …") { app.sheet = .logWork(LogPreset(start: d.at(minutes: 9 * 60))) }
                }
            }
        }
    }

    private func allDayRow(_ events: [CalEvent], colW: CGFloat) -> some View {
        let perDay: [(day: Date, events: [CalEvent])] = days.map { d in
            (d, events.filter { $0.start < d.endOfDay && ($0.end > d.startOfDay || $0.start.isSameDay(d)) })
        }
        let maxCount = perDay.map(\.events.count).max() ?? 0
        return Group {
            if maxCount > 0 {
                HStack(alignment: .top, spacing: 0) {
                    Text("ganzt.").scaledFont(size: 10).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(width: gutter - 6, alignment: .trailing).padding(.trailing, 6)
                    ForEach(perDay, id: \.day) { entry in
                        VStack(spacing: 2) {
                            ForEach(entry.events.prefix(3)) { e in
                                let c = e.moduleID.map { store.color(for: $0) } ?? e.calendarColor
                                Text(e.title)
                                    .scaledFont(size: 11, weight: .medium)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(c.opacity(0.22)))
                                    .onTapGesture(count: 2) { app.sheet = .editEvent(e.id) }
                                    .accessibilityAddTraits(.isButton)
                                    .accessibilityAction(named: "Bearbeiten") { app.sheet = .editEvent(e.id) }
                            }
                            if entry.events.count > 3 { Text("+\(entry.events.count - 3)").font(.caption2).foregroundStyle(.secondary) }
                        }
                        .padding(.horizontal, 2)
                        .frame(width: colW, alignment: .top)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: Raster

    private func grid(segments: [EventSegment], colW: CGFloat) -> some View {
        let totalH = hourHeight * 24
        return ZStack(alignment: .topLeading) {
            // Stundenlinien
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { h in
                    HStack(alignment: .top, spacing: 0) {
                        Text(h == 0 ? "" : String(format: "%02d:00", h))
                            .scaledFont(size: 10, weight: .medium).monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(width: gutter - 8, alignment: .trailing)
                            .padding(.trailing, 8)
                            .offset(y: -6)
                        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
                    }
                    .frame(height: hourHeight, alignment: .top)
                    .id("h\(h)")
                }
            }

            // Tages-Hintergründe: Wochenende, Lernfenster, feste Arbeitszeiten
            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                dayBackground(day: day, height: totalH)
                    .frame(width: colW, height: totalH)
                    .offset(x: gutter + colW * CGFloat(i))
            }
            #if os(macOS)
            .gesture(createGesture(colW: colW))
            #else
            .onTapGesture(count: 2, coordinateSpace: .named("grid")) { loc in
                // iPhone: Doppeltippen auf freie Fläche legt einen Termin an
                let day = min(days.count - 1, max(0, Int((loc.x - gutter) / colW)))
                let s = snap(loc.y)
                app.sheet = .newEvent(start: days[day].at(minutes: s), end: days[day].at(minutes: s + 60), moduleID: nil)
            }
            #endif

            // Feste Arbeitszeiten (anklickbar → „wahrgenommen“)
            ForEach(Array(days.enumerated()), id: \.element) { i, day in
                ForEach(store.workBlocks.filter { $0.weekday == day.isoWeekday }) { w in
                    WorkBlockCell(item: app.trackItem(for: w, on: day),
                                  width: colW - 4, height: CGFloat(w.endMinutes - w.startMinutes) / 60 * hourHeight)
                        .offset(x: gutter + colW * CGFloat(i) + 2, y: CGFloat(w.startMinutes) / 60 * hourHeight)
                }
            }

            // Spaltentrenner
            ForEach(1..<max(1, days.count), id: \.self) { i in
                Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 1, height: totalH).offset(x: gutter + colW * CGFloat(i))
            }

            // Neuer-Termin-Vorschau
            GhostPreview(draft: draft, colW: colW, gutter: gutter, hourHeight: hourHeight)

            // Termine
            ForEach(segments) { seg in
                let w = (colW - 4) / CGFloat(seg.cols)
                EventBlockView(segment: seg, width: w - 1, hourHeight: hourHeight, colWidth: colW,
                               color: seg.event.moduleID.map { store.color(for: $0) } ?? seg.event.calendarColor,
                               selected: $selected)
                    .offset(x: gutter + colW * CGFloat(seg.day) + 2 + w * CGFloat(seg.col), y: CGFloat(seg.startMin) / 60 * hourHeight)
            }

            // Jetzt-Linie
            if let i = days.firstIndex(where: \.isToday) {
                TimelineView(.periodic(from: .now, by: 60)) { ctx in
                    let y = CGFloat(ctx.date.minutesSinceMidnight) / 60 * hourHeight
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: -4)
                        Rectangle().fill(Color.red).frame(width: colW - 4, height: 1.5)
                    }
                    .offset(x: gutter + colW * CGFloat(i), y: y - 4)
                    .allowsHitTesting(false)
                }
            }
        }
        .frame(height: totalH, alignment: .topLeading)
        .coordinateSpace(.named("grid"))
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private func dayBackground(day: Date, height: CGFloat) -> some View {
        let p = store.prefs
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(day.isWeekend ? Color.primary.opacity(0.025) : Color.clear)
            // außerhalb des Lernfensters leicht abdunkeln
            Rectangle().fill(Color.primary.opacity(0.03)).frame(height: CGFloat(p.studyDayStart) / 60 * hourHeight)
            Rectangle().fill(Color.primary.opacity(0.03))
                .frame(height: max(0, height - CGFloat(p.studyDayEnd) / 60 * hourHeight))
                .offset(y: CGFloat(p.studyDayEnd) / 60 * hourHeight)
        }
        .contentShape(Rectangle())
        .onTapGesture { selected = nil }
    }

    /// Ziehen auf freier Fläche erstellt einen neuen Termin.
    private func createGesture(colW: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
            .onChanged { v in
                let day = min(days.count - 1, max(0, Int((v.startLocation.x - gutter) / colW)))
                let a = snap(v.startLocation.y), b = snap(v.location.y)
                let s = min(a, b), e = max(a, b)
                draft.ghost = GridDraft.Ghost(day: day, start: s, end: max(e, s + 15))
            }
            .onEnded { _ in
                guard let g = draft.ghost else { return }
                draft.ghost = nil
                let d = days[g.day]
                app.sheet = .newEvent(start: d.at(minutes: g.start), end: d.at(minutes: g.end), moduleID: nil)
            }
    }

    private func snap(_ y: CGFloat) -> Int {
        let m = Int((y - 8) / hourHeight * 60)
        return min(24 * 60, max(0, (m + 7) / 15 * 15))
    }

    /// Spaltenaufteilung für überlappende Termine.
    private func layout(_ events: [CalEvent]) -> [EventSegment] {
        var out: [EventSegment] = []
        for (i, d) in days.enumerated() {
            let ds = d.startOfDay, de = d.endOfDay
            let dayEvents = events.filter { $0.start < de && $0.end > ds }
            var segs: [EventSegment] = []
            for e in dayEvents {
                let s: Int = e.start < ds ? 0 : e.start.minutesSinceMidnight
                let en: Int = e.end >= de ? 24 * 60 : max(s + 15, e.end.minutesSinceMidnight)
                segs.append(EventSegment(event: e, day: i, startMin: s, endMin: max(en, s + 15)))
            }
            segs.sort { a, b in
                if a.startMin == b.startMin { return a.endMin > b.endMin }
                return a.startMin < b.startMin
            }

            var cluster: [Int] = []
            var clusterEnd = -1
            var columnsEnd: [Int] = []
            func flush() {
                let n = columnsEnd.count
                for idx in cluster { segs[idx].cols = max(1, n) }
                cluster.removeAll(); columnsEnd.removeAll()
            }
            for idx in segs.indices {
                if segs[idx].startMin >= clusterEnd && !cluster.isEmpty { flush() }
                if let c = columnsEnd.firstIndex(where: { $0 <= segs[idx].startMin }) {
                    segs[idx].col = c
                    columnsEnd[c] = segs[idx].endMin
                } else {
                    segs[idx].col = columnsEnd.count
                    columnsEnd.append(segs[idx].endMin)
                }
                cluster.append(idx)
                clusterEnd = max(clusterEnd, segs[idx].endMin)
            }
            flush()
            out += segs
        }
        return out
    }
}

@Observable
final class GridDraft {
    struct Ghost: Equatable { var day: Int; var start: Int; var end: Int }
    var ghost: Ghost?
}

private struct GhostPreview: View {
    let draft: GridDraft
    let colW: CGFloat
    let gutter: CGFloat
    let hourHeight: CGFloat

    var body: some View {
        if let g = draft.ghost {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.25))
                .overlay(alignment: .topLeading) {
                    Text("\(Fmt.hm(g.start))–\(Fmt.hm(g.end))").scaledFont(size: 11, weight: .semibold).padding(5)
                }
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1))
                .frame(width: colW - 4, height: max(12, CGFloat(g.end - g.start) / 60 * hourHeight))
                .offset(x: gutter + colW * CGFloat(g.day) + 2, y: CGFloat(g.start) / 60 * hourHeight)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Termin-Block mit direkter Manipulation

struct EventBlockView: View {
    @Environment(AppModel.self) private var app
    @Environment(CalendarService.self) private var calendar
    @Environment(\.accessibilityReduceMotion) private var reduce
    let segment: EventSegment
    let width: CGFloat
    let hourHeight: CGFloat
    let colWidth: CGFloat
    let color: Color
    @Binding var selected: String?

    @State private var drag: CGSize = .zero
    @State private var resize: CGFloat = 0
    @State private var active = false

    private var event: CalEvent { segment.event }
    private var height: CGFloat { max(18, CGFloat(segment.endMin - segment.startMin) / 60 * hourHeight + resize) }
    private var isBlock: Bool { event.link?.kind == .block }

    var body: some View {
        let compact = height < 34
        let confirmed = event.start < Date() && app.isConfirmed(app.trackItem(for: event))
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if confirmed { Image(systemName: "checkmark.circle.fill").scaledFont(size: 9).foregroundStyle(.green) }
                if event.link?.kind == .deadline { Image(systemName: "flag.fill").scaledFont(size: 8) }
                if isBlock { Image(systemName: "brain.head.profile").scaledFont(size: 8) }
                Text(event.title).scaledFont(size: 11, weight: .semibold).lineLimit(compact ? 1 : 2)
            }
            if !compact {
                Text(timeLabel).scaledFont(size: 10).monospacedDigit().opacity(0.75)
                if !event.location.isEmpty, height > 56 { Text(event.location).scaledFont(size: 10).lineLimit(1).opacity(0.7) }
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 6)
        .padding(.vertical, compact ? 1 : 4)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(color.opacity(selected == event.id || active ? 0.42 : (isBlock ? 0.16 : 0.24)))
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(color.opacity(isBlock ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        )
        .overlay(alignment: .bottom) {
            #if os(macOS)
            if event.editable && height > 24 {
                Color.clear.frame(height: 7).contentShape(Rectangle())
                    .resizeCursor()
                    .gesture(resizeGesture)
            }
            #endif
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .scaleEffect(active && !reduce ? 1.02 : 1)
        .shadow(color: .black.opacity(active ? 0.22 : 0), radius: active ? 10 : 0, y: active ? 4 : 0)
        .offset(drag)
        .zIndex(active ? 100 : (selected == event.id ? 50 : 0))
        .opacity(event.end < Date() && !active ? 0.6 : 1)
        .contentShape(Rectangle())
        // Gesten statt Button: Einfach- und Doppelklick sowie Ziehen auf demselben Block.
        .onTapGesture(count: 2) { app.sheet = .editEvent(event.id) }
        .onTapGesture { selected = (selected == event.id ? nil : event.id) }
        .gesture(moveGesture, including: event.editable ? .all : .subviews)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title), \(Fmt.time(event.start)) bis \(Fmt.time(event.end))")
        .accessibilityValue(confirmed ? "wahrgenommen" : "")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { selected = (selected == event.id ? nil : event.id) }
        .accessibilityAction(named: "Bearbeiten") { app.sheet = .editEvent(event.id) }
        .sensoryFeedback(.impact(weight: .medium), trigger: active) { _, new in new }
        .sensoryFeedback(.selection, trigger: drag) { old, new in active && snapKey(old) != snapKey(new) }
        .popover(isPresented: Binding(get: { selected == event.id && !active }, set: { if !$0 && selected == event.id { selected = nil } }), arrowEdge: .trailing) {
            EventPopover(event: event) { selected = nil }
                .compactPopover()
        }
        .help(event.editable ? "Ziehen zum Verschieben, Doppelklick zum Bearbeiten" : "\(event.calendarTitle) (schreibgeschützt)")
    }

    private var timeLabel: String {
        let s = segment.startMin + Int(drag.height / hourHeight * 60)
        let e = segment.endMin + Int((drag.height + resize) / hourHeight * 60)
        return active ? "\(Fmt.hm(snap(s)))–\(Fmt.hm(snap(e)))" : "\(Fmt.time(event.start))–\(Fmt.time(event.end))"
    }

    private func snap(_ m: Int) -> Int { (m + (m >= 0 ? 7 : -7)) / 15 * 15 }

    /// Viertelstunden-Raster für haptisches Einrasten beim Ziehen.
    private func snapKey(_ s: CGSize) -> Int {
        Int((s.width / colWidth).rounded()) * 1000 + snap(Int(s.height / hourHeight * 60)) / 15
    }

    private func dragChanged(_ translation: CGSize) {
        if !active {
            withAnimation(Motion.snappy) { active = true }
            selected = nil
            app.eventDragActive = true
        }
        // 1:1 – der Termin bleibt dort, wo er gegriffen wurde
        drag = translation
    }

    private func dragEnded(_ translation: CGSize) {
        app.eventDragActive = false
        let dayDelta = Int((translation.width / colWidth).rounded())
        let minDelta = snap(Int(translation.height / hourHeight * 60))
        guard dayDelta != 0 || minDelta != 0 else {
            withAnimation(Motion.momentum) { drag = .zero; active = false }
            return
        }
        let target = CGSize(width: CGFloat(dayDelta) * colWidth, height: CGFloat(minDelta) / 60 * hourHeight)
        withAnimation(Motion.pick(reduce, Motion.momentum)) { drag = target } completion: {
            commitMove(dayDelta: dayDelta, minDelta: minDelta)
        }
    }

    #if os(macOS)
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { dragChanged($0.translation) }
            .onEnded { dragEnded($0.translation) }
    }
    #else
    /// iPhone: erst lange drücken, dann ziehen – sonst kollidiert es mit dem Scrollen.
    private var moveGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    if !active { withAnimation(Motion.snappy) { active = true }; selected = nil; app.eventDragActive = true }
                case .second(true, let d?):
                    dragChanged(d.translation)
                default: break
                }
            }
            .onEnded { value in
                if case .second(true, let d?) = value { dragEnded(d.translation) } else {
                    app.eventDragActive = false
                    withAnimation(Motion.momentum) { drag = .zero; active = false }
                }
            }
    }
    #endif

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { v in
                if !active { active = true }
                let minH = 15 / 60 * hourHeight - CGFloat(segment.endMin - segment.startMin) / 60 * hourHeight
                resize = max(minH, v.translation.height)
            }
            .onEnded { v in
                let delta = snap(Int(v.translation.height / hourHeight * 60))
                guard delta != 0 else { withAnimation(Motion.standard) { resize = 0; active = false }; return }
                withAnimation(Motion.standard) { resize = CGFloat(delta) / 60 * hourHeight } completion: {
                    let newEnd = event.end.adding(minutes: delta)
                    do {
                        try calendar.move(event, to: event.start, end: max(newEnd, event.start.adding(minutes: 15)))
                        app.sync.reconcile()
                    } catch { app.showToast(error.localizedDescription, error: true) }
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { resize = 0; active = false }
                }
            }
    }

    private func commitMove(dayDelta: Int, minDelta: Int) {
        let newStart = event.start.adding(days: dayDelta).adding(minutes: minDelta)
        let newEnd = event.end.adding(days: dayDelta).adding(minutes: minDelta)
        do {
            try calendar.move(event, to: newStart, end: newEnd)
            app.sync.reconcile()
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { drag = .zero; active = false }
        } catch {
            app.showToast(error.localizedDescription, error: true)
            withAnimation(Motion.momentum) { drag = .zero; active = false }
        }
    }
}

struct EventPopover: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(FocusTimer.self) private var timer
    let event: CalEvent
    var dismiss: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(event.title).font(.headline).fixedSize(horizontal: false, vertical: true)
            Label(event.isAllDay ? Fmt.dayLong(event.start) : "\(Fmt.dayShort(event.start)), \(Fmt.time(event.start))–\(Fmt.time(event.end))", systemImage: "clock")
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse") }
            Label(event.calendarTitle, systemImage: "calendar").foregroundStyle(event.calendarColor)
            if let m = store.module(event.moduleID) {
                Button { app.openModule(m.id); dismiss() } label: {
                    Label(m.name, systemImage: "book.closed").foregroundStyle(m.color.color)
                }.buttonStyle(.borderless)
            }
            if !event.notes.isEmpty {
                Text(event.notes).font(.callout).foregroundStyle(.secondary).lineLimit(6)
            }
            if event.link?.kind == .block, let id = event.link?.id, let b = store.blocks.first(where: { $0.id == id }),
               b.status == .planned, event.end > Date(), !timer.isRunning, let mid = event.moduleID {
                Divider()
                Button { timer.start(moduleID: mid, minutes: max(15, b.minutes), blockID: b.id); dismiss() } label: {
                    Label("Fokus starten", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            if !event.isAllDay, case let item = app.trackItem(for: event), item.attendable {
                Divider()
                AttendanceSection(item: item)
            }
            Divider()
            HStack {
                if event.editable {
                    Button("Bearbeiten …") { app.sheet = .editEvent(event.id); dismiss() }
                    Spacer()
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                } else {
                    Text("Schreibgeschützter Kalender").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .font(.callout)
        .padding(16)
        .frame(width: 300, alignment: .leading)
        .confirmationDialog("Termin „\(event.title)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { delete(future: false) }
            if event.isRecurring { Button("Alle zukünftigen löschen", role: .destructive) { delete(future: true) } }
        } message: {
            Text("Der Termin wird auch aus Apple Kalender entfernt.")
        }
    }

    private func delete(future: Bool) {
        do {
            try calendar.delete(event, futureEvents: future)
            app.sync.reconcile()
            app.showToast("Termin gelöscht", symbol: "trash")
        } catch { app.showToast(error.localizedDescription, error: true) }
        dismiss()
    }
}

// MARK: - Monat

struct MonthGridView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    let month: Date
    var openDay: (Date) -> Void

    var body: some View {
        let gridStart = month.startOfWeek
        let days = (0..<42).map { gridStart.adding(days: $0) }
        let events = calendar.events(from: gridStart, to: gridStart.adding(days: 42))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(1...7, id: \.self) { wd in
                    Text(Fmt.weekday(wd, short: true)).scaledFont(size: 12, weight: .semibold).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
            }
            Divider()
            GeometryReader { geo in
                let h = geo.size.height / 6
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                    ForEach(days, id: \.self) { d in
                        let evs = events.filter { $0.start < d.endOfDay && $0.end > d.startOfDay || ($0.isAllDay && $0.start.isSameDay(d)) }
                        MonthCell(day: d, inMonth: Calendar.kompass.isDate(d, equalTo: month, toGranularity: .month), events: evs, height: h)
                            .onTapGesture(count: 2) { openDay(d) }
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { openDay(d) }
                    }
                }
            }
        }
    }
}

struct MonthCell: View {
    @Environment(DataStore.self) private var store
    let day: Date
    let inMonth: Bool
    let events: [CalEvent]
    let height: CGFloat

    var body: some View {
        let maxRows = max(1, Int((height - 30) / 17))
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text("\(Calendar.kompass.component(.day, from: day))")
                    .scaledFont(size: 12, weight: day.isToday ? .bold : .medium)
                    .foregroundStyle(day.isToday ? Color.white : (inMonth ? Color.primary : Color.secondary))
                    .frame(minWidth: 22, minHeight: 22)
                    .background(Circle().fill(day.isToday ? Color.red : .clear))
            }
            ForEach(events.prefix(maxRows)) { e in
                let c = e.moduleID.map { store.color(for: $0) } ?? e.calendarColor
                HStack(spacing: 4) {
                    if e.isAllDay {
                        Text(e.title).scaledFont(size: 10.5, weight: .medium).lineLimit(1)
                            .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 3).fill(c.opacity(0.25)))
                    } else {
                        Circle().fill(c).frame(width: 6, height: 6)
                        Text(e.title).scaledFont(size: 10.5).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Fmt.time(e.start)).scaledFont(size: 9.5).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            if events.count > maxRows {
                Text("+\(events.count - maxRows) weitere").scaledFont(size: 10).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(height: height, alignment: .top)
        .background(day.isWeekend ? Color.primary.opacity(0.02) : Color.clear)
        .overlay(Rectangle().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .opacity(inMonth ? 1 : 0.55)
        .contentShape(Rectangle())
    }
}

/// Fester Arbeitsblock im Raster – Klick zeigt „Wahrgenommen?“.
struct WorkBlockCell: View {
    @Environment(AppModel.self) private var app
    let item: TrackItem
    let width: CGFloat
    let height: CGFloat
    @State private var show = false

    var body: some View {
        let confirmed = app.isConfirmed(item)
        let skipped = !confirmed && app.isSkipped(item)
        Button { show.toggle() } label: {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.gray.opacity(confirmed ? 0.22 : 0.12))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color.gray.opacity(show ? 0.6 : 0), lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: confirmed ? "checkmark.circle.fill" : (skipped ? "xmark.circle" : "briefcase"))
                            .foregroundStyle(confirmed ? Color.green : Color.secondary)
                        Text(item.title).strikethrough(skipped)
                    }
                    .scaledFont(size: 10, weight: .medium)
                    .foregroundStyle(.secondary)
                    .padding(4)
                }
                .frame(width: width, height: max(14, height))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arbeitszeit: \(item.title)")
        .accessibilityValue(confirmed ? "wahrgenommen" : (skipped ? "nicht wahrgenommen" : "offen"))
        .popover(isPresented: $show, arrowEdge: .trailing) { WorkBlockPopover(item: item).compactPopover() }
        .help("Feste Arbeitszeit – klicken zum Bestätigen")
    }
}
