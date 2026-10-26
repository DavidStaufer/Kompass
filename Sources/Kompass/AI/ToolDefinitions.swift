import Foundation

/// JSON-Schema-Bausteine für die Werkzeuge der KI.
enum P {
    typealias Schema = [String: Any]
    static func s(_ d: String) -> Schema { ["type": "string", "description": d] }
    static func e(_ d: String, _ v: [String]) -> Schema { ["type": "string", "description": d, "enum": v] }
    static func i(_ d: String) -> Schema { ["type": "integer", "description": d] }
    static func n(_ d: String) -> Schema { ["type": "number", "description": d] }
    static func b(_ d: String) -> Schema { ["type": "boolean", "description": d] }
    static func a(_ d: String, _ items: Schema) -> Schema { ["type": "array", "description": d, "items": items] }
    static func o(_ props: [String: Schema], _ req: [String] = []) -> Schema { ["type": "object", "properties": props, "required": req] }
}

enum ToolDefinitions {
    private static func fn(_ name: String, _ desc: String, _ props: [String: P.Schema] = [:], _ req: [String] = []) -> [String: Any] {
        let params: [String: Any] = ["type": "object", "properties": props, "required": req]
        let function: [String: Any] = ["name": name, "description": desc, "parameters": params]
        return ["type": "function", "function": function]
    }

    static let dt = "Lokale Zeit im Format YYYY-MM-DDTHH:MM (oder YYYY-MM-DD für ganztägig)"
    static let mod = "Modul-ID (aus list_modules) oder exakter Modulname"

    static let all: [[String: Any]] = {
        var t: [[String: Any]] = []
        // Überblick & Module
        t.append(fn("get_overview", "Kompletter Überblick: heutige Termine, anstehende Fristen, offene Aufgaben, Module mit Fortschritt und Wochenstand. Nutze das zuerst, wenn du Kontext brauchst."))
        t.append(fn("list_modules", "Listet alle Module des aktuellen Semesters mit ID, Fortschritt, Klausurdatum.", ["include_archived": P.b("Auch archivierte/alte Module")]))
        t.append(fn("get_module", "Details eines Moduls: Themen (mit IDs und Sicherheit), Materialien (mit IDs), Veranstaltungen, Fristen, Dokumente, Quizze, Karteikarten.", ["module": P.s(mod)], ["module"]))
        t.append(fn("create_module", "Legt ein neues Modul an.", [
            "name": P.s("Name des Moduls"), "code": P.s("Kürzel, z. B. ANA1"), "ects": P.n("ECTS-Punkte"),
            "color": P.e("Farbe", ModuleColor.allCases.map(\.rawValue)), "weekly_goal_hours": P.n("Selbststudium pro Woche in Stunden"),
            "lecturer": P.s("Dozent/in"), "notes": P.s("Notizen")
        ], ["name"]))
        t.append(fn("update_module", "Ändert Eigenschaften eines Moduls.", [
            "module": P.s(mod), "name": P.s("Neuer Name"), "code": P.s("Kürzel"), "ects": P.n("ECTS"),
            "color": P.e("Farbe", ModuleColor.allCases.map(\.rawValue)), "weekly_goal_hours": P.n("Wochenziel in Stunden"),
            "lecturer": P.s("Dozent/in"), "notes": P.s("Notizen (ersetzt)"), "archived": P.b("Archivieren")
        ], ["module"]))
        t.append(fn("delete_module", "Löscht ein Modul samt Materialien, Karteikarten und Quizzen (Nutzer muss bestätigen).", ["module": P.s(mod)], ["module"]))
        t.append(fn("add_course_session", "Fügt eine wöchentliche Veranstaltung (Vorlesung, Übung …) hinzu und trägt sie als Serie in den Kalender ein.", [
            "module": P.s(mod), "kind": P.e("Art", SessionKind.allCases.map(\.rawValue)),
            "weekday": P.i("Wochentag 1=Montag … 7=Sonntag"), "start": P.s("Beginn HH:MM"), "end": P.s("Ende HH:MM"),
            "room": P.s("Raum"), "biweekly": P.b("Nur alle 2 Wochen")
        ], ["module", "kind", "weekday", "start", "end"]))
        t.append(fn("remove_course_session", "Entfernt eine Veranstaltung samt Kalenderserie (Nutzer muss bestätigen).", ["module": P.s(mod), "session_id": P.s("ID der Veranstaltung aus get_module")], ["module", "session_id"]))
        t.append(fn("add_topics", "Fügt Themen/Kapitel zu einem Modul hinzu (für Fortschritt und Lernplanung).", [
            "module": P.s(mod), "topics": P.a("Themen-Titel", P.s("Titel")), "covered": P.b("Bereits in der Vorlesung behandelt")
        ], ["module", "topics"]))
        t.append(fn("update_topic", "Aktualisiert ein Thema: Sicherheit (0–1) oder ob es behandelt wurde.", [
            "module": P.s(mod), "topic": P.s("Themen-ID oder Titel"), "confidence": P.n("Sicherheit 0 bis 1"), "covered": P.b("Behandelt"), "title": P.s("Neuer Titel")
        ], ["module", "topic"]))

        // Kalender
        t.append(fn("list_events", "Listet Termine aus allen Apple-Kalendern im Zeitraum (inkl. Vorlesungen, Lernblöcken, Arbeit, Privates).", [
            "start": P.s(dt), "end": P.s(dt)
        ], ["start", "end"]))
        t.append(fn("find_free_time", "Findet freie Zeitfenster innerhalb der Lernzeiten des Nutzers (berücksichtigt Termine, Arbeit und Puffer).", [
            "start": P.s(dt), "end": P.s(dt), "min_minutes": P.i("Mindestlänge in Minuten (Standard 45)")
        ], ["start", "end"]))
        t.append(fn("create_event", "Erstellt einen Termin in Apple Kalender (Standard: Kompass-Kalender).", [
            "title": P.s("Titel"), "start": P.s(dt), "end": P.s(dt), "all_day": P.b("Ganztägig"),
            "module": P.s("Optional: zugehöriges Modul"), "location": P.s("Ort"), "notes": P.s("Notizen"),
            "calendar": P.s("Optional: Name eines anderen Kalenders"), "alarm_minutes_before": P.i("Erinnerung X Minuten vorher"),
            "study_block": P.b("Als Lernblock zählen (für Fortschritt und Wochenrückblick); benötigt module")
        ], ["title", "start", "end"]))
        t.append(fn("update_event", "Ändert/verschiebt einen bestehenden Termin (event_id aus list_events).", [
            "event_id": P.s("ID aus list_events"), "title": P.s("Neuer Titel"), "start": P.s(dt), "end": P.s(dt),
            "location": P.s("Ort"), "notes": P.s("Notizen")
        ], ["event_id"]))
        t.append(fn("delete_event", "Löscht einen Termin (Nutzer muss bestätigen).", ["event_id": P.s("ID aus list_events")], ["event_id"]))

        // Fristen & Aufgaben
        t.append(fn("create_deadline", "Legt eine Klausur, Abgabe, Präsentation, ein Testat, eine Prüfungsanmeldung o. Ä. an – inkl. Kalendereintrag, Erinnerungen-App und Mitteilungen.", [
            "title": P.s("Titel"), "kind": P.e("Art", DeadlineKind.allCases.map(\.rawValue)), "date": P.s(dt),
            "module": P.s("Zugehöriges Modul"), "all_day": P.b("Ganztägig"), "duration_minutes": P.i("Dauer, z. B. Klausurdauer"),
            "location": P.s("Ort/Raum"), "notes": P.s("Notizen"), "prep_hours": P.n("Geschätzter Vorbereitungsaufwand in Stunden"),
            "remind_days_before": P.a("Erinnerungen X Tage vorher (Standard je nach Art)", ["type": "number"])
        ], ["title", "kind", "date"]))
        t.append(fn("list_deadlines", "Listet Fristen (Klausuren, Abgaben, Präsentationen …).", ["include_done": P.b("Auch erledigte"), "module": P.s("Nur dieses Modul")]))
        t.append(fn("update_deadline", "Ändert eine Frist oder markiert sie als erledigt.", [
            "deadline_id": P.s("ID aus list_deadlines"), "title": P.s("Titel"), "date": P.s(dt), "done": P.b("Erledigt"),
            "location": P.s("Ort"), "notes": P.s("Notizen"), "prep_hours": P.n("Vorbereitungsaufwand in h")
        ], ["deadline_id"]))
        t.append(fn("delete_deadline", "Löscht eine Frist (Nutzer muss bestätigen).", ["deadline_id": P.s("ID")], ["deadline_id"]))
        t.append(fn("create_task", "Legt eine Aufgabe (To-do) an, optional mit Fälligkeit und Zeitschätzung.", [
            "title": P.s("Titel"), "module": P.s("Modul"), "due": P.s(dt), "estimate_minutes": P.i("Geschätzte Dauer in Minuten"), "notes": P.s("Notizen")
        ], ["title"]))
        t.append(fn("list_tasks", "Listet Aufgaben.", ["include_done": P.b("Auch erledigte")]))
        t.append(fn("update_task", "Ändert eine Aufgabe oder hakt sie ab.", [
            "task_id": P.s("ID aus list_tasks"), "done": P.b("Erledigt"), "title": P.s("Titel"), "due": P.s(dt), "estimate_minutes": P.i("Minuten")
        ], ["task_id"]))

        // Materialien & Lernen
        t.append(fn("list_materials", "Listet die hochgeladenen Materialien eines Moduls (Vorlesungen, Übungen, Altklausuren …).", ["module": P.s(mod)], ["module"]))
        t.append(fn("search_materials", "Volltextsuche in den Materialien. Liefert passende Textstellen mit Quelle (Seite/Folie).", [
            "query": P.s("Suchbegriffe"), "module": P.s("Optional: nur in diesem Modul"), "limit": P.i("Anzahl Treffer (Standard 6)")
        ], ["query"]))
        t.append(fn("read_material", "Liest den Text eines Materials (abschnittsweise über offset).", [
            "material_id": P.s("ID aus list_materials"), "offset": P.i("Startzeichen (Standard 0)"), "max_chars": P.i("Maximal Zeichen (Standard 12000, max 20000)")
        ], ["material_id"]))
        t.append(fn("set_material_studied", "Markiert ein Material als durchgearbeitet (zählt zum Fortschritt).", [
            "material_id": P.s("ID"), "studied": P.b("Durchgearbeitet")
        ], ["material_id", "studied"]))
        t.append(fn("save_document", "Speichert ein längeres Ergebnis (Zusammenfassung, Probeklausur mit Lösungen, Lernplan, Erklärung) als Dokument im Modul. Markdown. Bei Probeklausuren die Lösungen unter einer Überschrift '## Lösungen' am Ende.", [
            "module": P.s("Modul"), "kind": P.e("Art", DocKind.allCases.map(\.rawValue)), "title": P.s("Titel"), "markdown": P.s("Inhalt in Markdown")
        ], ["kind", "title", "markdown"]))
        t.append(fn("create_flashcards", "Erstellt Karteikarten (Spaced Repetition) für ein Modul.", [
            "module": P.s(mod),
            "cards": P.a("Karten", P.o(["front": P.s("Frage/Begriff"), "back": P.s("Antwort"), "topic": P.s("Thema")], ["front", "back"]))
        ], ["module", "cards"]))
        t.append(fn("create_quiz", "Erstellt ein interaktives Quiz, das der Nutzer in der App lösen kann.", [
            "module": P.s(mod), "title": P.s("Titel"),
            "questions": P.a("Fragen", P.o([
                "type": P.e("single_choice oder open", ["single_choice", "open"]), "question": P.s("Frage"),
                "options": P.a("Antwortoptionen (nur single_choice)", P.s("Option")), "correct_index": P.i("Index der richtigen Option (0-basiert)"),
                "answer": P.s("Musterlösung"), "explanation": P.s("Kurze Erklärung"), "topic": P.s("Thema")
            ], ["type", "question"]))
        ], ["module", "title", "questions"]))
        t.append(fn("record_quiz_result", "Hält das Ergebnis einer Abfrage im Chat fest und aktualisiert die Themen-Sicherheit.", [
            "module": P.s(mod), "topic": P.s("Thema"), "correct": P.i("Richtig beantwortet"), "total": P.i("Gestellte Fragen")
        ], ["module", "correct", "total"]))
        // Zeiterfassung
        t.append(fn("log_time", "Bucht Zeit (wie ein Jira-Worklog) auf ein Modul, auf Arbeit oder eine eigene Kategorie, optional auf eine Aufgabe/Frist.", [
            "category": P.s("Modulname/-ID, „Arbeit“ oder Name einer eigenen Kategorie"),
            "duration": P.s("Dauer im Jira-Format, z. B. „1h 30m“, „45m“, „2h“"), "minutes": P.i("Alternativ: Minuten"),
            "start": P.s(dt), "activity": P.e("Art", ActivityKind.allCases.map(\.rawValue)),
            "task_id": P.s("Optional: Aufgaben-ID"), "deadline_id": P.s("Optional: Fristen-ID"), "note": P.s("Beschreibung")
        ], ["category"]))
        t.append(fn("get_time_report", "Auswertung der Zeiterfassung: Summen je Kategorie, Art, Tag oder Woche – z. B. „wie viel habe ich diesen Monat gearbeitet“.", [
            "start": P.s(dt), "end": P.s(dt),
            "group_by": P.e("Gruppierung", ["category", "activity", "day", "week"]),
            "category": P.s("Optional: nur dieses Modul / „Arbeit“ / Kategorie / „Studium“"),
            "activity_filter": P.e("Optional", ["all", "self_study", "courses", "work", "other"])
        ], ["start", "end"]))
        t.append(fn("list_worklogs", "Listet einzelne Zeitbuchungen (mit IDs).", [
            "start": P.s(dt), "end": P.s(dt), "category": P.s("Optional: Filter")
        ], ["start", "end"]))
        t.append(fn("update_worklog", "Ändert eine Zeitbuchung.", [
            "worklog_id": P.s("ID aus list_worklogs"), "duration": P.s("Neue Dauer, z. B. „2h“"), "start": P.s(dt),
            "category": P.s("Neue Kategorie"), "activity": P.e("Art", ActivityKind.allCases.map(\.rawValue)), "note": P.s("Beschreibung")
        ], ["worklog_id"]))
        t.append(fn("delete_worklog", "Löscht eine Zeitbuchung (Nutzer muss bestätigen).", ["worklog_id": P.s("ID")], ["worklog_id"]))
        t.append(fn("list_unconfirmed", "Vergangene Termine (Vorlesungen, Lernblöcke, Arbeit, gemerkte private Termine), die noch nicht als wahrgenommen bestätigt wurden.", [
            "days": P.i("Wie viele Tage zurück (Standard 7)")
        ]))
        t.append(fn("confirm_attendance", "Markiert Termin-Vorkommen als wahrgenommen (bucht die Zeit) oder als nicht wahrgenommen. Bei Serien gilt es nur für dieses eine Vorkommen.", [
            "keys": P.a("Schlüssel aus list_unconfirmed", P.s("key")), "all": P.b("Alle offenen der letzten 7 Tage"),
            "attended": P.b("true = wahrgenommen (Standard), false = nicht wahrgenommen")
        ]))
        t.append(fn("create_time_category", "Legt eine eigene Zeitkategorie an (z. B. Sport, Haushalt).", [
            "name": P.s("Name"), "color": P.e("Farbe", ModuleColor.allCases.map(\.rawValue))
        ], ["name"]))

        // Planung
        t.append(fn("get_week_review", "Wochenbilanz: Soll (Wochenziele, geplante Blöcke, fällige Aufgaben/Fristen) vs. Ist (gelernte Zeit, erledigte Blöcke/Aufgaben) plus Belastung (Arbeit, Vorlesungen, freie Zeit).", [
            "week_offset": P.i("0 = diese Woche, -1 = letzte, 1 = nächste")
        ]))
        t.append(fn("plan_study_blocks", "Plant Lernblöcke automatisch in freie Zeiten einer Woche (nach Wochenzielen, Klausurnähe, Abgaben, Arbeitszeiten). Mit commit=false nur Vorschlag, mit commit=true direkt in den Kalender.", [
            "week_offset": P.i("0 = diese Woche, 1 = nächste"), "commit": P.b("Direkt eintragen")
        ]))
        t.append(fn("clear_study_blocks", "Entfernt noch nicht erledigte, geplante Lernblöcke einer Woche aus Plan und Kalender (Nutzer muss bestätigen).", [
            "week_offset": P.i("0 = diese Woche, 1 = nächste"), "module": P.s("Optional: nur dieses Modul")
        ]))
        t.append(fn("add_work_block", "Fügt einen festen, wöchentlichen Arbeitsblock (Werkstudent) hinzu.", [
            "weekday": P.i("1=Montag … 7=Sonntag"), "start": P.s("HH:MM"), "end": P.s("HH:MM"), "label": P.s("Bezeichnung")
        ], ["weekday", "start", "end"]))
        t.append(fn("update_study_preferences", "Ändert die Lernzeit-Einstellungen des Nutzers.", [
            "study_day_start": P.s("Frühester Lernbeginn HH:MM"), "study_day_end": P.s("Spätestes Lernende HH:MM"),
            "max_minutes_per_day": P.i("Maximale Lernzeit pro Tag in Minuten"), "block_minutes": P.i("Standard-Blocklänge in Minuten"),
            "break_minutes": P.i("Pause zwischen Blöcken"), "study_on_weekends": P.b("Am Wochenende lernen"), "weekend_max_minutes": P.i("Max. Minuten an Wochenendtagen")
        ]))

        // Bedienung
        t.append(fn("open_view", "Öffnet eine Ansicht in der App.", [
            "view": P.e("Ansicht", ["today", "calendar", "week", "deadlines", "cards", "module", "quiz", "document"]),
            "module": P.s("Für view=module"), "id": P.s("Quiz- oder Dokument-ID"), "date": P.s("Für view=calendar: Datum")
        ], ["view"]))
        t.append(fn("start_focus_timer", "Startet den Fokus-Timer für ein Modul (Lernzeit wird erfasst).", [
            "module": P.s(mod), "minutes": P.i("Dauer in Minuten (Standard 50)")
        ], ["module"]))
        return t
    }()

    static func activityLabel(_ name: String) -> String {
        switch name {
        case "get_overview": return "Verschafft sich einen Überblick"
        case "list_modules", "get_module": return "Schaut in deine Module"
        case "create_module": return "Legt Modul an"
        case "update_module": return "Aktualisiert Modul"
        case "add_course_session": return "Trägt Veranstaltung ein"
        case "add_topics", "update_topic": return "Aktualisiert Themen"
        case "list_events": return "Liest deinen Kalender"
        case "find_free_time": return "Sucht freie Zeiten"
        case "create_event": return "Erstellt Termin"
        case "update_event": return "Verschiebt Termin"
        case "delete_event": return "Löscht Termin"
        case "create_deadline", "update_deadline": return "Pflegt Fristen"
        case "list_deadlines": return "Prüft Fristen"
        case "create_task", "update_task", "list_tasks": return "Pflegt Aufgaben"
        case "list_materials": return "Sichtet Materialien"
        case "search_materials": return "Durchsucht Materialien"
        case "read_material": return "Liest Material"
        case "save_document": return "Speichert Dokument"
        case "create_flashcards": return "Erstellt Karteikarten"
        case "create_quiz": return "Erstellt Quiz"
        case "record_quiz_result": return "Speichert Ergebnis"
        case "log_study_time", "log_time": return "Bucht Zeit"
        case "get_time_report", "list_worklogs": return "Wertet Zeiten aus"
        case "update_worklog", "delete_worklog": return "Pflegt Zeitbuchungen"
        case "list_unconfirmed": return "Prüft offene Termine"
        case "confirm_attendance": return "Bestätigt Termine"
        case "create_time_category": return "Legt Kategorie an"
        case "get_week_review": return "Erstellt Wochenbilanz"
        case "plan_study_blocks": return "Plant Lernblöcke"
        case "clear_study_blocks": return "Räumt Lernblöcke auf"
        case "add_work_block": return "Trägt Arbeitszeit ein"
        case "update_study_preferences": return "Passt Lernzeiten an"
        case "open_view": return "Öffnet Ansicht"
        case "start_focus_timer": return "Startet Fokus-Timer"
        default: return "Arbeitet"
        }
    }
}
