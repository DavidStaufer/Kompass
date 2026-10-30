import SwiftUI
import Charts
import UniformTypeIdentifiers
import QuickLook

struct ModuleDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.isCompactLayout) private var compact
    let moduleID: UUID

    var body: some View {
        @Bindable var app = app
        if let m = store.module(moduleID) {
            VStack(spacing: 0) {
                ModuleHeader(module: m)
                    .padding(.horizontal, compact ? 16 : 28)
                    .padding(.top, compact ? 8 : 20)
                    .padding(.bottom, 12)
                if compact {
                    // iPhone: Reiter als wischbare Chips
                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            ForEach(ModuleTab.allCases) { t in
                                FilterChip(label: t.label, selected: app.moduleTab == t) {
                                    withAnimation(Motion.snappy) { app.moduleTab = t }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.bottom, 10)
                } else {
                    Picker("Bereich", selection: $app.moduleTab) {
                        ForEach(ModuleTab.allCases) { t in Text(t.label).tag(t) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 520)
                    .padding(.bottom, 12)
                }
                Divider()
                Group {
                    switch app.moduleTab {
                    case .overview: ModuleOverviewTab(module: m)
                    case .topics: TopicsTab(module: m)
                    case .materials: MaterialsTab(module: m)
                    case .learn: LearnTab(module: m)
                    case .docs: DocsTab(module: m)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .navigationTitle(m.name)
            .inlineNavigationTitle()
        } else {
            ContentUnavailableView("Modul nicht gefunden", systemImage: "questionmark.folder")
        }
    }
}

struct ModuleHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.isCompactLayout) private var compact
    var module: Module

    var body: some View {
        let p = ProgressEngine.progress(for: module, store: store)
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                ProgressRing(value: p.overall, color: module.color.color, lineWidth: compact ? 5 : 6, size: compact ? 46 : 56)
                Text("\(Int(p.overall * 100))").scaledFont(size: 17, weight: .bold, design: .rounded).monospacedDigit()
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(module.name).scaledFont(size: compact ? 21 : 26, weight: .bold).tracking(-0.5).lineLimit(compact ? 2 : 1)
                    if !module.code.isEmpty { Pill(text: module.code, color: module.color.color) }
                }
                FlowLayout(spacing: 10) {
                    Label(p.status.label, systemImage: p.status.symbol).foregroundStyle(p.status.color)
                    Text("\(module.ects.formatted()) ECTS")
                    if !module.lecturer.isEmpty { Text(module.lecturer) }
                    if let e = p.examDate { Label("Klausur \(Fmt.relative(e)) · \(Fmt.dayShort(e))", systemImage: "graduationcap") }
                }
                .scaledFont(size: 12, weight: .medium)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                app.assistant.scopeModuleID = module.id
                withAnimation(Motion.standard) { app.showAssistant = true }
            } label: {
                Label("Fragen", systemImage: "sparkles")
                    .labelStyle(AdaptiveIconLabelStyle(iconOnly: compact))
            }
            .help("Assistent zu diesem Modul")
            Menu {
                Button("Frist hinzufügen …") { app.sheet = .deadline(nil, moduleID: module.id, kind: nil) }
                Button("Klausurtermin eintragen …") { app.sheet = .deadline(nil, moduleID: module.id, kind: .klausur) }
                Button("Zeit buchen …") { app.sheet = .logWork(LogPreset(target: .module(module.id))) }
                Divider()
                Button("Modul bearbeiten …") { app.sheet = .editModule(module.id) }
                Button(module.archived ? "Wiederherstellen" : "Archivieren") { store.updateModule(module.id) { $0.archived.toggle() } }
            } label: { Label("Weitere Aktionen", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                .plainMenu()
        }
    }
}

// MARK: - Übersicht

struct ModuleOverviewTab: View {
    @Environment(DataStore.self) private var store
    var module: Module

    var body: some View {
        let p = ProgressEngine.progress(for: module, store: store)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Karten als eigene Views: ViewThatFits baut beide Varianten, gerechnet wird nur in der sichtbaren.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        VStack(spacing: 20) { ModuleProgressCard(module: module, progress: p); ModuleStudyChart(module: module) }.frame(minWidth: 380)
                        VStack(spacing: 20) { ModuleNextCard(module: module); ModuleSessionsCard(module: module) }.frame(width: 330)
                    }
                    VStack(spacing: 20) {
                        ModuleProgressCard(module: module, progress: p); ModuleNextCard(module: module)
                        ModuleStudyChart(module: module); ModuleSessionsCard(module: module)
                    }
                }
                if !module.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("Notizen", symbol: "note.text")
                        Text(module.notes).textSelection(.enabled)
                    }
                    .card()
                }
            }
            .pagePadding()
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ModuleProgressCard: View {
    @Environment(DataStore.self) private var store
    @Environment(FocusTimer.self) private var timer
    let module: Module
    let progress: ModuleProgress

    var body: some View {
        let p = progress
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Fortschritt", symbol: "chart.line.uptrend.xyaxis") {
                if p.examDate != nil {
                    Text("Soll heute: \(Fmt.percent(p.expected))").font(.caption).foregroundStyle(.secondary)
                }
            }
            ProgressLine(label: "Gesamt", value: p.overall, color: module.color.color, detail: Fmt.percent(p.overall), marker: p.examDate != nil ? p.expected : nil)
            ProgressLine(label: "Themen-Sicherheit", value: p.topicConfidence ?? 0, color: .blue,
                         detail: p.topicsTotal == 0 ? "keine Themen" : "\(Fmt.percent(p.topicConfidence ?? 0)) · \(p.topicsCovered)/\(p.topicsTotal) behandelt")
            ProgressLine(label: "Materialien bearbeitet", value: p.materialsTotal > 0 ? Double(p.materialsStudied) / Double(p.materialsTotal) : 0, color: .teal,
                         detail: "\(p.materialsStudied)/\(p.materialsTotal)")
            ProgressLine(label: "Quiz-Schnitt", value: p.quizAverage ?? 0, color: .purple, detail: p.quizAverage.map(Fmt.percent) ?? "noch kein Quiz")
            ProgressLine(label: "Karteikarten gefestigt", value: p.cardsTotal > 0 ? Double(p.cardsMature) / Double(p.cardsTotal) : 0, color: .orange,
                         detail: "\(p.cardsMature)/\(p.cardsTotal)")
            ProgressLine(label: "Lernzeit bis zur Klausur", value: p.timeRatio, color: .green,
                         detail: "\(Fmt.hours(p.minutesTotal)) / \(Fmt.hours(p.targetMinutesTotal))")
            HStack {
                Text("Diese Woche: \(Fmt.hours(p.minutesThisWeek)) von \(Fmt.hours(p.goalMinutesWeek))").font(.callout)
                Spacer()
                if !timer.isRunning {
                    Button { timer.start(moduleID: module.id, minutes: store.prefs.defaultFocusMinutes) } label: { Label("Fokus starten", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(module.color.color)
                }
            }
        }
        .card()
    }
}

private struct ModuleStudyChart: View {
    @Environment(DataStore.self) private var store
    let module: Module

    var body: some View {
        let weeks = (0..<8).reversed().map { Date().startOfWeek.adding(weeks: -$0) }
        let data = weeks.map { w in (w, store.minutes(moduleID: module.id, from: w, to: w.adding(days: 7))) }
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Lernzeit der letzten Wochen", symbol: "chart.bar")
            Chart {
                ForEach(data, id: \.0) { w, m in
                    BarMark(x: .value("KW", "KW\(w.weekNumber)"), y: .value("Stunden", Double(m) / 60))
                        .foregroundStyle(module.color.color.gradient)
                        .cornerRadius(4)
                        .accessibilityLabel("KW \(w.weekNumber)")
                        .accessibilityValue(Fmt.hours(m))
                }
                RuleMark(y: .value("Ziel", module.weeklyGoalHours))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .annotation(position: .top, alignment: .leading) { Text("Ziel").font(.caption2).foregroundStyle(.secondary) }
                    .accessibilityLabel("Wochenziel")
                    .accessibilityValue("\(module.weeklyGoalHours.formatted()) Stunden")
            }
            .frame(height: 160)
        }
        .card()
    }
}

private struct ModuleNextCard: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let module: Module

    var body: some View {
        let dls = store.deadlines.filter { $0.moduleID == module.id && !$0.done }.sorted { $0.date < $1.date }
        let blocks = store.blocks.filter { $0.moduleID == module.id && $0.status == .planned && $0.end > Date() }.sorted { $0.start < $1.start }.prefix(3)
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Als Nächstes", symbol: "flag") {
                Button { app.sheet = .deadline(nil, moduleID: module.id, kind: nil) } label: { Label("Neue Frist", systemImage: "plus").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Neue Frist")
            }
            if dls.isEmpty && blocks.isEmpty {
                Text("Keine Fristen. Trag den Klausurtermin ein, damit Kompass rückwärts planen kann.").font(.callout).foregroundStyle(.secondary)
                Button("Klausurtermin eintragen") { app.sheet = .deadline(nil, moduleID: module.id, kind: .klausur) }
            }
            ForEach(dls.prefix(4)) { d in
                Button { app.sheet = .deadline(d.id, moduleID: nil, kind: nil) } label: {
                    HStack {
                        Image(systemName: d.kind.symbol).foregroundStyle(d.kind.tint).frame(width: 18).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(d.title).font(.callout.weight(.medium))
                            Text(Fmt.dateTime(d.date, allDay: d.allDay)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Fmt.relative(d.date)).font(.caption.weight(.semibold)).foregroundStyle(Date().daysUntil(d.date) <= 3 ? .orange : .secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(Array(blocks)) { b in
                HStack {
                    Image(systemName: "brain.head.profile").foregroundStyle(module.color.color).frame(width: 18).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Lernblock\(b.focus.isEmpty ? "" : ": \(b.focus)")").font(.callout)
                        Text("\(Fmt.dayShort(b.start)), \(Fmt.time(b.start))–\(Fmt.time(b.end))").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

private struct ModuleSessionsCard: View {
    @Environment(AppModel.self) private var app
    let module: Module

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Veranstaltungen", symbol: "building.columns") {
                Button { app.sheet = .editModule(module.id) } label: { Label("Veranstaltungen bearbeiten", systemImage: "pencil").labelStyle(.iconOnly) }
                    .buttonStyle(.borderless)
                    .help("Veranstaltungen bearbeiten")
            }
            if module.sessions.isEmpty {
                Text("Noch keine Vorlesungs- oder Übungszeiten. Sie werden als wiederkehrende Termine in Apple Kalender eingetragen.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach(module.sessions.sorted { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }) { s in
                HStack {
                    Text(s.kind.label).font(.callout.weight(.medium)).frame(width: 84, alignment: .leading)
                    Text("\(Fmt.weekday(s.weekday, short: true)) \(Fmt.hm(s.startMinutes))–\(Fmt.hm(s.endMinutes))").font(.callout.monospacedDigit())
                    if s.biweekly { Pill(text: "14-tägl.") }
                    Spacer()
                    Text(s.room).font(.caption).foregroundStyle(.secondary)
                    if s.eventIdentifier != nil {
                        Image(systemName: "calendar").font(.caption2).foregroundStyle(.tertiary).accessibilityLabel("Im Kalender")
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .card()
    }
}

struct ProgressLine: View {
    var label: String
    var value: Double
    var color: Color
    var detail: String
    var marker: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).scaledFont(size: 12, weight: .medium)
                Spacer()
                Text(detail).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            BarMeter(value: value, color: color, height: 6, marker: marker)
        }
    }
}

// MARK: - Themen

struct TopicsTab: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    var module: Module
    @State private var newTopics = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Bewerte ehrlich, wie sicher du dich fühlst. Quizze und Karteikarten passen die Werte automatisch an.")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button { app.sheet = .generator(.topics, module.id, []) } label: { Label("Aus Materialien erkennen", systemImage: "sparkles") }
                }
                if module.topics.isEmpty {
                    ContentUnavailableView("Noch keine Themen", systemImage: "list.bullet.indent",
                                           description: Text("Füge die Kapitel der Vorlesung hinzu – oder lass sie von der KI aus deinen Folien erkennen."))
                        .frame(minHeight: 200)
                }
                VStack(spacing: 0) {
                    ForEach(module.topics) { t in
                        TopicRow(moduleID: module.id, topic: t, color: module.color.color)
                        if t.id != module.topics.last?.id { Divider() }
                    }
                }
                .card(padding: 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Themen hinzufügen (eine pro Zeile)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $newTopics)
                        .font(.body)
                        .frame(height: 80)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.subtleFill))
                    Button("Hinzufügen") {
                        let lines = newTopics.split(separator: "\n").map { String($0).trimmed }.filter { !$0.isEmpty }
                        store.updateModule(module.id) { m in m.topics += lines.map { Topic(title: $0) } }
                        newTopics = ""
                    }
                    .disabled(newTopics.trimmed.isEmpty)
                }
            }
            .pagePadding()
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

struct TopicRow: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.isCompactLayout) private var compact
    let moduleID: UUID
    let topic: Topic
    let color: Color
    @State private var editing = false
    @State private var title = ""

    var body: some View {
        HStack(spacing: 12) {
            CheckToggle(isOn: Binding(get: { topic.covered }, set: { v in update { $0.covered = v } }), tint: color)
                .help("In der Vorlesung behandelt")
            if editing {
                TextField("Titel", text: $title).onSubmit { update { $0.title = title.trimmed.isEmpty ? $0.title : title.trimmed }; editing = false }
            } else {
                Text(topic.title).font(.callout).foregroundStyle(topic.covered ? .primary : .secondary)
                    .onTapGesture(count: 2) { title = topic.title; editing = true }
                    .accessibilityAction(named: "Umbenennen") { title = topic.title; editing = true }
            }
            Spacer()
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { i in
                    Button { setLevel(i) } label: {
                        Capsule()
                            .fill(i <= topic.levelIndex && topic.confidence > 0 ? levelColor(topic.levelIndex) : Color.primary.opacity(0.1))
                            .frame(width: compact ? 16 : 22, height: 8)
                            .padding(.vertical, compact ? 8 : 0)
                    }
                    .buttonStyle(.pressable)
                    .help(Topic.levels[i].label)
                }
            }
            // VoiceOver: ein einstellbarer Wert statt fünf unbeschrifteter Knöpfe
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Sicherheit")
            .accessibilityValue(topic.confidence > 0 ? topic.levelLabel : "nicht bewertet")
            .accessibilityAdjustableAction { direction in
                let current = topic.confidence > 0 ? topic.levelIndex : -1
                switch direction {
                case .increment: setLevel(min(4, current + 1))
                case .decrement: setLevel(max(0, current - 1))
                @unknown default: break
                }
            }
            if !compact { Text(topic.levelLabel).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading) }
            Menu {
                Button("Umbenennen") { title = topic.title; editing = true }
                Button("Abfragen lassen") { app.assistant.ask("Frag mich zum Thema „\(topic.title)“ ab – eine Frage nach der anderen.", scope: moduleID) }
                Divider()
                Button("Löschen", role: .destructive) { store.updateModule(moduleID) { $0.topics.removeAll { $0.id == topic.id } } }
            } label: { Label("Weitere Aktionen", systemImage: "ellipsis").labelStyle(.iconOnly) }
                .plainMenu()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func setLevel(_ i: Int) {
        withAnimation(Motion.snappy) { update { $0.confidence = Topic.levels[i].value; $0.lastReviewed = Date() } }
    }

    private func levelColor(_ i: Int) -> Color { [.red, .red, .orange, .yellow, .green][i] }

    private func update(_ change: (inout Topic) -> Void) {
        store.updateModule(moduleID) { m in
            if let i = m.topics.firstIndex(where: { $0.id == topic.id }) { change(&m.topics[i]) }
        }
    }
}

// MARK: - Materialien

struct MaterialsTab: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    var module: Module
    @State private var importing = false
    @State private var importKind: MaterialKind?
    @State private var dropTargeted = false
    @State private var pasteSheet = false
    @State private var search = ""
    @State private var preview: URL?

    var body: some View {
        let filtered = module.materials.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
        let groups = MaterialKind.allCases.compactMap { k -> (MaterialKind, [Material])? in
            let items = filtered.filter { $0.kind == k }.sorted { ($0.lectureNumber ?? 999, $0.title) < ($1.lectureNumber ?? 999, $1.title) }
            return items.isEmpty ? nil : (k, items)
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                WueModuleBanner(module: module)
                dropZone
                if !module.materials.isEmpty {
                    TextField("Materialien durchsuchen", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                }
                ForEach(groups, id: \.0) { kind, items in
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(kind.plural) (\(items.count))", systemImage: kind.symbol).scaledFont(size: 14, weight: .semibold)
                        VStack(spacing: 0) {
                            ForEach(items) { mat in
                                MaterialRow(module: module, material: mat) { preview = Paths.materialFile(module.id, mat) }
                                if mat.id != items.last?.id { Divider().padding(.leading, 40) }
                            }
                        }
                        .card(padding: 4)
                    }
                }
            }
            .pagePadding()
            .frame(maxWidth: 960, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let n = MaterialImporter.importFiles(urls, moduleID: module.id, kind: importKind, store: store)
                if n > 0 { app.showToast("\(n) Datei\(n == 1 ? "" : "en") hinzugefügt – Text wird gelesen …", symbol: "doc.badge.plus") }
            }
        }
        .sheet(isPresented: $pasteSheet) { PasteMaterialSheet(moduleID: module.id) }
        .quickLookPreview($preview)
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down.on.square").scaledFont(size: 28).foregroundStyle(dropTargeted ? Color.accentColor : .secondary)
                .accessibilityHidden(true)
            Text(Platform.isMac ? "Dateien oder Ordner hierher ziehen" : "Materialien hinzufügen").scaledFont(size: 14, weight: .semibold)
            Text("PDF (auch Scans), PowerPoint, Word, Bilder, Notebooks, Text – Vorlesungen, Übungen, Altklausuren, Probeklausuren …")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Menu("Dateien wählen …") {
                    Button("Art automatisch erkennen") { importKind = nil; importing = true }
                    Divider()
                    ForEach(MaterialKind.allCases) { k in Button(k.label) { importKind = k; importing = true } }
                }
                .fixedSize()
                Button("Text einfügen …") { pasteSheet = true }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(dropTargeted ? Color.accentColor : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                .background(RoundedRectangle(cornerRadius: 14).fill(dropTargeted ? Color.accentColor.opacity(0.06) : Color.clear))
        )
        .scaleEffect(dropTargeted ? 1.01 : 1)
        .animation(Motion.snappy, value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            let n = MaterialImporter.importFiles(urls, moduleID: module.id, store: store)
            if n > 0 { app.showToast("\(n) Datei\(n == 1 ? "" : "en") hinzugefügt – Text wird gelesen …", symbol: "doc.badge.plus") }
            return n > 0
        } isTargeted: { dropTargeted = $0 }
    }
}

struct MaterialRow: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    let module: Module
    let material: Material
    var onOpen: () -> Void = {}
    @State private var renaming = false
    @State private var title = ""
    @State private var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: material.kind.symbol).foregroundStyle(module.color.color).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("Titel", text: $title).onSubmit { store.updateMaterial(material.id) { $0.title = title.trimmed.isEmpty ? $0.title : title.trimmed }; renaming = false }
                } else {
                    Text(material.title).font(.callout.weight(.medium)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    switch material.status {
                    case .extracting: ProgressView().controlSize(.mini); Text("Text wird gelesen …")
                    case .empty: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange); Text("Kein Text erkannt")
                    case .failed: Text("Fehler beim Lesen").foregroundStyle(.red)
                    case .ready:
                        if let p = material.pageCount { Text("\(p) Seiten") }
                        Text("\(material.charCount.formatted()) Zeichen")
                        if material.usedOCR == true { Text("· Texterkennung") }
                    }
                    Text("· \(material.fileExtension.uppercased())")
                    if material.sourceKey != nil { Label("WueCampus", systemImage: "graduationcap").labelStyle(.titleAndIcon) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            CheckToggle(isOn: Binding(get: { material.studied }, set: { v in store.updateMaterial(material.id) { $0.studied = v } }), tint: .green)
                .help("Als bearbeitet markieren")
            Menu {
                Button("Öffnen") { onOpen() }
                #if os(macOS)
                Button("Im Finder zeigen") { Platform.reveal(Paths.materialFile(module.id, material)) }
                #endif
                Divider()
                Button("Zusammenfassen") { app.sheet = .generator(.summary, module.id, [material.id]) }
                Button("Karteikarten erstellen") { app.sheet = .generator(.flashcards, module.id, [material.id]) }
                Button("Mehr Karteikarten mit Claude") {
                    var options = GeneratorOptions()
                    options.count = 10
                    app.claude.enqueue(.flashcards, module: module, materialIDs: [material.id], options: options)
                    app.showToast("10 weitere Karten kommen mit dem nächsten Claude-Durchlauf", symbol: "sparkles")
                }
                Button("Quiz erstellen") { app.sheet = .generator(.quiz, module.id, [material.id]) }
                if material.kind == .altklausur || material.kind == .probeklausur {
                    Button("Probeklausur in diesem Stil") { app.sheet = .generator(.mockExam, module.id, [material.id]) }
                }
                Button("Im Chat besprechen") { app.assistant.ask("Lies „\(material.title)“ (id \(material.id.uuidString)) und erkläre mir die wichtigsten Inhalte.", scope: module.id) }
                Divider()
                Menu("Art ändern") {
                    ForEach(MaterialKind.allCases) { k in Button(k.label) { store.updateMaterial(material.id) { $0.kind = k } } }
                }
                Button("Umbenennen") { title = material.title; renaming = true }
                Button("Text neu einlesen") { MaterialImporter.extract(materialID: material.id, moduleID: module.id, file: Paths.materialFile(module.id, material), store: store) }
                Divider()
                Button("Löschen …", role: .destructive) { confirmDelete = true }
            } label: { Label("Weitere Aktionen", systemImage: "ellipsis.circle").labelStyle(.iconOnly) }
                .plainMenu()
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen() }
        .accessibilityAction(named: "Öffnen") { onOpen() }
        .confirmationDialog("„\(material.title)“ löschen?", isPresented: $confirmDelete) {
            Button("Löschen", role: .destructive) { store.deleteMaterial(material.id) }
        } message: { Text("Die Kopie in Kompass wird gelöscht. Deine Originaldatei bleibt erhalten.") }
    }
}

struct PasteMaterialSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let moduleID: UUID
    @State private var title = ""
    @State private var kind: MaterialKind = .notiz
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SheetHeader(title: "Text als Material") { EmptyView() }
            HStack {
                TextField("Titel", text: $title)
                Picker("Art", selection: $kind) { ForEach(MaterialKind.allCases) { Text($0.label).tag($0) } }.labelsHidden().frame(width: 160)
            }
            TextEditor(text: $text).font(.body).frame(minHeight: 260)
                .scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.subtleFill))
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Hinzufügen") {
                    _ = MaterialImporter.addText(text, title: title.trimmed.isEmpty ? "Notiz" : title.trimmed, kind: kind, moduleID: moduleID, store: store)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(text.trimmed.isEmpty)
            }
        }
        .padding(20).macFrame(width: 600)
    }
}
