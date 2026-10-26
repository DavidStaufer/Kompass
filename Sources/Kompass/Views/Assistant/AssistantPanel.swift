import SwiftUI

struct AssistantPanel: View {
    @Environment(\.isCompactLayout) private var compact
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(Assistant.self) private var assistant
    var previewChat = false
    @State private var hasKey = Secrets.hasDeepSeekKey
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !hasKey {
                KeySetupCard { hasKey = true }
                    .padding(16)
                Spacer()
            } else {
                messagesView
                inputBar
            }
        }
        .background(Color.appBackground)
        .onAppear { hasKey = previewChat || Secrets.hasDeepSeekKey; inputFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .kompassKeyChanged)) { _ in hasKey = Secrets.hasDeepSeekKey }
        #if os(iOS)
        .presentationDetents([.large])
        #endif
    }

    // MARK: Kopf

    private var header: some View {
        @Bindable var assistant = assistant
        return HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
            Menu {
                Button { assistant.scopeModuleID = nil } label: {
                    if assistant.scopeModuleID == nil { Label("Allgemein", systemImage: "checkmark") } else { Text("Allgemein") }
                }
                Divider()
                ForEach(store.activeModules) { m in
                    Button { assistant.scopeModuleID = m.id } label: {
                        if assistant.scopeModuleID == m.id { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                    }
                }
            } label: {
                Text(store.module(assistant.scopeModuleID)?.name ?? "Assistent").font(.system(size: 14, weight: .semibold))
            }
            .plainMenu(indicator: true)
            .help("Kontext wählen – im Modul-Kontext kennt die KI dessen Materialien")
            Spacer()
            Button { assistant.clear() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.borderless)
                .help("Neues Gespräch")
                .disabled(assistant.messages.isEmpty)
            #if os(iOS)
            Button("Fertig") { withAnimation(Motion.standard) { app.showAssistant = false } }
                .fontWeight(.semibold)
                .padding(.leading, 8)
            #endif
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Verlauf

    private var messagesView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if assistant.messages.isEmpty && !assistant.isRunning { suggestions }
                    ForEach(assistant.messages) { m in
                        MessageView(message: m)
                            .id(m.id)
                    }
                    if assistant.isRunning { liveView }
                    if let c = assistant.confirmation { confirmationCard(c) }
                    if let e = assistant.errorText {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(e).font(.callout)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: assistant.messages.count) { _, _ in withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: assistant.live?.content.count ?? 0) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: assistant.confirmation?.id) { _, _ in withAnimation(Motion.standard) { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: assistant.key) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private var suggestions: some View {
        let scoped = store.module(assistant.scopeModuleID)
        let items: [(String, String)] = scoped.map { m in [
            ("questionmark.bubble", "Frag mich zu \(m.name) ab"),
            ("text.append", "Fasse die letzte Vorlesung zusammen"),
            ("doc.badge.clock", "Erstelle eine Probeklausur im Stil der Altklausuren"),
            ("list.bullet.clipboard", "Erstelle einen Lernplan bis zur Klausur"),
            ("lightbulb", "Erkläre mir das schwierigste Thema einfach")
        ] } ?? [
            ("calendar.badge.clock", "Was steht diese Woche an und wie schaffe ich das?"),
            ("wand.and.stars", "Plane meine Lernblöcke für nächste Woche"),
            ("flag", "Welche Fristen sind am dringendsten?"),
            ("person.badge.clock", "Ich arbeite Di und Do 9–17 Uhr als Werkstudent – trag das ein"),
            ("plus.rectangle.on.folder", "Hilf mir, mein Semester einzurichten")
        ]
        return VStack(alignment: .leading, spacing: 10) {
            Text(scoped == nil ? "Wobei kann ich helfen?" : "Lernen mit \(scoped!.name)")
                .font(.system(size: 20, weight: .bold)).tracking(-0.3)
            Text("Ich kann deinen Kalender, deine Module, Fristen und Materialien direkt bearbeiten.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(items, id: \.1) { icon, text in
                Button { assistant.send(text) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
                        Text(text).font(.callout).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.subtleFill))
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.top, 8)
    }

    private var liveView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = assistant.live?.content, !text.isEmpty {
                MarkdownView(text: text)
            }
            if assistant.confirmation == nil {
                HStack(spacing: 8) {
                    TypingDots()
                    Text(assistant.activity ?? ((assistant.live?.content.isEmpty ?? true) ? "Denkt nach …" : "Schreibt …"))
                        .font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }
            }
        }
    }

    private func confirmationCard(_ c: Assistant.Confirmation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(c.title, systemImage: "hand.raised.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.orange)
            Text(c.detail).font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Ablehnen") { assistant.resolve(false) }
                Button("Erlauben") { assistant.resolve(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35)))
        .transition(.scale(scale: 0.96, anchor: .bottom).combined(with: .opacity))
    }

    // MARK: Eingabe

    private var inputBar: some View {
        @Bindable var assistant = assistant
        return HStack(alignment: .bottom, spacing: 8) {
            TextField(assistant.scopeModuleID == nil ? "Frag Kompass …" : "Frag zu \(store.module(assistant.scopeModuleID)?.name ?? "diesem Modul") …",
                      text: $assistant.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { assistant.send(assistant.draft) }
                .padding(.vertical, 8)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.cardBackground))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
            Button {
                if assistant.isRunning { assistant.stop() } else { assistant.send(assistant.draft) }
            } label: {
                Image(systemName: assistant.isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(assistant.isRunning || !assistant.draft.trimmed.isEmpty ? Color.accentColor : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.pressable)
            .disabled(!assistant.isRunning && assistant.draft.trimmed.isEmpty)
            .help(assistant.isRunning ? "Stoppen" : "Senden (Enter)")
        }
        .padding(12)
        .background(.bar)
    }
}

extension Notification.Name {
    static let kompassKeyChanged = Notification.Name("kompassKeyChanged")
}

struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduce
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { ctx in
            let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.35) % 3
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .opacity(reduce ? 0.6 : (i == phase ? 1 : 0.3))
                }
            }
        }
    }
}

struct MessageView: View {
    @Environment(AppModel.self) private var app
    let message: AIMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.content)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor))
            }
        case .assistant:
            if !message.content.trimmed.isEmpty {
                MarkdownView(text: message.content)
            }
        case .tool:
            HStack(spacing: 8) {
                Image(systemName: message.isError == true ? "exclamationmark.circle" : "checkmark.circle.fill")
                    .foregroundStyle(message.isError == true ? Color.orange : Color.green)
                    .font(.system(size: 12))
                Text(message.summary ?? ToolDefinitions.activityLabel(message.toolName ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
                if let a = message.attachment { attachmentButton(a) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.subtleFill))
        }
    }

    @ViewBuilder
    private func attachmentButton(_ a: ChatAttachment) -> some View {
        let title: String = {
            switch a.kind {
            case .quiz: return "Starten"
            case .doc: return "Öffnen"
            case .cards: return "Lernen"
            case .plan: return "Prüfen"
            case .module: return "Ansehen"
            case .deadline: return "Ansehen"
            case .view: return "Anzeigen"
            }
        }()
        Button(title) { open(a) }.controlSize(.small)
    }

    private func open(_ a: ChatAttachment) {
        switch a.kind {
        case .quiz: if let id = UUID(uuidString: a.id) { app.sheet = .quiz(id) }
        case .doc: if let id = UUID(uuidString: a.id) { app.sheet = .doc(id) }
        case .cards: app.sheet = .cardReview(UUID(uuidString: a.id))
        case .plan: if let d = Fmt.machineDay.date(from: a.id) { app.sheet = .planner(d) }
        case .module: if let id = UUID(uuidString: a.id) { app.openModule(id) }
        case .deadline: if let id = UUID(uuidString: a.id) { app.sheet = .deadline(id, moduleID: nil, kind: nil) }
        case .view:
            if a.id.hasPrefix("calendar:"), let d = Fmt.machineDay.date(from: String(a.id.dropFirst(9))) {
                app.calendarDate = d
                app.selection = .calendar
            }
        }
    }
}

struct KeySetupCard: View {
    var onSaved: () -> Void
    @State private var key = ""
    @State private var testing = false
    @State private var status: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DeepSeek verbinden", systemImage: "key.fill").font(.headline)
            Text("Der Assistent nutzt die DeepSeek-API (günstig, Abrechnung pro Nutzung). Erstelle einen Key auf platform.deepseek.com → API Keys und füge ihn hier ein. Er wird im Schlüsselbund gespeichert.")
                .font(.callout).foregroundStyle(.secondary)
            SecureField("sk-…", text: $key)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Link("Key erstellen ↗", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                    .font(.callout)
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Speichern", action: save).buttonStyle(.borderedProminent).disabled(key.trimmed.isEmpty || testing)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .card()
    }

    private func save() {
        let k = key.trimmed
        guard !k.isEmpty else { return }
        Secrets.deepSeekKey = k
        testing = true
        status = "Verbindung wird getestet …"
        Task { @MainActor in
            let client = DeepSeekClient.fromSettings(AppModel.shared.store.prefs)
            do {
                _ = try await client?.test()
                status = "Verbunden ✓"
                NotificationCenter.default.post(name: .kompassKeyChanged, object: nil)
                onSaved()
            } catch {
                status = (error as? AIError)?.message ?? error.localizedDescription
            }
            testing = false
        }
    }
}
