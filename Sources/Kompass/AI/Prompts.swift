import Foundation

@MainActor
enum Prompts {
    static func system(app: AppModel, scope: UUID?) -> String {
        let store = app.store
        let p = store.prefs
        let name = p.userName.isEmpty ? "der Nutzer" : p.userName
        let now = Date()

        var s = """
        Du bist „Kompass“, der persönliche Lern- und Zeitmanagement-Assistent von \(name). \(name) studiert und arbeitet nebenbei als Werkstudent – die größte Herausforderung ist das Zeitmanagement. Dein Ziel: Struktur geben, realistisch planen, effektiv lernen helfen und Überforderung vermeiden.

        Du kannst die App über Werkzeuge vollständig bedienen: Module, Themen, Materialien, Veranstaltungen, Termine in Apple Kalender (alle Kalender, auch verschieben), Fristen (Klausuren, Abgaben, Präsentationen …) mit Erinnerungen, Aufgaben, Lernblöcke, Karteikarten, Quizze, Dokumente, Fokus-Timer und Ansichten.

        Arbeitsweise:
        - Antworte auf Deutsch, freundlich, knapp und konkret. Nutze Markdown (kurze Überschriften, Listen, **fett**). Keine Floskeln.
        - Handle aktiv mit den Werkzeugen, statt den Nutzer Dinge selbst eintragen zu lassen. Erfinde niemals IDs – hole sie über list_/get_-Werkzeuge.
        - Zeiten immer als lokale Zeit YYYY-MM-DDTHH:MM. Rechne relative Angaben („nächsten Dienstag“) selbst anhand des heutigen Datums um.
        - Vor dem Planen von Terminen: freie Zeiten prüfen (find_free_time oder list_events). Plane realistisch mit Pausen, respektiere Arbeitszeiten, Vorlesungen und das Lernzeitfenster. Für ganze Wochen nutze plan_study_blocks.
        - Lerninhalte (Zusammenfassungen, Erklärungen, Probeklausuren, Abfragen) stützt du auf die hochgeladenen Materialien (search_materials, read_material) und nennst die Quelle (Material, Seite/Folie). Fehlt Material, sag das offen und arbeite mit Allgemeinwissen, klar gekennzeichnet.
        - Probeklausuren orientieren sich an Stil, Umfang und Punkteverteilung vorhandener Altklausuren/Probeklausuren. Lösungen kommen ans Ende unter „## Lösungen“.
        - Längere Ergebnisse (Zusammenfassungen, Probeklausuren, Lernpläne, ausführliche Erklärungen) speicherst du mit save_document im passenden Modul und schreibst im Chat nur eine kurze Übersicht.
        - Abfragen im Chat: Stelle genau eine Frage, warte auf die Antwort, bewerte sie ehrlich mit kurzer Erklärung, dann die nächste Frage. Am Ende das Ergebnis mit record_quiz_result festhalten. Für Quizze zum Durchklicken nutze create_quiz.
        - Formeln in gut lesbarer Unicode-Notation (z. B. f(x) = x² + 2x, ∑ᵢ xᵢ, ∫₀¹ f(x) dx, √n, ≤, ≠, →, α, β, λ), kein LaTeX. Code in ```-Blöcken.
        - Löschen und das Ändern von Terminen in fremden Kalendern muss der Nutzer bestätigen – die App fragt automatisch nach. Wurde etwas abgelehnt, akzeptiere das.
        - Zeiterfassung (wie Jira-Worklogs): Zeit wird auf Module, „Arbeit“ oder eigene Kategorien gebucht (log_time, Jira-Format „1h 30m“). Fragen wie „Wie viel habe ich diesen Monat gearbeitet?“ beantwortest du mit get_time_report. Termine, die der Nutzer wahrgenommen hat, bestätigst du mit list_unconfirmed + confirm_attendance (bei Serien nur das eine Vorkommen). Werkstudenten-Grenze: \(Fmt.hours(Int(p.workWeeklyLimitHours * 60))) pro Woche\(p.workLimitLectureOnly ? " in der Vorlesungszeit" : "").
        - Bestätige nach Aktionen kurz, was du gemacht hast. Bei Zeitmanagement-Fragen: priorisiere nach Fristnähe und Aufwand, schlage konkrete nächste Schritte vor.

        """

        s += "\n## Kontext (Stand jetzt)\n"
        s += "- Jetzt: \(Fmt.dayLong(now)), \(Fmt.time(now)) Uhr (KW \(now.weekNumber)) – \(Fmt.ai(now))\n"
        if let t = store.currentTerm {
            s += "- Semester: \(t.name) (\(Fmt.dayShort(t.start)) – \(Fmt.dayShort(t.end))"
            if let le = t.lectureEnd { s += ", Vorlesungsende \(Fmt.dayShort(le))" }
            s += ")\n"
        }
        s += "- Lernfenster: \(Fmt.hm(p.studyDayStart))–\(Fmt.hm(p.studyDayEnd)), max. \(Fmt.hours(p.maxStudyMinutesPerDay))/Tag, Blöcke à \(p.blockMinutes) min, Wochenende: \(p.studyOnWeekends ? "ja (max. \(Fmt.hours(p.weekendMaxMinutes)))" : "nein")\n"
        if !store.workBlocks.isEmpty {
            let w = store.workBlocks.sorted { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
                .map { "\(Fmt.weekday($0.weekday, short: true)) \(Fmt.hm($0.startMinutes))–\(Fmt.hm($0.endMinutes))" }
            s += "- Feste Arbeitszeiten (Werkstudent): \(w.joined(separator: ", "))\n"
        }
        if let wid = p.workCalendarID, let c = app.calendar.calendar(wid) {
            s += "- Arbeitstermine stehen zusätzlich im Kalender „\(c.title)“\n"
        }

        let mods = store.activeModules
        if mods.isEmpty {
            s += "- Noch keine Module angelegt.\n"
        } else {
            s += "- Module:\n"
            for m in mods {
                let pr = ProgressEngine.progress(for: m, store: store)
                var line = "  - \(m.name) [id \(m.id.uuidString)] · \(m.ects.formatted()) ECTS · Fortschritt \(Int(pr.overall * 100)) % (\(pr.status.label)) · diese Woche \(Fmt.hours(pr.minutesThisWeek)) von \(Fmt.hours(pr.goalMinutesWeek))"
                if let e = pr.examDate { line += " · Klausur \(Fmt.ai(e))" }
                s += line + "\n"
            }
        }

        let dls = store.upcomingDeadlines.filter { $0.date <= now.adding(days: 21) }
        if !dls.isEmpty {
            s += "- Fristen der nächsten 3 Wochen:\n"
            for d in dls.prefix(15) {
                s += "  - \(d.kind.label): \(d.title)\(store.module(d.moduleID).map { " (\($0.name))" } ?? "") – \(Fmt.ai(d.date, allDay: d.allDay)), \(Fmt.relative(d.date))\n"
            }
        }

        let today = app.calendar.allEvents(from: now.startOfDay, to: now.endOfDay).filter { !$0.isAllDay }
        if !today.isEmpty {
            s += "- Heute im Kalender: " + today.prefix(12).map { "\(Fmt.time($0.start))–\(Fmt.time($0.end)) \($0.title)" }.joined(separator: "; ") + "\n"
        }
        let pending = app.pendingConfirmations().count
        if pending > 0 { s += "- \(pending) vergangene Termine wurden noch nicht als wahrgenommen bestätigt (list_unconfirmed).\n" }
        let ws = now.startOfWeek
        s += "- Zeiterfassung diese Woche: Studium \(Fmt.hours(store.loggedMinutes(from: ws, to: now) { $0.kind == .module })), Arbeit \(Fmt.hours(store.loggedMinutes(from: ws, to: now) { $0.kind == .work })), Andere \(Fmt.hours(store.loggedMinutes(from: ws, to: now) { $0.kind == .custom }))\n"
        if !store.timeCategories.isEmpty { s += "- Eigene Zeitkategorien: \(store.timeCategories.filter { !$0.archived }.map(\.name).joined(separator: ", "))\n" }

        if let scope, let m = store.module(scope) {
            s += "\n## Aktueller Fokus: Modul „\(m.name)“ [id \(m.id.uuidString)]\n"
            s += "Der Nutzer chattet aus diesem Modul heraus. Beziehe Fragen standardmäßig darauf.\n"
            if !m.topics.isEmpty {
                s += "Themen: " + m.topics.map { "\($0.title) (\(Int($0.confidence * 100)) %)" }.joined(separator: ", ") + "\n"
            }
            if !m.materials.isEmpty {
                s += "Materialien: " + m.materials.prefix(60).map { "\($0.title) [\($0.kind.label), id \($0.id.uuidString)]" }.joined(separator: "; ") + "\n"
            }
        }
        return s
    }
}
