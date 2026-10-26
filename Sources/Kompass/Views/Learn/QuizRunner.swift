import SwiftUI

struct QuizRunner: View {
    @Environment(AppModel.self) private var app
    @Environment(DataStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduce
    let quizID: UUID

    @State private var index = 0
    @State private var chosen: [Int: Int] = [:]
    @State private var openAnswers: [Int: String] = [:]
    @State private var scores: [Int: Double] = [:]
    @State private var feedback: [Int: String] = [:]
    @State private var revealed: Set<Int> = []
    @State private var grading = false
    @State private var finished = false
    @State private var gradeError: String?

    var body: some View {
        if let quiz = store.quizzes.first(where: { $0.id == quizID }), !quiz.questions.isEmpty {
            let color = store.color(for: quiz.moduleID)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(quiz.title).font(.system(size: 17, weight: .bold))
                        Text(store.module(quiz.moduleID)?.name ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !finished { Text("\(index + 1) / \(quiz.questions.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary) }
                    Button("Schließen") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(20)
                BarMeter(value: finished ? 1 : Double(index) / Double(quiz.questions.count), color: color, height: 4)
                    .padding(.horizontal, 20)
                Group {
                    if finished { results(quiz, color: color) } else { question(quiz.questions[index], quiz: quiz, color: color) }
                }
                .id(finished ? -1 : index)
                .transition(reduce ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .move(edge: .leading).combined(with: .opacity)))
            }
            .macFrame(width: 720, height: 620)
            .clipped()
        } else {
            ContentUnavailableView("Quiz nicht gefunden", systemImage: "questionmark").frame(width: 400, height: 300)
        }
    }

    // MARK: Frage

    @ViewBuilder
    private func question(_ q: QuizQuestion, quiz: Quiz, color: Color) -> some View {
        let isRevealed = revealed.contains(index)
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !q.topic.isEmpty { Pill(text: q.topic, color: color) }
                    MarkdownView(text: q.prompt, baseSize: 16)
                    if q.type == .single {
                        VStack(spacing: 8) {
                            ForEach(q.options.indices, id: \.self) { i in optionButton(q, i, isRevealed: isRevealed) }
                        }
                    } else {
                        TextEditor(text: Binding(get: { openAnswers[index] ?? "" }, set: { openAnswers[index] = $0 }))
                            .font(.body)
                            .frame(minHeight: 110)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.subtleFill))
                            .disabled(isRevealed)
                    }
                    if isRevealed { revealBox(q) }
                    if let gradeError { Text(gradeError).font(.caption).foregroundStyle(.orange) }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
            }
            HStack {
                if index > 0 { Button("Zurück") { go(index - 1) } }
                Spacer()
                if !isRevealed {
                    if q.type == .open {
                        if grading { ProgressView().controlSize(.small) }
                        Button("Lösung zeigen") { withAnimation(Motion.standard) { _ = revealed.insert(index) } }
                        if Secrets.hasDeepSeekKey {
                            Button("Von KI bewerten lassen") { grade(q) }
                                .buttonStyle(.borderedProminent)
                                .disabled((openAnswers[index] ?? "").trimmed.isEmpty || grading)
                        }
                    }
                } else if q.type == .open && scores[index] == nil {
                    Text("Wie gut war deine Antwort?").foregroundStyle(.secondary)
                    Button("Falsch") { selfRate(0) }
                    Button("Teilweise") { selfRate(0.5) }
                    Button("Richtig") { selfRate(1) }.buttonStyle(.borderedProminent)
                } else {
                    Button(index + 1 < quiz.questions.count ? "Weiter" : "Auswerten") {
                        if index + 1 < quiz.questions.count { go(index + 1) } else { finish(quiz) }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
        }
    }

    private func optionButton(_ q: QuizQuestion, _ i: Int, isRevealed: Bool) -> some View {
        let picked = chosen[index] == i
        let correct = q.correctIndex == i
        let tint: Color = !isRevealed ? (picked ? .accentColor : .clear) : (correct ? .green : (picked ? .red : .clear))
        return Button {
            guard !isRevealed else { return }
            chosen[index] = i
            scores[index] = correct ? 1 : 0
            withAnimation(Motion.standard) { _ = revealed.insert(index) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(["A", "B", "C", "D", "E", "F"][min(i, 5)])
                    .font(.system(size: 12, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(tint == .clear ? Color.primary.opacity(0.08) : tint.opacity(0.25)))
                Text(q.options[i]).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if isRevealed && correct { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                if isRevealed && picked && !correct { Image(systemName: "xmark.circle.fill").foregroundStyle(.red) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint == .clear ? Color.subtleFill : tint.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.6), lineWidth: tint == .clear ? 0 : 1))
        }
        .buttonStyle(.pressable)
        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [])
    }

    private func revealBox(_ q: QuizQuestion) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if q.type == .open {
                Text("Musterlösung").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MarkdownView(text: q.answer)
            }
            if let fb = feedback[index] {
                HStack(alignment: .top) {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        if let s = scores[index] { Text("Bewertung: \(Fmt.percent(s))").font(.callout.weight(.semibold)) }
                        Text(fb).font(.callout)
                    }
                }
            }
            if !q.explanation.isEmpty {
                Text("Erklärung").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                MarkdownView(text: q.explanation)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.06)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    // MARK: Ergebnis

    private func results(_ quiz: Quiz, color: Color) -> some View {
        let total = Double(quiz.questions.count)
        let score = scores.values.reduce(0, +) / max(1, total)
        var byTopic: [String: [Double]] = [:]
        for (i, q) in quiz.questions.enumerated() where !q.topic.isEmpty { byTopic[q.topic, default: []].append(scores[i] ?? 0) }
        return ScrollView {
            VStack(spacing: 18) {
                ZStack {
                    ProgressRing(value: score, color: score >= 0.8 ? .green : (score >= 0.5 ? .orange : .red), lineWidth: 10, size: 120)
                    Text(Fmt.percent(score)).font(.system(size: 28, weight: .bold, design: .rounded))
                }
                .padding(.top, 20)
                Text(score >= 0.85 ? "Stark! Das sitzt." : (score >= 0.6 ? "Gute Basis – dranbleiben." : "Da geht noch was – wiederhole die schwachen Themen."))
                    .font(.headline)
                if !byTopic.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(byTopic.keys.sorted(), id: \.self) { t in
                            let v = byTopic[t]!.reduce(0, +) / Double(byTopic[t]!.count)
                            HStack {
                                Text(t).font(.callout).frame(width: 220, alignment: .leading).lineLimit(1)
                                BarMeter(value: v, color: v >= 0.7 ? .green : (v >= 0.4 ? .orange : .red), height: 6)
                                Text(Fmt.percent(v)).font(.caption.monospacedDigit()).frame(width: 44)
                            }
                        }
                    }
                    .card()
                    .padding(.horizontal, 24)
                }
                HStack {
                    Button("Nochmal") { reset() }
                    Button("Schwache Themen im Chat üben") {
                        let weak = byTopic.filter { ($0.value.reduce(0, +) / Double($0.value.count)) < 0.7 }.keys.sorted()
                        dismiss()
                        app.assistant.ask("Ich hatte im Quiz „\(quiz.title)“ \(Fmt.percent(score)). Erkläre mir die Themen \(weak.isEmpty ? "noch einmal kurz" : weak.joined(separator: ", ")) und frag mich danach ab.", scope: quiz.moduleID)
                    }
                    Button("Fertig") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Logik

    private func go(_ i: Int) {
        gradeError = nil
        withAnimation(Motion.pick(reduce)) { index = i }
    }

    private func selfRate(_ v: Double) {
        scores[index] = v
    }

    private func grade(_ q: QuizQuestion) {
        let i = index
        let answer = openAnswers[i] ?? ""
        grading = true
        gradeError = nil
        Task {
            do {
                let g = try await StudyGenerator.grade(question: q, answer: answer, store: store)
                scores[i] = g.score
                feedback[i] = g.feedback
            } catch {
                gradeError = "Bewertung fehlgeschlagen – bewerte dich selbst."
            }
            grading = false
            withAnimation(Motion.standard) { _ = revealed.insert(i) }
        }
    }

    private func finish(_ quiz: Quiz) {
        let total = Double(quiz.questions.count)
        let score = scores.values.reduce(0, +) / max(1, total)
        if let qi = store.quizzes.firstIndex(where: { $0.id == quiz.id }) {
            store.quizzes[qi].attempts.append(QuizAttempt(score: score, answered: scores.count))
        }
        var byTopic: [String: [Double]] = [:]
        for (i, q) in quiz.questions.enumerated() where !q.topic.isEmpty { byTopic[q.topic, default: []].append(scores[i] ?? 0) }
        for (t, vals) in byTopic {
            store.applyResult(moduleID: quiz.moduleID, topicName: t, score: vals.reduce(0, +) / Double(vals.count), weight: 0.4)
        }
        withAnimation(Motion.standard) { finished = true }
    }

    private func reset() {
        chosen = [:]; openAnswers = [:]; scores = [:]; feedback = [:]; revealed = []
        withAnimation(Motion.standard) { finished = false; index = 0 }
    }
}
