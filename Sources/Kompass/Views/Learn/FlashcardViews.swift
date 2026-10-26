import SwiftUI

struct FlashcardsHome: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @State private var browseModule: UUID?
    @State private var search = ""
    @State private var front = ""
    @State private var back = ""

    var body: some View {
        let due = store.dueCards()
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Karteikarten", subtitle: "Wiederholung im optimalen Abstand (Spaced Repetition)") {
                    Button { app.sheet = .cardReview(nil) } label: { Label("Alle fälligen lernen (\(due.count))", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(due.isEmpty)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                    ForEach(store.activeModules) { m in
                        let cards = store.flashcards.filter { $0.moduleID == m.id }
                        let d = cards.filter { $0.due <= Date() }.count
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { ModuleDot(color: m.color.color); Text(m.name).font(.system(size: 14, weight: .semibold)).lineLimit(1) }
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(d)").font(.system(size: 26, weight: .bold, design: .rounded))
                                Text("fällig · \(cards.count) gesamt").font(.caption).foregroundStyle(.secondary)
                            }
                            BarMeter(value: cards.isEmpty ? 0 : Double(cards.filter(\.isMature).count) / Double(cards.count), color: m.color.color, height: 5)
                            HStack {
                                Button("Lernen") { app.sheet = .cardReview(m.id) }.disabled(d == 0)
                                Button("Ansehen") { browseModule = m.id }
                                Spacer()
                                Button { app.sheet = .generator(.flashcards, m.id, []) } label: { Image(systemName: "sparkles") }
                                    .help("Karten mit KI erstellen")
                            }
                            .controlSize(.small)
                        }
                        .card(padding: 14)
                    }
                }
                if let mid = browseModule, let m = store.module(mid) {
                    browser(m)
                }
            }
            .pagePadding()
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Karteikarten")
        .inlineNavigationTitle()
    }

    private func browser(_ m: Module) -> some View {
        let cards = store.flashcards.filter { $0.moduleID == m.id && (search.isEmpty || $0.front.localizedCaseInsensitiveContains(search) || $0.back.localizedCaseInsensitiveContains(search)) }
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Karten: \(m.name)", symbol: "rectangle.stack") {
                TextField("Suchen", text: $search).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            HStack(alignment: .top) {
                TextField("Vorderseite", text: $front, axis: .vertical).textFieldStyle(.roundedBorder)
                TextField("Rückseite", text: $back, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Hinzufügen") {
                    store.flashcards.append(Flashcard(moduleID: m.id, front: front.trimmed, back: back.trimmed))
                    front = ""; back = ""
                }
                .disabled(front.trimmed.isEmpty || back.trimmed.isEmpty)
            }
            ForEach(cards) { c in
                HStack(alignment: .top, spacing: 12) {
                    Text(c.front).font(.callout.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                    Text(c.back).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(c.due <= Date() ? "fällig" : "in \(max(1, Date().daysUntil(c.due))) T").font(.caption)
                        if !c.topic.isEmpty { Text(c.topic).font(.caption2).foregroundStyle(.secondary) }
                    }
                    .frame(width: 90, alignment: .trailing)
                    Button { store.flashcards.removeAll { $0.id == c.id } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
        .card()
    }
}

/// Lern-Session: Karte umdrehen (Leertaste), bewerten (1–4) oder wischen.
struct CardReviewSheet: View {
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    let moduleID: UUID?

    @State private var queue: [UUID] = []
    @State private var flipped = false
    @State private var offset: CGFloat = 0
    @State private var reviewed = 0
    @State private var correct = 0
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(moduleID.flatMap { store.module($0)?.name } ?? "Alle Module").font(.headline)
                Spacer()
                Text("\(reviewed) gelernt · \(queue.count) übrig").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button("Fertig") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let id = queue.first, let card = store.flashcards.first(where: { $0.id == id }) {
                cardView(card)
                    .id(card.id)
                    .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
                ratingBar(card)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill").font(.system(size: 52)).foregroundStyle(.green)
                        .symbolEffect(.bounce, value: reviewed)
                    Text(reviewed == 0 ? "Keine Karten fällig." : "Geschafft! \(reviewed) Karten wiederholt.").font(.title3.weight(.semibold))
                    if reviewed > 0 { Text("\(Fmt.percent(Double(correct) / Double(max(1, reviewed)))) gewusst").foregroundStyle(.secondary) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .macFrame(width: 640, height: 560)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            queue = store.dueCards(moduleID: moduleID).prefix(60).map(\.id)
        }
        .onKeyPress(.space) { withAnimation(Motion.pick(reduce, Motion.momentum)) { flipped.toggle() }; return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "1234")) { press in
            guard flipped, let g = Int(press.characters) else { return .ignored }
            rate(g - 1)
            return .handled
        }
    }

    private func cardView(_ c: Flashcard) -> some View {
        let color = store.color(for: c.moduleID)
        return ZStack {
            face(text: c.front, label: c.topic.isEmpty ? "Frage" : c.topic, color: color)
                .opacity(flipped ? 0 : 1)
            face(text: c.back, label: "Antwort", color: color)
                .rotation3DEffect(.degrees(reduce ? 0 : 180), axis: (x: 0, y: 1, z: 0))
                .opacity(flipped ? 1 : 0)
        }
        .rotation3DEffect(.degrees(flipped && !reduce ? 180 : 0), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
        .offset(x: offset)
        .rotationEffect(.degrees(Double(offset) / 24))
        .overlay(alignment: .top) {
            if abs(offset) > 40 {
                Pill(text: offset > 0 ? "Gewusst" : "Nochmal", color: offset > 0 ? .green : .red)
                    .padding(.top, 12)
                    .opacity(min(1, Double(abs(offset) - 40) / 80))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.pick(reduce, Motion.momentum)) { flipped.toggle() } }
        .gesture(swipe)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func face(text: String, label: String, color: Color) -> some View {
        VStack(spacing: 14) {
            Text(label.uppercased()).font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(color)
            ScrollView {
                MarkdownView(text: text, baseSize: 17)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.cardBackground))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(color.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.08), radius: 16, y: 6)
    }

    /// Wischen nach rechts = gewusst, nach links = nochmal. Folgt 1:1, projiziert den Schwung.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                guard flipped else {
                    // Vor dem Umdrehen: weicher Widerstand statt hartem Stopp
                    offset = rubberband(v.translation.width, dimension: 300)
                    return
                }
                offset = v.translation.width
            }
            .onEnded { v in
                let projected = v.translation.width + project(v.velocity.width)
                if flipped && abs(projected) > 220 {
                    let dir: CGFloat = projected > 0 ? 1 : -1
                    withAnimation(Motion.momentum) { offset = dir * 700 } completion: {
                        offset = 0
                        rate(dir > 0 ? 2 : 0)
                    }
                } else {
                    withAnimation(Motion.momentum) { offset = 0 }
                }
            }
    }

    private func project(_ velocity: CGFloat, rate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * rate / (1 - rate)
    }

    private func rubberband(_ x: CGFloat, dimension: CGFloat, c: CGFloat = 0.55) -> CGFloat {
        (x * dimension * c) / (dimension + c * abs(x))
    }

    private func ratingBar(_ c: Flashcard) -> some View {
        HStack(spacing: 10) {
            if !flipped {
                Button { withAnimation(Motion.pick(reduce, Motion.momentum)) { flipped = true } } label: {
                    Text("Antwort zeigen").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                ForEach(0..<4, id: \.self) { g in
                    let labels = ["Nochmal", "Schwer", "Gut", "Einfach"]
                    let colors: [Color] = [.red, .orange, .green, .blue]
                    Button { rate(g) } label: {
                        VStack(spacing: 2) {
                            Text(labels[g]).font(.callout.weight(.semibold))
                            Text(preview(c, grade: g)).font(.caption2).opacity(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).tint(colors[g]).controlSize(.large)
                    .help("Taste \(g + 1)")
                }
            }
        }
    }

    private func preview(_ c: Flashcard, grade: Int) -> String {
        var copy = c
        copy.review(grade: grade)
        let mins = Int(copy.due.timeIntervalSinceNow / 60)
        if mins < 60 { return "\(max(1, mins)) min" }
        let days = Int((copy.intervalDays).rounded())
        return days <= 1 ? "1 Tag" : "\(days) Tage"
    }

    private func rate(_ grade: Int) {
        guard let id = queue.first, let i = store.flashcards.firstIndex(where: { $0.id == id }) else { return }
        store.flashcards[i].review(grade: grade)
        let card = store.flashcards[i]
        if !card.topic.isEmpty {
            store.applyResult(moduleID: card.moduleID, topicName: card.topic, score: [0, 0.4, 0.8, 1][grade], weight: 0.12)
        }
        reviewed += 1
        if grade >= 2 { correct += 1 }
        withAnimation(Motion.pick(reduce)) {
            queue.removeFirst()
            if grade == 0 { queue.append(id) }  // nochmal am Ende der Runde
            flipped = false
            offset = 0
        }
    }
}
