import Foundation

enum GeneratorKind: String, CaseIterable, Identifiable {
    case quiz, flashcards, summary, mockExam, studyPlan, topics
    var id: String { rawValue }
    var label: String {
        switch self {
        case .quiz: return "Quiz"
        case .flashcards: return "Karteikarten"
        case .summary: return "Zusammenfassung"
        case .mockExam: return "Probeklausur"
        case .studyPlan: return "Lernplan"
        case .topics: return "Themen erkennen"
        }
    }
    var symbol: String {
        switch self {
        case .quiz: return "checklist"
        case .flashcards: return "rectangle.on.rectangle.angled"
        case .summary: return "text.append"
        case .mockExam: return "doc.badge.clock"
        case .studyPlan: return "list.bullet.clipboard"
        case .topics: return "list.bullet.indent"
        }
    }
    var blurb: String {
        switch self {
        case .quiz: return "Fragen zum Durchklicken – Ergebnis fließt in deinen Fortschritt."
        case .flashcards: return "Karten mit Wiederholung im optimalen Abstand."
        case .summary: return "Kompakte Zusammenfassung mit Definitionen, Formeln und Prüfungsfragen."
        case .mockExam: return "Klausur im Stil deiner Altklausuren – mit Lösungen."
        case .studyPlan: return "Wochenplan bis zur Klausur, abgestimmt auf deine Schwächen."
        case .topics: return "Liest die Gliederung aus den Materialien und legt Themen an."
        }
    }
    /// Welche Materialarten standardmäßig ausgewählt sind.
    var preferredKinds: Set<MaterialKind> {
        switch self {
        case .mockExam: return [.altklausur, .probeklausur, .uebung, .vorlesung, .skript]
        case .topics: return [.vorlesung, .skript]
        default: return [.vorlesung, .skript, .uebung, .zusammenfassung, .notiz, .altklausur, .probeklausur]
        }
    }
}

struct GeneratorOptions {
    var count = 12
    var difficulty = 1
    var openShare = 0.3
    var focus = ""
    var minutes = 90

    var difficultyLabel: String { ["leicht", "mittel", "anspruchsvoll (Klausurniveau)"][min(2, max(0, difficulty))] }
}

@MainActor
enum StudyGenerator {
    // MARK: Kontext

    static func context(_ materials: [Material], store: DataStore, budget: Int = 90_000) -> String {
        let texts = materials.map { (m: $0, t: store.text(of: $0.id)) }.filter { !$0.t.trimmed.isEmpty }
        guard !texts.isEmpty else { return "" }
        // Kurze Texte vollständig, lange anteilig kürzen
        var alloc: [UUID: Int] = [:]
        var remaining = budget
        let sorted = texts.sorted { $0.t.count < $1.t.count }
        for (i, x) in sorted.enumerated() {
            let share = remaining / (sorted.count - i)
            let take = min(share, x.t.count)
            alloc[x.m.id] = take
            remaining -= take
        }
        var out = ""
        for x in texts {
            let take = alloc[x.m.id] ?? 0
            out += "\n\n=== \(x.m.kind.label): \(x.m.title) ===\n"
            out += String(x.t.prefix(take))
            if take < x.t.count { out += "\n[… gekürzt]" }
        }
        return out
    }

    private static let tutor = """
    Du bist ein exzellenter Hochschul-Tutor. Du erstellst präzise, fachlich korrekte Lernmaterialien auf Deutsch \
    (Fachbegriffe dürfen englisch bleiben, wenn das Material englisch ist). Du stützt dich auf das bereitgestellte Material. \
    Formeln schreibst du in gut lesbarer Unicode-Notation (x², ∑, ∫, √, ≤, →, griechische Buchstaben), kein LaTeX.
    """

    // MARK: Erzeugen

    /// Erzeugt das gewünschte Lernmaterial und speichert es. Liefert einen Verweis auf das Ergebnis.
    static func generate(_ kind: GeneratorKind, module: Module, materials: [Material], options: GeneratorOptions,
                         store: DataStore, onProgress: @escaping @MainActor (Int) -> Void) async throws -> ChatAttachment {
        guard let client = DeepSeekClient.fromSettings(store.prefs) else {
            throw AIError(message: "Bitte hinterlege zuerst deinen DeepSeek-API-Key in den Einstellungen → KI.")
        }
        let ctx = context(materials, store: store)
        let topics = module.topics.map(\.title).joined(separator: ", ")
        let focus = options.focus.trimmed.isEmpty ? "" : "\nSchwerpunkt: \(options.focus)"
        let material = ctx.isEmpty ? "\n(Kein Material ausgewählt – nutze fundiertes Fachwissen zum Modul „\(module.name)“ und kennzeichne das.)" : "\n\nMATERIAL:\n\(ctx)"
        let progress: @MainActor (StreamResult) -> Void = { onProgress($0.content.count) }

        switch kind {
        case .quiz:
            let user = """
            Erstelle ein Quiz mit \(options.count) Fragen zum Modul „\(module.name)“. Schwierigkeit: \(options.difficultyLabel).
            Etwa \(Int(options.openShare * 100)) % offene Fragen, der Rest Single-Choice mit 4 Optionen (genau eine richtig, plausible Distraktoren).
            Ordne jede Frage einem Thema zu\(topics.isEmpty ? "" : ", möglichst aus: \(topics)").\(focus)
            Antworte nur mit JSON in diesem Format:
            {"title": "…", "questions": [{"type": "single_choice", "question": "…", "options": ["…","…","…","…"], "correct_index": 0, "explanation": "…", "topic": "…"}, {"type": "open", "question": "…", "answer": "Musterlösung", "explanation": "…", "topic": "…"}]}
            \(material)
            """
            let raw = try await client.complete(system: tutor, user: user, jsonMode: true, temperature: 0.5, onUpdate: progress)
            guard let obj = JSONExtract.object(raw) else { throw AIError(message: "Die Antwort der KI war kein gültiges Quiz. Versuch es noch einmal.") }
            let qs = parseQuestions(obj["questions"] as? [[String: Any]] ?? [])
            guard !qs.isEmpty else { throw AIError(message: "Die KI hat keine verwertbaren Fragen geliefert.") }
            let quiz = Quiz(moduleID: module.id, title: (obj["title"] as? String)?.nilIfEmpty ?? "Quiz \(module.displayCode)",
                            questions: qs, sourceMaterialIDs: materials.map(\.id))
            store.quizzes.append(quiz)
            return ChatAttachment(kind: .quiz, id: quiz.id.uuidString, label: quiz.title)

        case .flashcards:
            let user = """
            Erstelle \(options.count) Karteikarten zum Modul „\(module.name)“: zentrale Begriffe, Definitionen, Sätze, Formeln, typische Zusammenhänge.
            Vorderseite kurz und eindeutig, Rückseite knapp aber vollständig. Keine Duplikate.\(focus)
            Ordne jede Karte einem Thema zu\(topics.isEmpty ? "" : ", möglichst aus: \(topics)").
            Antworte nur mit JSON: {"cards": [{"front": "…", "back": "…", "topic": "…"}]}
            \(material)
            """
            let raw = try await client.complete(system: tutor, user: user, jsonMode: true, temperature: 0.4, onUpdate: progress)
            guard let obj = JSONExtract.object(raw), let arr = obj["cards"] as? [[String: Any]] else {
                throw AIError(message: "Die Antwort der KI enthielt keine Karteikarten.")
            }
            let existing = Set(store.flashcards.filter { $0.moduleID == module.id }.map { $0.front.lowercased() })
            let cards = arr.compactMap { o -> Flashcard? in
                guard let f = (o["front"] as? String)?.trimmed.nilIfEmpty, let b = (o["back"] as? String)?.trimmed.nilIfEmpty,
                      !existing.contains(f.lowercased()) else { return nil }
                return Flashcard(moduleID: module.id, topic: (o["topic"] as? String) ?? "", front: f, back: b)
            }
            store.flashcards.append(contentsOf: cards)
            return ChatAttachment(kind: .cards, id: module.id.uuidString, label: "\(cards.count) neue Karten")

        case .topics:
            let user = """
            Lies die Gliederung aus dem Material des Moduls „\(module.name)“ und liste die prüfungsrelevanten Themen/Kapitel in sinnvoller Reihenfolge (8–25 Einträge, prägnante Titel).
            \(topics.isEmpty ? "" : "Bereits vorhanden (nicht wiederholen): \(topics)")
            Antworte nur mit JSON: {"topics": ["…", "…"]}
            \(material)
            """
            let raw = try await client.complete(system: tutor, user: user, jsonMode: true, temperature: 0.2, onUpdate: progress)
            guard let obj = JSONExtract.object(raw), let arr = obj["topics"] as? [Any] else { throw AIError(message: "Keine Themen erkannt.") }
            let have = Set(module.topics.map { $0.title.lowercased() })
            let new = arr.compactMap { ($0 as? String)?.trimmed.nilIfEmpty }.filter { !have.contains($0.lowercased()) }.map { Topic(title: $0) }
            store.updateModule(module.id) { $0.topics.append(contentsOf: new) }
            return ChatAttachment(kind: .module, id: module.id.uuidString, label: "\(new.count) Themen")

        case .summary:
            let user = """
            Schreibe eine lernfreundliche Zusammenfassung zum Modul „\(module.name)“ in Markdown.\(focus)
            Aufbau: kurze Einleitung; pro Thema eine ##-Überschrift mit Kernaussagen als Liste, wichtigen **Definitionen**, Formeln, einem kurzen Beispiel;
            am Ende „## Typische Prüfungsfragen“ (5–10 Fragen) und „## Quellen“ (Material und Seiten/Folien).
            \(material)
            """
            let md = try await client.complete(system: tutor, user: user, temperature: 0.4, onUpdate: progress)
            let doc = StudyDoc(moduleID: module.id, kind: .zusammenfassung, title: options.focus.trimmed.nilIfEmpty.map { "Zusammenfassung: \($0)" } ?? "Zusammenfassung \(module.name)",
                               markdown: md, sourceMaterialIDs: materials.map(\.id))
            store.docs.append(doc)
            return ChatAttachment(kind: .doc, id: doc.id.uuidString, label: doc.title)

        case .mockExam:
            let hasOld = materials.contains { $0.kind == .altklausur || $0.kind == .probeklausur }
            let user = """
            Erstelle eine realistische Probeklausur zum Modul „\(module.name)“ für \(options.minutes) Minuten Bearbeitungszeit. Schwierigkeit: \(options.difficultyLabel).\(focus)
            \(hasOld ? "Orientiere dich eng an Aufbau, Aufgabentypen, Umfang und Punkteverteilung der beigefügten Altklausuren/Probeklausuren, aber erfinde neue Aufgaben." : "Decke die wichtigsten Themen ab und nutze typische Aufgabentypen des Fachs.")
            Format (Markdown): Titel, Hinweise (Zeit, Hilfsmittel, Gesamtpunkte), dann „## Aufgabe 1 (x Punkte)“ usw. mit Teilaufgaben a), b) …
            Am Ende „## Lösungen“ mit vollständigen, nachvollziehbaren Musterlösungen und Punkteschema.
            \(material)
            """
            let md = try await client.complete(system: tutor, user: user, temperature: 0.6, maxTokens: 8000, onUpdate: progress)
            let doc = StudyDoc(moduleID: module.id, kind: .probeklausur, title: "Probeklausur \(module.name) – \(Fmt.dayMonth(Date()))",
                               markdown: md, sourceMaterialIDs: materials.map(\.id))
            store.docs.append(doc)
            return ChatAttachment(kind: .doc, id: doc.id.uuidString, label: doc.title)

        case .studyPlan:
            let p = ProgressEngine.progress(for: module, store: store)
            let examText = p.examDate.map { "Die Klausur ist am \(Fmt.dayLong($0)) (\(Fmt.relative($0)))." } ?? "Es ist noch kein Klausurtermin eingetragen – plane bis zum Semesterende."
            let topicState = module.topics.isEmpty ? "Keine Themen erfasst – leite sie aus dem Material ab."
                : module.topics.map { "- \($0.title): Sicherheit \(Int($0.confidence * 100)) %\($0.covered ? "" : " (noch nicht behandelt)")" }.joined(separator: "\n")
            let user = """
            Erstelle einen konkreten Lernplan für das Modul „\(module.name)“. Heute ist \(Fmt.dayLong(Date())). \(examText)
            Wochenziel: \(Fmt.hours(Int(module.weeklyGoalHours * 60))) Selbststudium. Der Student arbeitet zusätzlich als Werkstudent – plane realistisch mit Puffer.
            Aktueller Stand der Themen:
            \(topicState)\(focus)
            Format (Markdown): kurze Strategie; dann pro Woche „## KW xx (Datum–Datum)“ mit Zielen, Themen, Übungen/Altklausuren und Wiederholungen (Spaced Repetition);
            die letzte Woche vor der Klausur als Prüfungssimulation. Schwache Themen zuerst und öfter.
            \(material)
            """
            let md = try await client.complete(system: tutor, user: user, temperature: 0.5, onUpdate: progress)
            let doc = StudyDoc(moduleID: module.id, kind: .lernplan, title: "Lernplan \(module.name)", markdown: md, sourceMaterialIDs: materials.map(\.id))
            store.docs.append(doc)
            return ChatAttachment(kind: .doc, id: doc.id.uuidString, label: doc.title)
        }
    }

    static func parseQuestions(_ arr: [[String: Any]]) -> [QuizQuestion] {
        arr.compactMap { o -> QuizQuestion? in
            guard let prompt = ((o["question"] ?? o["prompt"]) as? String)?.trimmed.nilIfEmpty else { return nil }
            let typeRaw = ((o["type"] as? String) ?? "").lowercased()
            let options = (o["options"] as? [Any])?.compactMap { ($0 as? String)?.trimmed.nilIfEmpty } ?? []
            let answer = (o["answer"] as? String) ?? ""
            let explanation = (o["explanation"] as? String) ?? ""
            let topic = (o["topic"] as? String) ?? ""
            let isOpen = typeRaw.contains("open") || typeRaw.contains("offen") || options.count < 2
            if isOpen {
                return QuizQuestion(type: .open, prompt: prompt, answer: answer.nilIfEmpty ?? explanation, explanation: explanation, topic: topic)
            }
            var idx = (o["correct_index"] as? NSNumber)?.intValue ?? (o["correct"] as? NSNumber)?.intValue
            if idx == nil, !answer.isEmpty { idx = options.firstIndex { $0.lowercased() == answer.lowercased() } }
            guard let i = idx, options.indices.contains(i) else { return nil }
            return QuizQuestion(type: .single, prompt: prompt, options: options, correctIndex: i, answer: options[i], explanation: explanation, topic: topic)
        }
    }

    // MARK: Bewerten

    struct Grade { var score: Double; var feedback: String }

    static func grade(question: QuizQuestion, answer: String, store: DataStore) async throws -> Grade {
        guard let client = DeepSeekClient.fromSettings(store.prefs) else { throw AIError(message: "Kein API-Key hinterlegt.") }
        let user = """
        Bewerte die Antwort eines Studenten fair, aber streng wie in einer Klausur.
        Frage: \(question.prompt)
        Musterlösung: \(question.answer)
        \(question.explanation.isEmpty ? "" : "Erläuterung: \(question.explanation)")
        Antwort des Studenten: \(answer)
        Antworte nur mit JSON: {"score": 0.0 bis 1.0, "feedback": "2–4 Sätze: was stimmt, was fehlt, Tipp"}
        """
        let raw = try await client.complete(system: tutor, user: user, jsonMode: true, temperature: 0.2, maxTokens: 600)
        guard let o = JSONExtract.object(raw) else { throw AIError(message: "Bewertung fehlgeschlagen.") }
        let score = (o["score"] as? NSNumber)?.doubleValue ?? 0
        return Grade(score: min(1, max(0, score > 1 ? score / 100 : score)), feedback: (o["feedback"] as? String) ?? "")
    }

    // MARK: Wochenfazit

    static func weekReflection(report: WeekReport, next: WeekReport, store: DataStore, onUpdate: @escaping @MainActor (String) -> Void) async throws -> String {
        guard let client = DeepSeekClient.fromSettings(store.prefs) else { throw AIError(message: "Kein API-Key hinterlegt.") }
        let lines = report.lines.map { "- \($0.name): \(Fmt.hours($0.logged)) von \(Fmt.hours($0.goal)), Blöcke \($0.blocksDone)/\($0.blocksPlanned)" }.joined(separator: "\n")
        let dl = report.deadlines.map { "- \($0.kind.label) \($0.title): \($0.done ? "erledigt" : "offen")" }.joined(separator: "\n")
        let nextDl = next.deadlines.map { "- \($0.kind.label) \($0.title) am \(Fmt.dayShort($0.date))" }.joined(separator: "\n")
        let user = """
        Schreibe ein ehrliches, motivierendes Wochenfazit (Markdown, max. 180 Wörter) für einen Studenten, der nebenbei als Werkstudent arbeitet.
        Woche KW \(report.weekStart.weekNumber):
        \(lines)
        Gesamt: \(Fmt.hours(report.totalLogged)) von \(Fmt.hours(report.totalGoal)). Arbeit: \(Fmt.hours(report.workMinutes)). Aufgaben erledigt: \(report.tasksDone.count), fällig: \(report.tasksDue.count).
        Fristen dieser Woche:
        \(dl.isEmpty ? "keine" : dl)
        Nächste Woche: Arbeit \(Fmt.hours(next.workMinutes)), Fristen:
        \(nextDl.isEmpty ? "keine" : nextDl)
        Aufbau: **Fazit** (1–2 Sätze), **Lief gut**, **Verbessern**, **Fokus nächste Woche** (3 konkrete Punkte).
        """
        return try await client.complete(system: tutor, user: user, temperature: 0.6, maxTokens: 900) { onUpdate($0.content) }
    }
}
