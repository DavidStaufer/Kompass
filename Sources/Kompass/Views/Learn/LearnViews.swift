import SwiftUI
import UniformTypeIdentifiers

// MARK: - Lernen-Tab im Modul

struct LearnTab: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    var module: Module

    var body: some View {
        let quizzes = store.quizzes.filter { $0.moduleID == module.id && !$0.questions.isEmpty }.sorted { $0.createdAt > $1.createdAt }
        let cards = store.flashcards.filter { $0.moduleID == module.id }
        let due = cards.filter { $0.due <= Date() }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ClaudePendingCard(moduleID: module.id)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach([GeneratorKind.flashcards, .summary, .cheatSheet, .mustKnow, .quiz, .mockExam, .studyPlan]) { k in
                        GeneratorTile(kind: k) { app.sheet = .generator(k, module.id, []) }
                    }
                    GeneratorTileView(symbol: "bubble.left.and.text.bubble.right", title: "Abfragen im Chat",
                                      blurb: "Die KI fragt dich Schritt für Schritt ab und bewertet deine Antworten.") {
                        app.assistant.ask("Frag mich zu \(module.name) ab. Starte mit meinen schwächsten Themen, eine Frage nach der anderen.", scope: module.id)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Karteikarten", symbol: "rectangle.on.rectangle.angled") {
                        Button { app.selection = .cards } label: { Text("Alle verwalten").font(.callout) }.buttonStyle(.borderless)
                    }
                    HStack(spacing: 20) {
                        VStack(alignment: .leading) {
                            Text("\(due.count)").scaledFont(size: 28, weight: .bold, design: .rounded)
                            Text("fällig").font(.caption).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading) {
                            Text("\(cards.filter(\.isMature).count)/\(cards.count)").scaledFont(size: 28, weight: .bold, design: .rounded)
                            Text("gefestigt").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { app.sheet = .cardReview(module.id) } label: { Label("Jetzt lernen", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(module.color.color)
                            .disabled(due.isEmpty)
                    }
                }
                .card()

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel("Quizze", symbol: "checklist")
                    if quizzes.isEmpty {
                        Text("Noch keine Quizze. Erstelle eins aus deinen Materialien.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(quizzes) { q in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(q.title).font(.callout.weight(.medium))
                                Text("\(q.questions.count) Fragen · \(Fmt.dayShort(q.createdAt))\(q.attempts.isEmpty ? "" : " · \(q.attempts.count)× gemacht")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if let best = q.bestScore { Pill(text: "Bestes: \(Fmt.percent(best))", color: best >= 0.8 ? .green : (best >= 0.5 ? .orange : .red)) }
                            Button("Starten") { app.sheet = .quiz(q.id) }
                            Menu {
                                Button("Löschen", role: .destructive) { store.quizzes.removeAll { $0.id == q.id } }
                            } label: { Label("Weitere Aktionen", systemImage: "ellipsis").labelStyle(.iconOnly) }
                                .plainMenu()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .card()
            }
            .pagePadding()
            .frame(maxWidth: 1000, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// Auswahl im Erstellen-Fenster: Claude über das Abo oder DeepSeek über die API.
struct EnginePicker: View {
    @Binding var useClaude: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Erstellen mit", selection: $useClaude) {
                Text("Claude").tag(true)
                Text("DeepSeek").tag(false)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 280)
            Text(useClaude
                 ? "Über dein Claude-Abo, ohne API-Kosten. Fertig mit dem nächsten Durchlauf (täglich um 7 Uhr) – sofort, wenn du in der Claude-App „Jetzt ausführen“ wählst."
                 : "Sofort, kostet DeepSeek-Guthaben.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Offene Claude-Aufträge eines Moduls.
struct ClaudePendingCard: View {
    @Environment(ClaudeBridge.self) private var claude
    let moduleID: UUID

    var body: some View {
        let items = claude.pending(for: moduleID)
        if !items.isEmpty {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Claude erstellt beim nächsten Durchlauf").scaledFont(size: 13, weight: .semibold)
                    ForEach(items) { r in
                        HStack {
                            Text(r.label + (r.materialIDs.isEmpty ? "" : " · \(r.materialIDs.count) Material\(r.materialIDs.count == 1 ? "" : "ien")"))
                                .font(.callout)
                            Spacer()
                            Button("Zurückziehen") { claude.cancel(r) }.buttonStyle(.borderless).font(.caption)
                        }
                    }
                }
            }
            .card(padding: 14)
        }
    }
}

struct APIKeyHint: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "key.fill").foregroundStyle(.orange).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("DeepSeek-API-Key fehlt").font(.headline)
                Text("Für KI-Funktionen trage deinen Key in den Einstellungen (⌘,) → KI ein. Er wird sicher im Schlüsselbund gespeichert.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            OpenSettingsButton()
        }
        .card()
    }
}

struct GeneratorTile: View {
    var kind: GeneratorKind
    var action: () -> Void
    var body: some View {
        GeneratorTileView(symbol: kind.symbol, title: kind.label, blurb: kind.blurb, action: action)
    }
}

struct GeneratorTileView: View {
    var symbol: String
    var title: String
    var blurb: String
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol).scaledFont(size: 20, weight: .medium).foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(title).scaledFont(size: 14, weight: .semibold)
                Text(blurb).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            .card(padding: 14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor.opacity(hover ? 0.5 : 0), lineWidth: 1))
        }
        .buttonStyle(.pressable)
        .onHover { h in withAnimation(Motion.snappy) { hover = h } }
    }
}

// MARK: - Dokumente-Tab

struct DocsTab: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    var module: Module

    var body: some View {
        let docs = store.docs.filter { $0.moduleID == module.id }.sorted { $0.createdAt > $1.createdAt }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Zusammenfassungen, Probeklausuren, Lernpläne und Notizen – von dir oder der KI.").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Menu {
                        ForEach([GeneratorKind.summary, .cheatSheet, .mustKnow, .mockExam, .studyPlan]) { k in
                            Button { app.sheet = .generator(k, module.id, []) } label: { Label(k.label, systemImage: k.symbol) }
                        }
                        Divider()
                        Button("Leere Notiz") {
                            let d = StudyDoc(moduleID: module.id, kind: .notiz, title: "Notiz \(Fmt.dayMonth(Date()))", markdown: "")
                            store.docs.append(d)
                            app.sheet = .doc(d.id)
                        }
                    } label: { Label("Neu", systemImage: "plus") }
                        .fixedSize()
                }
                if docs.isEmpty {
                    ContentUnavailableView("Noch keine Dokumente", systemImage: "doc.text",
                                           description: Text("Lass dir eine Zusammenfassung oder Probeklausur aus deinen Materialien erstellen."))
                        .frame(minHeight: 240)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(docs) { d in
                        Button { app.sheet = .doc(d.id) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(d.kind.label, systemImage: d.kind.symbol).font(.caption.weight(.semibold)).foregroundStyle(module.color.color)
                                Text(d.title).scaledFont(size: 14, weight: .semibold).lineLimit(2).multilineTextAlignment(.leading)
                                Text(preview(d.markdown)).font(.caption).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Text(Fmt.dayShort(d.createdAt)).font(.caption2).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                            .card(padding: 14)
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button("Löschen", role: .destructive) { store.docs.removeAll { $0.id == d.id } }
                        }
                    }
                }
            }
            .pagePadding()
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func preview(_ md: String) -> String {
        md.components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.trimmed.isEmpty }.prefix(3)
            .joined(separator: " ").replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "- ", with: "")
    }
}

// MARK: - Generator

struct GeneratorSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let kind: GeneratorKind
    let moduleID: UUID
    let preselected: [UUID]

    @Environment(ClaudeBridge.self) private var claude
    /// Claude (über das Abo, beim nächsten Durchlauf) oder DeepSeek (sofort, API-Kosten)
    @AppStorage("generator.useClaude") private var useClaude = true
    @State private var selection: Set<UUID> = []
    @State private var options = GeneratorOptions()
    @State private var running = false
    @State private var chars = 0
    @State private var error: String?
    @State private var result: ChatAttachment?
    @State private var task: Task<Void, Never>?
    @State private var loaded = false

    var body: some View {
        let module = store.module(moduleID)
        let mats = module?.materials.filter { $0.status == .ready } ?? []
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(title: kind.label, subtitle: module?.name) { EmptyView() }
            if let result {
                resultView(result)
            } else if running {
                VStack(spacing: 14) {
                    ProgressView().controlSize(.large)
                    Text("Die KI arbeitet …").font(.headline)
                    Text(chars > 0 ? "\(chars.formatted()) Zeichen geschrieben" : "Liest \(selection.count) Material\(selection.count == 1 ? "" : "ien")")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Button("Abbrechen") { task?.cancel(); running = false }
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                Text(kind.blurb).foregroundStyle(.secondary)
                if Secrets.deepSeekEnabled { EnginePicker(useClaude: $useClaude) }
                optionsView
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Grundlage").scaledFont(size: 13, weight: .semibold)
                        Spacer()
                        Button("Alle") { selection = Set(mats.map(\.id)) }.buttonStyle(.borderless)
                        Button("Keine") { selection = [] }.buttonStyle(.borderless)
                    }
                    if mats.isEmpty {
                        Text("Noch keine lesbaren Materialien – die KI nutzt dann Allgemeinwissen. Lade Folien, Übungen oder Altklausuren hoch, um bessere Ergebnisse zu bekommen.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    let groups = MaterialKind.allCases.compactMap { k -> (kind: MaterialKind, items: [Material])? in
                        let items = mats.filter { $0.kind == k }
                        return items.isEmpty ? nil : (k, items)
                    }
                    List {
                        ForEach(groups, id: \.kind) { group in
                            Section(group.kind.plural) {
                                ForEach(group.items) { m in
                                    Toggle(isOn: $selection[contains: m.id]) {
                                        HStack {
                                            Text(m.title).lineLimit(1)
                                            Spacer()
                                            Text("\(m.charCount / 1000)k Zeichen").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .checkboxStyle()
                                }
                            }
                        }
                    }
                    .frame(height: 220)
                    .borderedList()
                    let total = mats.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.charCount }
                    if total > 90_000 {
                        Text("Viel Material (\(total / 1000)k Zeichen) – längere Texte werden anteilig gekürzt. Für beste Ergebnisse gezielt auswählen.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(result == nil ? "Abbrechen" : "Fertig") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if result == nil && !running {
                    Button(viaClaude ? "An Claude übergeben" : "Erstellen") { viaClaude ? queueForClaude() : start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!viaClaude && !Secrets.hasDeepSeekKey)
                }
            }
            if !viaClaude && !Secrets.hasDeepSeekKey { APIKeyHint() }
        }
        .padding(20)
        .macFrame(width: 600)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if !preselected.isEmpty { selection = Set(preselected) }
            else { selection = Set(mats.filter { kind.preferredKinds.contains($0.kind) }.map(\.id)) }
            switch kind {
            case .quiz: options.count = 10
            case .flashcards: options.count = 20
            default: break
            }
        }
    }

    @ViewBuilder
    private var optionsView: some View {
        Form {
            switch kind {
            case .quiz:
                Stepper("Fragen: \(options.count)", value: $options.count, in: 3...30)
                Picker("Schwierigkeit", selection: $options.difficulty) { Text("Leicht").tag(0); Text("Mittel").tag(1); Text("Klausurniveau").tag(2) }
                    .pickerStyle(.segmented)
                LabeledContent("Offene Fragen") {
                    HStack { Slider(value: $options.openShare, in: 0...1, step: 0.1); Text(Fmt.percent(options.openShare)).frame(width: 44) }
                }
            case .flashcards:
                Stepper("Karten: \(options.count)", value: $options.count, in: 5...60, step: 5)
            case .mockExam:
                Stepper("Bearbeitungszeit: \(options.minutes) min", value: $options.minutes, in: 30...240, step: 15)
                Picker("Schwierigkeit", selection: $options.difficulty) { Text("Leicht").tag(0); Text("Mittel").tag(1); Text("Klausurniveau").tag(2) }
                    .pickerStyle(.segmented)
            default:
                EmptyView()
            }
            if kind != .topics {
                TextField("Schwerpunkt (optional)", text: $options.focus, prompt: Text("z. B. Kapitel 3–5, Beweise, Rechenaufgaben"))
            }
        }
        .sheetForm()
        .frame(height: kind == .quiz ? 200 : (kind == .mockExam ? 160 : (kind == .topics ? 0 : 110)))
        .opacity(kind == .topics ? 0 : 1)
    }

    @ViewBuilder
    private func resultView(_ r: ChatAttachment) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").scaledFont(size: 44).foregroundStyle(.green)
                .symbolEffect(.bounce, value: result != nil)
                .accessibilityHidden(true)
            Text(r.label).font(.headline).multilineTextAlignment(.center)
            switch r.kind {
            case .quiz:
                Button { if let id = UUID(uuidString: r.id) { app.sheet = .quiz(id) } } label: { Label("Quiz starten", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .doc:
                Button { if let id = UUID(uuidString: r.id) { app.sheet = .doc(id) } } label: { Label("Öffnen", systemImage: "doc.text") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            case .cards:
                Button { app.sheet = .cardReview(moduleID) } label: { Label("Jetzt lernen", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            default:
                Button { app.openModule(moduleID, tab: .topics); dismiss() } label: { Text("Themen ansehen") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// Ohne DeepSeek geht alles über Claude.
    private var viaClaude: Bool { useClaude || !Secrets.deepSeekEnabled }

    private func queueForClaude() {
        guard let module = store.module(moduleID) else { return }
        claude.enqueue(kind, module: module, materialIDs: Array(selection), options: options)
        app.showToast("An Claude übergeben – kommt mit dem nächsten Durchlauf", symbol: "sparkles")
        dismiss()
    }

    private func start() {
        guard let module = store.module(moduleID) else { return }
        let mats = module.materials.filter { selection.contains($0.id) }
        error = nil
        running = true
        chars = 0
        task = Task {
            do {
                let r = try await StudyGenerator.generate(kind, module: module, materials: mats, options: options, store: store) { n in
                    withAnimation(Motion.snappy) { chars = n }
                }
                withAnimation(Motion.standard) { result = r }
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                self.error = (error as? AIError)?.message ?? error.localizedDescription
            }
            running = false
        }
    }
}

// MARK: - Dokument

struct DocumentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let docID: UUID
    @State private var showSolutions = false
    @State private var editing = false
    @State private var draft = ""
    @State private var examStart: Date?
    @State private var confirmDelete = false
    @State private var exporting = false
    @State private var exportDoc: TextFileDocument?

    var body: some View {
        if let doc = store.docs.first(where: { $0.id == docID }) {
            let parts = split(doc.markdown)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(doc.kind.label, systemImage: doc.kind.symbol).font(.caption.weight(.semibold)).foregroundStyle(store.color(for: doc.moduleID))
                        TextField("Titel", text: Binding(get: { doc.title }, set: { v in update { $0.title = v } }))
                            .textFieldStyle(.plain).scaledFont(size: 20, weight: .bold)
                    }
                    Spacer()
                    if doc.kind == .probeklausur {
                        if let examStart {
                            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                                let s = Int(ctx.date.timeIntervalSince(examStart))
                                Label(String(format: "%d:%02d", s / 60, s % 60), systemImage: "stopwatch").monospacedDigit()
                            }
                            Button("Stopp") { self.examStart = nil }
                        } else {
                            Button { examStart = Date(); showSolutions = false } label: { Label("Klausur simulieren", systemImage: "stopwatch") }
                        }
                    }
                    if parts.solutions != nil {
                        Toggle("Lösungen", isOn: $showSolutions.animation(Motion.standard)).toggleStyle(.switch).controlSize(.small)
                    }
                    Button(editing ? "Fertig" : "Bearbeiten") {
                        if editing { update { $0.markdown = draft } } else { draft = doc.markdown }
                        editing.toggle()
                    }
                }
                .padding(20)
                Divider()
                if editing {
                    TextEditor(text: $draft).scaledFont(size: 13, design: .monospaced).padding(12)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            MarkdownView(text: parts.main)
                            if let sol = parts.solutions {
                                if showSolutions {
                                    Divider()
                                    MarkdownView(text: sol).transition(.opacity)
                                } else {
                                    Button { withAnimation(Motion.standard) { showSolutions = true } } label: {
                                        Label("Lösungen einblenden", systemImage: "eye")
                                    }
                                    .padding(.top, 10)
                                }
                            }
                        }
                        .pagePadding()
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity)
                    }
                }
                Divider()
                HStack {
                    Button("Löschen", role: .destructive) { confirmDelete = true }
                    Button { Platform.copy(doc.markdown); app.showToast("Kopiert") } label: { Label("Kopieren", systemImage: "doc.on.doc") }
                    Button { export(doc) } label: { Label("Exportieren", systemImage: "square.and.arrow.up") }
                    Button {
                        dismiss()
                        app.assistant.ask("Lass uns über das Dokument „\(doc.title)“ sprechen. Hier der Inhalt:\n\n\(String(doc.markdown.prefix(12000)))", scope: doc.moduleID)
                    } label: { Label("Im Chat besprechen", systemImage: "sparkles") }
                    Spacer()
                    Button("Schließen") { if editing { update { $0.markdown = draft } }; dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(14)
            }
            .macFrame(width: 860, height: 720)
            .fileExporter(isPresented: $exporting, document: exportDoc, contentType: UTType(filenameExtension: "md") ?? .plainText,
                          defaultFilename: doc.title.replacingOccurrences(of: "/", with: "-") + ".md") { _ in }
            .confirmationDialog("Dokument löschen?", isPresented: $confirmDelete) {
                Button("Löschen", role: .destructive) { store.docs.removeAll { $0.id == docID }; dismiss() }
            }
        } else {
            ContentUnavailableView("Dokument nicht gefunden", systemImage: "doc").frame(width: 400, height: 300)
        }
    }

    private func split(_ md: String) -> (main: String, solutions: String?) {
        let lines = md.components(separatedBy: "\n")
        guard let idx = lines.firstIndex(where: { l in
            let t = l.trimmed.lowercased()
            return t.hasPrefix("#") && (t.contains("lösung") || t.contains("loesung") || t.contains("musterlösung"))
        }), idx > 0 else { return (md, nil) }
        return (lines[..<idx].joined(separator: "\n"), lines[idx...].joined(separator: "\n"))
    }

    private func update(_ change: (inout StudyDoc) -> Void) {
        if let i = store.docs.firstIndex(where: { $0.id == docID }) { change(&store.docs[i]) }
    }

    private func export(_ doc: StudyDoc) {
        exportDoc = TextFileDocument(text: doc.markdown)
        exporting = true
    }
}
