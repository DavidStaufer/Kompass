import SwiftUI

struct OnboardingView: View {
    enum Step { case welcome, sync, term, work, access, ai }

    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(CalendarService.self) private var calendar
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce

    @State private var index = 0
    @State private var forward = true
    @State private var name = ""
    @State private var term = Term.suggested()
    @State private var work: [WorkBlock] = []
    @State private var key = ""
    @State private var accessRequested = false
    @State private var pickingFolder = false
    @State private var syncMessage: String?
    /// iPhone mit bestehenden Mac-Daten verbunden → Semester/Arbeit nicht neu abfragen
    @State private var usesExistingData = false

    private var steps: [Step] {
        if Platform.isMac { return [.welcome, .term, .work, .access, .ai] }
        return usesExistingData ? [.welcome, .sync, .access, .ai] : [.welcome, .sync, .term, .work, .access, .ai]
    }
    private var step: Step { steps[min(index, steps.count - 1)] }
    private var isLast: Bool { index >= steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Capsule().fill(i <= index ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(width: i == index ? 22 : 8, height: 8)
                }
            }
            .animation(Motion.standard, value: index)
            .padding(.top, 22)

            ScrollView {
                page
                    .id(step)
                    .transition(reduce ? .opacity : .asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                if index > 0 { Button("Zurück") { go(index - 1) } }
                Spacer()
                if step == .ai && key.trimmed.isEmpty {
                    Button("Später") { finish() }
                }
                Button(isLast ? "Los geht's" : (step == .sync && !usesExistingData ? "Überspringen" : "Weiter")) {
                    if isLast { finish() } else { advance() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(step == .term && term.name.trimmed.isEmpty)
            }
            .padding(20)
        }
        .macFrame(width: 620, height: 580)
        .interactiveDismissDisabled()
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let msg = app.useStorageFolder(url)
                syncMessage = msg
                if store.prefs.onboardingDone || !store.terms.isEmpty {
                    usesExistingData = true
                    name = store.prefs.userName
                }
            }
        }
        .onAppear {
            name = store.prefs.userName
            if let t = store.currentTerm { term = t }
            work = store.workBlocks
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            VStack(spacing: 16) {
                AppGlyph().frame(width: 96, height: 96)
                Text("Willkommen bei Kompass").scaledFont(size: 30, weight: .bold).tracking(-0.7).multilineTextAlignment(.center)
                Text("Dein Studium, deine Arbeit und dein Lernen – an einem Ort. Kompass plant deine Woche, erinnert dich an Fristen und lernt mit dir.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 440)
                TextField("Wie heißt du?", text: $name)
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 260).multilineTextAlignment(.center)
            }
            .padding(30)
        case .sync:
            OnboardingPage(symbol: "icloud", title: "Mit dem Mac synchronisieren", text: "Nutzt du Kompass schon auf dem Mac? Dann verbinde den Ordner „Kompass“ in iCloud Drive – iPhone und Mac teilen sich danach Module, Materialien, Zeiten und Karteikarten.") {
                VStack(spacing: 12) {
                    Button { pickingFolder = true } label: {
                        Label(usesExistingData ? "Anderen Ordner wählen …" : "iCloud-Ordner wählen …", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.borderedProminent)
                    if let syncMessage {
                        Label(syncMessage, systemImage: usesExistingData ? "checkmark.icloud.fill" : "icloud")
                            .font(.callout).foregroundStyle(usesExistingData ? .green : .secondary)
                            .multilineTextAlignment(.center)
                    }
                    Text("Im Dialog: „Durchsuchen“ → iCloud Drive → Ordner „Kompass“ auswählen → „Öffnen“. Neu hier? Einfach überspringen – du kannst das später in den Einstellungen nachholen.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
            }
        case .term:
            OnboardingPage(symbol: "graduationcap", title: "Dein Semester", text: "Damit Kompass Vorlesungen bis zum Semesterende einträgt und rückwärts von Klausuren plant.") {
                Form {
                    TextField("Name", text: $term.name)
                    DatePicker("Beginn", selection: $term.start, displayedComponents: .date)
                    DatePicker("Ende", selection: $term.end, in: term.start..., displayedComponents: .date)
                    DatePicker("Vorlesungsende", selection: $term.lectureEndOrEnd, in: term.start...term.end, displayedComponents: .date)
                }
                .formStyle(.grouped).frame(height: 240).frame(maxWidth: 460)
                .scrollDisabled(true)
            }
        case .work:
            OnboardingPage(symbol: "briefcase", title: "Deine Arbeitszeiten", text: "Feste Werkstudenten-Zeiten blockt der Planer automatisch. Wechselnde Schichten kannst du später als Kalender auswählen.") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($work) { $w in
                        WorkBlockEditorRow(block: $w) { work.removeAll { $0.id == w.id } }
                    }
                    Button { work.append(WorkBlock(weekday: (work.last?.weekday ?? 1) % 5 + 1)) } label: { Label("Arbeitstag hinzufügen", systemImage: "plus") }
                    Text("Keine festen Zeiten? Einfach überspringen.").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 440)
            }
        case .access:
            OnboardingPage(symbol: "calendar.badge.checkmark", title: "Kalender & Erinnerungen", text: "Kompass legt einen eigenen Kalender „Kompass“ und eine Erinnerungsliste an (über iCloud auf allen Geräten) und liest deine anderen Kalender, um freie Zeit zu finden.") {
                VStack(alignment: .leading, spacing: 10) {
                    AccessRow(title: "Kalender", ok: calendar.eventsAuthorized)
                    AccessRow(title: "Erinnerungen", ok: calendar.remindersAuthorized)
                    Button(accessRequested ? "Erneut anfragen" : "Zugriff erlauben") {
                        accessRequested = true
                        Task {
                            await calendar.requestAccess()
                            await app.sync.requestNotificationPermission()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    if accessRequested && !calendar.eventsAuthorized {
                        Button("Einstellungen öffnen") { calendar.openPrivacySettings() }
                    }
                }
                .frame(maxWidth: 320)
            }
        case .ai:
            OnboardingPage(symbol: "sparkles", title: "KI-Assistent", text: "Mit einem DeepSeek-API-Key fragt Kompass dich ab, erstellt Lernpläne, Zusammenfassungen und Probeklausuren und kann die ganze App für dich bedienen.") {
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("sk-…", text: $key).textFieldStyle(.roundedBorder)
                    Link("Key auf platform.deepseek.com erstellen ↗", destination: URL(string: "https://platform.deepseek.com/api_keys")!).font(.callout)
                    Text(Platform.isMac ? "Du kannst den Key auch später in den Einstellungen (⌘,) eintragen." : "Du kannst den Key auch später in den Einstellungen eintragen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: 360)
            }
        }
    }

    private func advance() {
        switch step {
        case .welcome: if !usesExistingData { store.prefs.userName = name.trimmed }
        case .term:
            if let i = store.terms.firstIndex(where: { $0.id == term.id }) { store.terms[i] = term } else { store.terms.append(term) }
            store.prefs.currentTermID = term.id
        case .work: store.workBlocks = work
        default: break
        }
        go(index + 1)
    }

    private func go(_ i: Int) {
        forward = i > index
        withAnimation(Motion.pick(reduce)) { index = max(0, min(steps.count - 1, i)) }
    }

    private func finish() {
        if !key.trimmed.isEmpty {
            Secrets.deepSeekKey = key
            NotificationCenter.default.post(name: .kompassKeyChanged, object: nil)
        }
        if !usesExistingData {
            store.prefs.userName = name.trimmed
            if !store.terms.contains(where: { $0.id == term.id }) { store.terms.append(term); store.prefs.currentTermID = term.id }
            store.workBlocks = work
        }
        store.prefs.onboardingDone = true
        dismiss()
        Task { await app.finishSetup() }
    }
}

struct OnboardingPage<Content: View>: View {
    var symbol: String
    var title: String
    var text: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).scaledFont(size: 34, weight: .medium).foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title).scaledFont(size: 24, weight: .bold).tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            content.padding(.top, 6)
        }
        .padding(Platform.isMac ? 30 : 20)
    }
}

struct AccessRow: View {
    var title: String
    var ok: Bool
    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundStyle(ok ? .green : .secondary)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            Text(ok ? "Erlaubt" : "Ausstehend").foregroundStyle(.secondary).font(.callout)
        }
    }
}

/// Das Kompass-Zeichen (auch Grundlage des App-Icons).
struct AppGlyph: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                RoundedRectangle(cornerRadius: s * 0.225, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.98), Color(red: 0.20, green: 0.22, blue: 0.62)], startPoint: .top, endPoint: .bottom))
                Circle().strokeBorder(Color.white.opacity(0.35), lineWidth: s * 0.025).padding(s * 0.16)
                CompassNeedle()
                    .fill(Color.white)
                    .frame(width: s * 0.2, height: s * 0.6)
                    .rotationEffect(.degrees(35))
                CompassNeedle(south: true)
                    .fill(Color.white.opacity(0.4))
                    .frame(width: s * 0.2, height: s * 0.6)
                    .rotationEffect(.degrees(35))
                Circle().fill(Color(red: 0.20, green: 0.22, blue: 0.62)).frame(width: s * 0.06)
            }
            .frame(width: s, height: s)
        }
    }
}

struct CompassNeedle: Shape {
    var south = false
    func path(in r: CGRect) -> Path {
        var p = Path()
        if south {
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        }
        p.closeSubpath()
        return p
    }
}
