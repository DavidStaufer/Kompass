import Foundation
import EventKit

/// Bequemer Zugriff auf die Argumente eines Tool-Calls.
struct ToolArgs {
    let raw: [String: Any]

    init(_ json: String) {
        if let d = json.data(using: .utf8), let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] { raw = o } else { raw = [:] }
    }

    func str(_ k: String) -> String? {
        if let s = raw[k] as? String { return s.trimmed.nilIfEmpty }
        if let n = raw[k] as? NSNumber { return n.stringValue }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let n = raw[k] as? NSNumber { return n.intValue }
        if let s = raw[k] as? String { return Int(s.trimmed) ?? Double(s.trimmed).map { Int($0) } }
        return nil
    }
    func double(_ k: String) -> Double? {
        if let n = raw[k] as? NSNumber { return n.doubleValue }
        if let s = raw[k] as? String { return Double(s.replacingOccurrences(of: ",", with: ".").trimmed) }
        return nil
    }
    func bool(_ k: String) -> Bool? {
        if let b = raw[k] as? Bool { return b }
        if let n = raw[k] as? NSNumber { return n.boolValue }
        if let s = raw[k] as? String { return ["true", "ja", "yes", "1"].contains(s.lowercased()) }
        return nil
    }
    func date(_ k: String) -> Date? { Fmt.parse(str(k)) }
    func strings(_ k: String) -> [String] {
        if let a = raw[k] as? [Any] { return a.compactMap { ($0 as? String)?.trimmed.nilIfEmpty } }
        if let s = raw[k] as? String { return s.split(whereSeparator: { $0 == "\n" || $0 == ";" }).map { String($0).trimmed }.filter { !$0.isEmpty } }
        return []
    }
    func objects(_ k: String) -> [[String: Any]] { raw[k] as? [[String: Any]] ?? [] }
}

struct ToolOutcome {
    var result: String
    var summary: String
    var isError = false
    var attachment: ChatAttachment?
}

@MainActor
struct ToolExecutor {
    let app: AppModel
    var store: DataStore { app.store }
    var cal: CalendarService { app.calendar }

    // MARK: Bestätigung

    /// Liefert einen Bestätigungstext, falls die Aktion vom Nutzer freigegeben werden muss.
    func confirmation(for name: String, args: ToolArgs) -> (title: String, detail: String)? {
        switch name {
        case "delete_module":
            guard let m = store.findModule(args.str("module")) else { return nil }
            return ("Modul „\(m.name)“ löschen?", "Alle Materialien, Karteikarten, Quizze und Dokumente dieses Moduls werden entfernt.")
        case "remove_course_session":
            return ("Veranstaltung entfernen?", "Die wöchentliche Serie wird auch aus Apple Kalender gelöscht.")
        case "delete_event":
            guard let id = args.str("event_id"), let e = cal.ekEvent(id: id) else { return nil }
            return ("Termin „\(e.title ?? "")“ löschen?", "\(Fmt.dateTime(e.startDate)) · Kalender „\(e.calendar?.title ?? "")“")
        case "update_event":
            guard store.prefs.aiConfirmExternalEdits, let id = args.str("event_id"), let e = cal.ekEvent(id: id) else { return nil }
            if e.calendar?.calendarIdentifier == store.prefs.kompassCalendarID { return nil }
            var change: [String] = []
            if let s = args.date("start") { change.append("Neu: \(Fmt.dateTime(s))") }
            if let t = args.str("title") { change.append("Titel: \(t)") }
            return ("Termin „\(e.title ?? "")“ ändern?", "Kalender „\(e.calendar?.title ?? "")“. " + change.joined(separator: " · "))
        case "delete_worklog":
            guard let id = args.str("worklog_id").flatMap(UUID.init(uuidString:)), let w = store.worklogs.first(where: { $0.id == id }) else { return nil }
            return ("Zeitbuchung löschen?", "\(store.label(for: TrackTarget(w)).name) · \(Fmt.dateTime(w.start)) · \(Fmt.duration(w.minutes))")
        case "delete_deadline":
            guard let id = args.str("deadline_id").flatMap(UUID.init(uuidString:)), let d = store.deadline(id) else { return nil }
            return ("\(d.kind.label) „\(d.title)“ löschen?", "Auch Kalendereintrag und Erinnerung werden entfernt.")
        case "clear_study_blocks":
            return ("Geplante Lernblöcke entfernen?", "Noch nicht erledigte Lernblöcke der gewählten Woche werden aus Plan und Kalender gelöscht.")
        default:
            return nil
        }
    }

    // MARK: Ausführen

    func run(_ name: String, _ args: ToolArgs) async -> ToolOutcome {
        switch name {
        case "get_overview": return overview()
        case "list_modules": return listModules(args)
        case "get_module": return getModule(args)
        case "create_module": return createModule(args)
        case "update_module": return updateModule(args)
        case "delete_module": return deleteModule(args)
        case "add_course_session": return addSession(args)
        case "remove_course_session": return removeSession(args)
        case "add_topics": return addTopics(args)
        case "update_topic": return updateTopic(args)
        case "list_events": return listEvents(args)
        case "find_free_time": return freeTime(args)
        case "create_event": return createEvent(args)
        case "update_event": return updateEvent(args)
        case "delete_event": return deleteEvent(args)
        case "create_deadline": return createDeadline(args)
        case "list_deadlines": return listDeadlines(args)
        case "update_deadline": return updateDeadline(args)
        case "delete_deadline": return deleteDeadline(args)
        case "create_task": return createTask(args)
        case "list_tasks": return listTasks(args)
        case "update_task": return updateTask(args)
        case "list_materials": return listMaterials(args)
        case "search_materials": return searchMaterials(args)
        case "read_material": return readMaterial(args)
        case "set_material_studied": return setStudied(args)
        case "save_document": return saveDocument(args)
        case "create_flashcards": return createFlashcards(args)
        case "create_quiz": return createQuiz(args)
        case "record_quiz_result": return recordResult(args)
        case "log_study_time", "log_time": return logTime(args)
        case "get_time_report": return timeReport(args)
        case "list_worklogs": return listWorklogs(args)
        case "update_worklog": return updateWorklog(args)
        case "delete_worklog": return deleteWorklog(args)
        case "list_unconfirmed": return listUnconfirmed(args)
        case "confirm_attendance": return confirmAttendance(args)
        case "create_time_category": return createCategory(args)
        case "get_week_review": return weekReview(args)
        case "plan_study_blocks": return planBlocks(args)
        case "clear_study_blocks": return clearBlocks(args)
        case "add_work_block": return addWorkBlock(args)
        case "update_study_preferences": return updatePrefs(args)
        case "open_view": return openView(args)
        case "start_focus_timer": return startTimer(args)
        default: return fail("Unbekanntes Werkzeug: \(name)")
        }
    }

    // MARK: Hilfen

    private func json(_ obj: Any) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }

    private func ok(_ obj: Any, _ summary: String, attachment: ChatAttachment? = nil) -> ToolOutcome {
        ToolOutcome(result: json(obj), summary: summary, attachment: attachment)
    }

    private func fail(_ message: String) -> ToolOutcome {
        ToolOutcome(result: json(["fehler": message]), summary: message, isError: true)
    }

    private func requireModule(_ args: ToolArgs, key: String = "module") -> Module? {
        store.findModule(args.str(key)) ?? (args.str(key) == nil ? store.module(app.assistant.scopeModuleID) : nil)
    }

    private func moduleDict(_ m: Module, detailed: Bool = false) -> [String: Any] {
        let p = ProgressEngine.progress(for: m, store: store)
        var d: [String: Any] = [
            "id": m.id.uuidString, "name": m.name, "kuerzel": m.displayCode, "ects": m.ects,
            "wochenziel_stunden": m.weeklyGoalHours, "fortschritt_prozent": Int(p.overall * 100),
            "status": p.status.label, "gelernt_diese_woche_min": p.minutesThisWeek,
            "themen_anzahl": m.topics.count, "materialien_anzahl": m.materials.count
        ]
        if let e = p.examDate { d["klausur"] = Fmt.ai(e) }
        if m.archived { d["archiviert"] = true }
        guard detailed else { return d }
        d["dozent"] = m.lecturer
        d["notizen"] = m.notes
        d["themen"] = m.topics.map { ["id": $0.id.uuidString, "titel": $0.title, "sicherheit_prozent": Int($0.confidence * 100), "behandelt": $0.covered] as [String: Any] }
        d["materialien"] = m.materials.map(materialDict)
        d["veranstaltungen"] = m.sessions.map { s -> [String: Any] in
            ["id": s.id.uuidString, "art": s.kind.label, "wochentag": Fmt.weekday(s.weekday), "von": Fmt.hm(s.startMinutes),
             "bis": Fmt.hm(s.endMinutes), "raum": s.room, "zweiwoechentlich": s.biweekly]
        }
        d["fristen"] = store.deadlines.filter { $0.moduleID == m.id }.sorted { $0.date < $1.date }.map(deadlineDict)
        d["dokumente"] = store.docs.filter { $0.moduleID == m.id }.map { ["id": $0.id.uuidString, "art": $0.kind.label, "titel": $0.title] }
        d["quizze"] = store.quizzes.filter { $0.moduleID == m.id }.map { q -> [String: Any] in
            ["id": q.id.uuidString, "titel": q.title, "fragen": q.questions.count, "bestes_ergebnis_prozent": q.bestScore.map { Int($0 * 100) } ?? NSNull()]
        }
        let cards = store.flashcards.filter { $0.moduleID == m.id }
        d["karteikarten"] = ["gesamt": cards.count, "faellig": cards.filter { $0.due <= Date() }.count, "gefestigt": cards.filter(\.isMature).count]
        d["fortschritt_details"] = [
            "themen_sicherheit_prozent": p.topicConfidence.map { Int($0 * 100) } ?? NSNull(),
            "materialien_bearbeitet": "\(p.materialsStudied)/\(p.materialsTotal)",
            "quiz_schnitt_prozent": p.quizAverage.map { Int($0 * 100) } ?? NSNull(),
            "lernzeit_gesamt_h": Double(p.minutesTotal) / 60,
            "lernzeit_soll_bis_klausur_h": Double(p.targetMinutesTotal) / 60,
            "erwartet_prozent": Int(p.expected * 100)
        ] as [String: Any]
        return d
    }

    private func materialDict(_ m: Material) -> [String: Any] {
        var d: [String: Any] = ["id": m.id.uuidString, "titel": m.title, "art": m.kind.label, "zeichen": m.charCount, "bearbeitet": m.studied]
        if let p = m.pageCount { d["seiten"] = p }
        if let n = m.lectureNumber { d["nummer"] = n }
        switch m.status {
        case .extracting: d["status"] = "wird gelesen"
        case .empty: d["status"] = "kein Text erkannt"
        case .failed: d["status"] = "fehlerhaft"
        case .ready: break
        }
        return d
    }

    private func deadlineDict(_ d: Deadline) -> [String: Any] {
        var o: [String: Any] = ["id": d.id.uuidString, "titel": d.title, "art": d.kind.label, "datum": Fmt.ai(d.date, allDay: d.allDay),
                                "in": Fmt.relative(d.date), "erledigt": d.done, "vorbereitung_h": d.effectivePrepHours]
        if let m = store.module(d.moduleID) { o["modul"] = m.name; o["modul_id"] = m.id.uuidString }
        if !d.location.isEmpty { o["ort"] = d.location }
        if d.durationMinutes > 0 { o["dauer_min"] = d.durationMinutes }
        if !d.notes.isEmpty { o["notizen"] = d.notes }
        return o
    }

    private func eventDict(_ e: CalEvent) -> [String: Any] {
        var o: [String: Any] = ["id": e.id, "titel": e.title, "start": Fmt.ai(e.start, allDay: e.isAllDay), "ende": Fmt.ai(e.end, allDay: e.isAllDay),
                                "kalender": e.calendarTitle, "bearbeitbar": e.editable]
        if e.isAllDay { o["ganztaegig"] = true }
        if !e.location.isEmpty { o["ort"] = e.location }
        if let l = e.link {
            let types: [KompassLink.Kind: String] = [.block: "Lernblock", .deadline: "Frist", .session: "Veranstaltung", .event: "Termin", .module: "Modul"]
            o["kompass"] = types[l.kind] ?? "Termin"
            if let m = store.module(l.moduleID) { o["modul"] = m.name }
        }
        if e.calendarID == store.prefs.workCalendarID { o["arbeit"] = true }
        return o
    }

    private func taskDict(_ t: TaskItem) -> [String: Any] {
        var o: [String: Any] = ["id": t.id.uuidString, "titel": t.title, "erledigt": t.done, "schaetzung_min": t.estimateMinutes]
        if let d = t.due { o["faellig"] = Fmt.ai(d) }
        if let m = store.module(t.moduleID) { o["modul"] = m.name }
        return o
    }

    private func weekStart(offset: Int) -> Date { Date().startOfWeek.adding(weeks: offset) }

    // MARK: Überblick

    private func overview() -> ToolOutcome {
        let now = Date()
        let today = cal.allEvents(from: now.startOfDay, to: now.endOfDay.adding(days: 1)).map(eventDict)
        let deadlines = store.upcomingDeadlines.filter { $0.date <= now.adding(days: 30) }.map(deadlineDict)
        let tasks = store.tasks.filter { !$0.done }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }.prefix(20).map(taskDict)
        let report = WeekReport.make(weekStart: now.startOfWeek, store: store, calendar: cal, includeFree: true)
        var week: [String: Any] = [
            "gelernt_h": Double(report.totalLogged) / 60, "ziel_h": Double(report.totalGoal) / 60,
            "arbeit_h": Double(report.workMinutes) / 60, "freie_lernzeit_rest_h": Double(report.freeMinutes) / 60
        ]
        let ws = now.startOfWeek
        week["erfasst_studium_h"] = Double(store.loggedMinutes(from: ws, to: now) { $0.kind == .module }) / 60
        week["erfasst_arbeit_h"] = Double(store.loggedMinutes(from: ws, to: now) { $0.kind == .work }) / 60
        let unconfirmed = app.pendingConfirmations().count
        let open = app.blocksAwaitingCheckIn.count
        var o: [String: Any] = [
            "jetzt": Fmt.ai(now), "semester": store.currentTerm?.name ?? "–",
            "module": store.activeModules.map { moduleDict($0) },
            "termine_heute_und_morgen": today, "fristen_naechste_30_tage": deadlines,
            "offene_aufgaben": Array(tasks), "woche": week
        ]
        if open > 0 { o["unbestaetigte_lernbloecke"] = open }
        if unconfirmed > 0 { o["unbestaetigte_termine"] = unconfirmed }
        return ok(o, "Überblick geladen")
    }

    private func listModules(_ a: ToolArgs) -> ToolOutcome {
        let list = (a.bool("include_archived") ?? false) ? store.modules : store.activeModules
        return ok(["module": list.map { moduleDict($0) }], "\(list.count) Module gelesen")
    }

    private func getModule(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden. Nutze list_modules für die IDs.") }
        return ok(moduleDict(m, detailed: true), "Modul „\(m.name)“ gelesen")
    }

    private func createModule(_ a: ToolArgs) -> ToolOutcome {
        guard let name = a.str("name") else { return fail("Name fehlt.") }
        if let existing = store.modules.first(where: { $0.name.lowercased() == name.lowercased() && !$0.archived }) {
            return ok(["hinweis": "Modul existiert bereits", "id": existing.id.uuidString], "Modul „\(name)“ existiert bereits")
        }
        var m = Module(name: name)
        m.code = a.str("code") ?? ""
        m.ects = a.double("ects") ?? 5
        m.color = ModuleColor.from(a.str("color")) ?? ModuleColor.allCases[store.modules.count % ModuleColor.allCases.count]
        m.weeklyGoalHours = a.double("weekly_goal_hours") ?? Module.suggestedWeeklyHours(ects: m.ects)
        m.lecturer = a.str("lecturer") ?? ""
        m.notes = a.str("notes") ?? ""
        m.termID = store.currentTerm?.id
        store.modules.append(m)
        return ok(["id": m.id.uuidString, "name": m.name], "Modul „\(m.name)“ angelegt",
                  attachment: ChatAttachment(kind: .module, id: m.id.uuidString, label: m.name))
    }

    private func updateModule(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        store.updateModule(m.id) { m in
            if let v = a.str("name") { m.name = v }
            if let v = a.str("code") { m.code = v }
            if let v = a.double("ects") { m.ects = v }
            if let v = ModuleColor.from(a.str("color")) { m.color = v }
            if let v = a.double("weekly_goal_hours") { m.weeklyGoalHours = v }
            if let v = a.str("lecturer") { m.lecturer = v }
            if let v = a.str("notes") { m.notes = v }
            if let v = a.bool("archived") { m.archived = v }
        }
        return ok(["status": "aktualisiert"], "Modul „\(m.name)“ aktualisiert")
    }

    private func deleteModule(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        for s in m.sessions { app.sync.removeSession(s) }
        for b in store.blocks where b.moduleID == m.id && b.status == .planned { app.sync.removeBlock(b) }
        store.deleteModule(m.id)
        if app.selection == .module(m.id) { app.selection = .today }
        return ok(["status": "gelöscht"], "Modul „\(m.name)“ gelöscht")
    }

    private func addSession(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        guard let wd = a.int("weekday"), (1...7).contains(wd), let s = Fmt.parseHM(a.str("start")), let e = Fmt.parseHM(a.str("end")), e > s else {
            return fail("Wochentag (1–7), Beginn und Ende (HH:MM) werden benötigt.")
        }
        let session = CourseSession(kind: SessionKind.parse(a.str("kind")), weekday: wd, startMinutes: s, endMinutes: e,
                                    room: a.str("room") ?? "", biweekly: a.bool("biweekly") ?? false)
        app.addSession(session, to: m.id)
        let inCal = store.module(m.id)?.sessions.first { $0.id == session.id }?.eventIdentifier != nil
        return ok(["id": session.id.uuidString, "im_kalender": inCal],
                  "\(session.kind.label) \(Fmt.weekday(wd, short: true)) \(Fmt.hm(s))–\(Fmt.hm(e)) für \(m.name) eingetragen")
    }

    private func removeSession(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a), let sid = a.str("session_id").flatMap(UUID.init(uuidString:)) else { return fail("Modul oder Veranstaltung nicht gefunden.") }
        app.removeSession(sid, from: m.id)
        return ok(["status": "entfernt"], "Veranstaltung aus \(m.name) entfernt")
    }

    private func addTopics(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        let titles = a.strings("topics")
        guard !titles.isEmpty else { return fail("Keine Themen angegeben.") }
        let covered = a.bool("covered") ?? false
        let existing = Set(m.topics.map { $0.title.lowercased() })
        let new = titles.filter { !existing.contains($0.lowercased()) }.map { Topic(title: $0, covered: covered) }
        store.updateModule(m.id) { $0.topics.append(contentsOf: new) }
        return ok(["hinzugefuegt": new.map { ["id": $0.id.uuidString, "titel": $0.title] }], "\(new.count) Themen zu \(m.name) hinzugefügt")
    }

    private func updateTopic(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a), let ref = a.str("topic") else { return fail("Modul oder Thema fehlt.") }
        let l = ref.lowercased()
        guard let t = m.topics.first(where: { $0.id.uuidString == ref }) ?? m.topics.first(where: { $0.title.lowercased() == l })
                ?? m.topics.first(where: { $0.title.lowercased().contains(l) }) else { return fail("Thema „\(ref)“ nicht gefunden.") }
        store.updateModule(m.id) { m in
            guard let i = m.topics.firstIndex(where: { $0.id == t.id }) else { return }
            if let c = a.double("confidence") { m.topics[i].confidence = min(1, max(0, c > 1 ? c / 100 : c)); m.topics[i].lastReviewed = Date() }
            if let c = a.bool("covered") { m.topics[i].covered = c }
            if let n = a.str("title") { m.topics[i].title = n }
        }
        return ok(["status": "aktualisiert"], "Thema „\(t.title)“ aktualisiert")
    }

    // MARK: Kalender

    private func listEvents(_ a: ToolArgs) -> ToolOutcome {
        guard cal.eventsAuthorized else { return fail(CalendarError.noAccess.localizedDescription) }
        let start = a.date("start") ?? Date().startOfDay
        var end = a.date("end") ?? start.adding(days: 7)
        if Fmt.isDateOnly(a.str("end")) { end = end.endOfDay }
        let evs = cal.allEvents(from: start, to: end)
        let limited = evs.prefix(150).map(eventDict)
        return ok(["termine": Array(limited), "anzahl": evs.count], "\(evs.count) Termine gelesen")
    }

    private func freeTime(_ a: ToolArgs) -> ToolOutcome {
        let start = max(a.date("start") ?? Date(), Date())
        var end = a.date("end") ?? start.adding(days: 7)
        if Fmt.isDateOnly(a.str("end")) { end = end.endOfDay }
        let minLen = Double(a.int("min_minutes") ?? 45) * 60
        let slots = Planner(store: store, calendar: cal).freeSlots(from: start, to: end).filter { $0.duration >= minLen }
        let list = slots.prefix(60).map { ["start": Fmt.ai($0.start), "ende": Fmt.ai($0.end), "minuten": Int($0.duration / 60)] as [String: Any] }
        let p = store.prefs
        return ok(["freie_zeiten": Array(list), "lernfenster": "\(Fmt.hm(p.studyDayStart))–\(Fmt.hm(p.studyDayEnd))", "puffer_min": p.bufferMinutes],
                  "\(slots.count) freie Zeitfenster gefunden")
    }

    private func createEvent(_ a: ToolArgs) -> ToolOutcome {
        guard cal.eventsAuthorized else { return fail(CalendarError.noAccess.localizedDescription) }
        guard let title = a.str("title"), let start = a.date("start") else { return fail("Titel und Start werden benötigt.") }
        let allDay = a.bool("all_day") ?? Fmt.isDateOnly(a.str("start"))
        let end = a.date("end") ?? start.adding(minutes: 60)
        let module = requireModule(a)
        var draft = CalendarService.EventDraft(title: title, start: start, end: end)
        draft.allDay = allDay
        draft.location = a.str("location") ?? ""
        draft.notes = a.str("notes") ?? ""
        if let name = a.str("calendar") {
            guard let c = cal.editableCalendars.first(where: { $0.title.lowercased() == name.lowercased() }) else {
                return fail("Kalender „\(name)“ nicht gefunden oder schreibgeschützt. Verfügbar: \(cal.editableCalendars.map(\.title).joined(separator: ", "))")
            }
            draft.calendarID = c.calendarIdentifier
        }
        if let alarm = a.int("alarm_minutes_before") { draft.alarmMinutes = [alarm] }
        let isBlock = (a.bool("study_block") ?? false) && module != nil
        let blockID = UUID()
        if isBlock, let module { draft.link = KompassLink(kind: .block, id: blockID, moduleID: module.id) }
        else if let module { draft.link = KompassLink(kind: .event, moduleID: module.id) }
        do {
            let e = try cal.create(draft)
            if isBlock, let module {
                store.blocks.append(PlannedBlock(id: blockID, moduleID: module.id, start: start, end: end, eventIdentifier: e.eventIdentifier))
            }
            return ok(["status": "erstellt", "kalender": e.calendar?.title ?? ""], "Termin „\(title)“ am \(Fmt.dateTime(start, allDay: allDay)) erstellt")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func updateEvent(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("event_id"), let e = cal.ekEvent(id: id) else { return fail(CalendarError.notFound.localizedDescription) }
        let oldStart = e.startDate ?? Date(), oldEnd = e.endDate ?? Date()
        if let t = a.str("title") { e.title = t }
        if let s = a.date("start") {
            e.startDate = s
            e.endDate = a.date("end") ?? s.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))
        } else if let en = a.date("end") { e.endDate = en }
        if let l = a.str("location") { e.location = l }
        if let n = a.str("notes") { e.notes = n }
        do {
            try cal.save(e)
            app.sync.reconcile()
            return ok(["status": "geändert", "start": Fmt.ai(e.startDate), "ende": Fmt.ai(e.endDate)], "„\(e.title ?? "")“ → \(Fmt.dateTime(e.startDate))")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private func deleteEvent(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("event_id"), let e = cal.ekEvent(id: id) else { return fail(CalendarError.notFound.localizedDescription) }
        let title = e.title ?? ""
        do {
            try cal.deleteEvent(e)
            app.sync.reconcile()
            return ok(["status": "gelöscht"], "Termin „\(title)“ gelöscht")
        } catch {
            return fail(error.localizedDescription)
        }
    }

    // MARK: Fristen & Aufgaben

    private func createDeadline(_ a: ToolArgs) -> ToolOutcome {
        guard let title = a.str("title"), let date = a.date("date") else { return fail("Titel und Datum werden benötigt.") }
        let kind = DeadlineKind.parse(a.str("kind"))
        var d = Deadline(title: title, kind: kind, moduleID: requireModule(a)?.id, date: date)
        d.allDay = a.bool("all_day") ?? Fmt.isDateOnly(a.str("date"))
        if d.allDay { d.date = date.startOfDay }
        d.durationMinutes = a.int("duration_minutes") ?? (kind == .klausur ? 90 : 0)
        d.location = a.str("location") ?? ""
        d.notes = a.str("notes") ?? ""
        d.prepHours = a.double("prep_hours")
        if let days = a.raw["remind_days_before"] as? [Any] {
            d.reminderOffsets = days.compactMap { ($0 as? NSNumber)?.doubleValue }.map { Int($0 * 24 * 60) }.sorted(by: >)
        }
        app.saveDeadline(d)
        let mod = store.module(d.moduleID).map { " (\($0.name))" } ?? ""
        return ok(["id": d.id.uuidString, "status": "angelegt"], "\(kind.label) „\(title)“\(mod) am \(Fmt.dateTime(d.date, allDay: d.allDay))",
                  attachment: ChatAttachment(kind: .deadline, id: d.id.uuidString, label: title))
    }

    private func listDeadlines(_ a: ToolArgs) -> ToolOutcome {
        var list = store.deadlines.sorted { $0.date < $1.date }
        if !(a.bool("include_done") ?? false) { list = list.filter { !$0.done } }
        if let m = store.findModule(a.str("module")) { list = list.filter { $0.moduleID == m.id } }
        return ok(["fristen": list.map(deadlineDict)], "\(list.count) Fristen gelesen")
    }

    private func updateDeadline(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("deadline_id").flatMap(UUID.init(uuidString:)), var d = store.deadline(id) else { return fail("Frist nicht gefunden.") }
        if let t = a.str("title") { d.title = t }
        if let dt = a.date("date") { d.date = dt; if Fmt.isDateOnly(a.str("date")) { d.allDay = true } }
        if let done = a.bool("done") { d.done = done; d.doneAt = done ? Date() : nil }
        if let l = a.str("location") { d.location = l }
        if let n = a.str("notes") { d.notes = n }
        if let p = a.double("prep_hours") { d.prepHours = p }
        app.saveDeadline(d)
        return ok(["status": "aktualisiert"], d.done ? "„\(d.title)“ erledigt" : "„\(d.title)“ aktualisiert")
    }

    private func deleteDeadline(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("deadline_id").flatMap(UUID.init(uuidString:)), let d = store.deadline(id) else { return fail("Frist nicht gefunden.") }
        app.deleteDeadline(id)
        return ok(["status": "gelöscht"], "„\(d.title)“ gelöscht")
    }

    private func createTask(_ a: ToolArgs) -> ToolOutcome {
        guard let title = a.str("title") else { return fail("Titel fehlt.") }
        var t = TaskItem(title: title, moduleID: requireModule(a)?.id, due: a.date("due"))
        t.estimateMinutes = a.int("estimate_minutes") ?? 30
        t.notes = a.str("notes") ?? ""
        store.tasks.append(t)
        return ok(["id": t.id.uuidString], "Aufgabe „\(title)“ angelegt")
    }

    private func listTasks(_ a: ToolArgs) -> ToolOutcome {
        var list = store.tasks
        if !(a.bool("include_done") ?? false) { list = list.filter { !$0.done } }
        return ok(["aufgaben": list.map(taskDict)], "\(list.count) Aufgaben gelesen")
    }

    private func updateTask(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("task_id").flatMap(UUID.init(uuidString:)), let t = store.tasks.first(where: { $0.id == id }) else { return fail("Aufgabe nicht gefunden.") }
        store.updateTask(id) { t in
            if let d = a.bool("done") { t.done = d; t.doneAt = d ? Date() : nil }
            if let v = a.str("title") { t.title = v }
            if let v = a.date("due") { t.due = v }
            if let v = a.int("estimate_minutes") { t.estimateMinutes = v }
        }
        return ok(["status": "aktualisiert"], (a.bool("done") ?? false) ? "„\(t.title)“ abgehakt" : "„\(t.title)“ aktualisiert")
    }

    // MARK: Materialien & Lernen

    private func listMaterials(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        return ok(["modul": m.name, "materialien": m.materials.map(materialDict)], "\(m.materials.count) Materialien in \(m.name)")
    }

    private func searchMaterials(_ a: ToolArgs) -> ToolOutcome {
        guard let q = a.str("query") else { return fail("Suchbegriff fehlt.") }
        let mods = store.findModule(a.str("module")).map { [$0] } ?? store.activeModules
        var chunks: [TextSearch.Chunk] = []
        var titles: [UUID: (String, String)] = [:]
        for m in mods {
            for mat in m.materials where mat.status == .ready {
                titles[mat.id] = (mat.title, m.name)
                chunks += TextSearch.chunks(materialID: mat.id, text: store.text(of: mat.id))
            }
        }
        guard !chunks.isEmpty else { return fail("In den Materialien ist noch kein lesbarer Text vorhanden. Der Nutzer sollte Materialien hochladen.") }
        let hits = TextSearch.search(q, in: chunks, limit: min(12, a.int("limit") ?? 6))
        let list = hits.map { h -> [String: Any] in
            let t = titles[h.chunk.materialID]
            return ["material_id": h.chunk.materialID.uuidString, "material": t?.0 ?? "", "modul": t?.1 ?? "",
                    "stelle": h.chunk.location, "text": String(h.chunk.text.prefix(1800))]
        }
        return ok(["treffer": list], "\(hits.count) Stellen zu „\(q)“ gefunden")
    }

    private func readMaterial(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("material_id").flatMap(UUID.init(uuidString:)), let (m, mat) = store.material(id) else { return fail("Material nicht gefunden.") }
        let text = store.text(of: id)
        guard !text.isEmpty else { return fail("Aus „\(mat.title)“ konnte kein Text gelesen werden.") }
        let offset = max(0, min(text.count, a.int("offset") ?? 0))
        let len = min(20000, max(1000, a.int("max_chars") ?? 12000))
        let start = text.index(text.startIndex, offsetBy: offset)
        let end = text.index(start, offsetBy: min(len, text.distance(from: start, to: text.endIndex)))
        let part = String(text[start..<end])
        let next = text.distance(from: text.startIndex, to: end)
        var o: [String: Any] = ["material": mat.title, "modul": m.name, "art": mat.kind.label, "gesamt_zeichen": text.count, "offset": offset, "text": part]
        if next < text.count { o["weiter_mit_offset"] = next }
        return ok(o, "„\(mat.title)“ gelesen")
    }

    private func setStudied(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("material_id").flatMap(UUID.init(uuidString:)), let (_, mat) = store.material(id) else { return fail("Material nicht gefunden.") }
        let v = a.bool("studied") ?? true
        store.updateMaterial(id) { $0.studied = v }
        return ok(["status": "ok"], "„\(mat.title)“ \(v ? "als bearbeitet markiert" : "zurückgesetzt")")
    }

    private func saveDocument(_ a: ToolArgs) -> ToolOutcome {
        guard let title = a.str("title"), let md = a.str("markdown") else { return fail("Titel und Inhalt fehlen.") }
        let doc = StudyDoc(moduleID: requireModule(a)?.id, kind: DocKind.parse(a.str("kind")), title: title, markdown: md)
        store.docs.append(doc)
        return ok(["id": doc.id.uuidString, "status": "gespeichert"], "\(doc.kind.label) „\(title)“ gespeichert",
                  attachment: ChatAttachment(kind: .doc, id: doc.id.uuidString, label: title))
    }

    private func createFlashcards(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        let cards = a.objects("cards").compactMap { o -> Flashcard? in
            guard let f = (o["front"] as? String)?.trimmed.nilIfEmpty, let b = (o["back"] as? String)?.trimmed.nilIfEmpty else { return nil }
            return Flashcard(moduleID: m.id, topic: (o["topic"] as? String) ?? "", front: f, back: b)
        }
        guard !cards.isEmpty else { return fail("Keine gültigen Karten übergeben.") }
        store.flashcards.append(contentsOf: cards)
        return ok(["anzahl": cards.count], "\(cards.count) Karteikarten für \(m.name) erstellt",
                  attachment: ChatAttachment(kind: .cards, id: m.id.uuidString, label: m.name))
    }

    private func createQuiz(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        let qs = StudyGenerator.parseQuestions(a.objects("questions"))
        guard !qs.isEmpty else { return fail("Keine gültigen Fragen übergeben.") }
        let quiz = Quiz(moduleID: m.id, title: a.str("title") ?? "Quiz", questions: qs)
        store.quizzes.append(quiz)
        return ok(["id": quiz.id.uuidString, "fragen": qs.count], "Quiz „\(quiz.title)“ mit \(qs.count) Fragen erstellt",
                  attachment: ChatAttachment(kind: .quiz, id: quiz.id.uuidString, label: quiz.title))
    }

    private func recordResult(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a), let total = a.int("total"), total > 0 else { return fail("Modul und Anzahl Fragen werden benötigt.") }
        let correct = max(0, min(total, a.int("correct") ?? 0))
        let score = Double(correct) / Double(total)
        if let topic = a.str("topic") { store.applyResult(moduleID: m.id, topicName: topic, score: score) }
        // Als Quiz-Versuch speichern, damit es in den Fortschritt einfließt
        let title = "Abfrage im Chat" + (a.str("topic").map { ": \($0)" } ?? "")
        var quiz = store.quizzes.first { $0.moduleID == m.id && $0.title == title } ?? Quiz(moduleID: m.id, title: title, questions: [])
        quiz.attempts.append(QuizAttempt(score: score, answered: total))
        if let i = store.quizzes.firstIndex(where: { $0.id == quiz.id }) { store.quizzes[i] = quiz } else { store.quizzes.append(quiz) }
        return ok(["status": "gespeichert", "ergebnis_prozent": Int(score * 100)], "Ergebnis \(correct)/\(total) für \(m.name) gespeichert")
    }

    // MARK: Zeiterfassung

    private func target(_ a: ToolArgs, key: String = "category") -> TrackTarget? {
        store.findTarget(a.str(key) ?? a.str("module")) ?? (a.str(key) == nil && a.str("module") == nil ? app.assistant.scopeModuleID.map { TrackTarget.module($0) } : nil)
    }

    private func worklogDict(_ w: Worklog) -> [String: Any] {
        var o: [String: Any] = ["id": w.id.uuidString, "kategorie": store.label(for: TrackTarget(w)).name, "art": w.activity.label,
                                "start": Fmt.ai(w.start), "ende": Fmt.ai(w.end), "dauer": Fmt.jira(w.minutes), "minuten": w.minutes,
                                "quelle": w.source.label]
        if !w.note.isEmpty { o["beschreibung"] = w.note }
        if !w.title.isEmpty { o["titel"] = w.title }
        if let t = w.taskID.flatMap({ id in store.tasks.first { $0.id == id } }) { o["aufgabe"] = t.title }
        if let d = w.deadlineID.flatMap({ store.deadline($0) }) { o["frist"] = d.title }
        return o
    }

    private func logTime(_ a: ToolArgs) -> ToolOutcome {
        guard let t = target(a) else { return fail("Kategorie nicht gefunden. Möglich: Modulnamen, „Arbeit“ oder: \(store.timeCategories.map(\.name).joined(separator: ", "))") }
        let mins = a.str("duration").flatMap(Fmt.parseDuration) ?? a.int("minutes")
        guard let mins, mins > 0 else { return fail("Dauer fehlt (z. B. „1h 30m“).") }
        let start = a.date("start") ?? a.date("date") ?? Date().adding(minutes: -mins)
        let activity = ActivityKind.parse(a.str("activity")) ?? ActivityKind.defaultFor(t.kind)
        guard let w = store.logWork(t, activity: activity, start: start, minutes: mins, source: .ai, note: a.str("note") ?? "",
                                    taskID: a.str("task_id").flatMap(UUID.init(uuidString:)),
                                    deadlineID: a.str("deadline_id").flatMap(UUID.init(uuidString:))) else { return fail("Buchung fehlgeschlagen.") }
        return ok(["id": w.id.uuidString, "status": "gebucht"], "\(Fmt.jira(mins)) auf \(store.label(for: t).name) gebucht")
    }

    private func filteredLogs(_ a: ToolArgs) -> (logs: [Worklog], start: Date, end: Date)? {
        guard let start = a.date("start") else { return nil }
        var end = a.date("end") ?? Date()
        if Fmt.isDateOnly(a.str("end")) { end = end.endOfDay }
        var logs = store.worklogs.filter { $0.start >= start && $0.start < end }
        if let c = a.str("category") {
            let l = c.lowercased()
            if ["studium", "uni", "lernen"].contains(l) { logs = logs.filter { $0.kind == .module } }
            else if let t = store.findTarget(c) { logs = logs.filter { TrackTarget($0).key == t.key } }
        }
        switch a.str("activity_filter") ?? "all" {
        case "self_study": logs = logs.filter { $0.kind == .module && $0.activity.isSelfStudy }
        case "courses": logs = logs.filter { $0.activity.isCourse || $0.activity == .pruefung }
        case "work": logs = logs.filter { $0.kind == .work }
        case "other": logs = logs.filter { $0.kind == .custom }
        default: break
        }
        return (logs, start, end)
    }

    private func timeReport(_ a: ToolArgs) -> ToolOutcome {
        guard let (logs, start, end) = filteredLogs(a) else { return fail("Start wird benötigt.") }
        let group = a.str("group_by") ?? "category"
        var buckets: [String: Int] = [:]
        for w in logs {
            let key: String
            switch group {
            case "activity": key = w.activity.label
            case "day": key = Fmt.machineDay.string(from: w.start)
            case "week": key = "KW \(w.start.weekNumber) (\(Fmt.machineDay.string(from: w.start.startOfWeek)))"
            default: key = store.label(for: TrackTarget(w)).name
            }
            buckets[key, default: 0] += w.minutes
        }
        let total = logs.reduce(0) { $0 + $1.minutes }
        let list = buckets.sorted { group == "day" || group == "week" ? $0.key < $1.key : $0.value > $1.value }
            .map { ["name": $0.key, "dauer": Fmt.jira($0.value), "stunden": hoursNumber($0.value)] as [String: Any] }
        let study = logs.filter { $0.kind == .module }
        let o: [String: Any] = [
            "zeitraum": "\(Fmt.ai(start)) – \(Fmt.ai(end))", "gesamt": Fmt.jira(total), "gesamt_stunden": hoursNumber(total),
            "studium": Fmt.jira(study.reduce(0) { $0 + $1.minutes }),
            "davon_selbststudium": Fmt.jira(study.filter { $0.activity.isSelfStudy }.reduce(0) { $0 + $1.minutes }),
            "arbeit": Fmt.jira(logs.filter { $0.kind == .work }.reduce(0) { $0 + $1.minutes }),
            "andere": Fmt.jira(logs.filter { $0.kind == .custom }.reduce(0) { $0 + $1.minutes }),
            "aufschluesselung": list, "buchungen": logs.count
        ]
        return ok(o, "Auswertung: \(Fmt.jira(total)) im Zeitraum")
    }

    private func hoursNumber(_ minutes: Int) -> NSDecimalNumber {
        NSDecimalNumber(string: String(format: "%.1f", Double(minutes) / 60), locale: Locale(identifier: "en_US_POSIX"))
    }

    private func listWorklogs(_ a: ToolArgs) -> ToolOutcome {
        guard let (logs, _, _) = filteredLogs(a) else { return fail("Start wird benötigt.") }
        let sorted = logs.sorted { $0.start < $1.start }
        return ok(["buchungen": sorted.prefix(150).map(worklogDict), "anzahl": logs.count], "\(logs.count) Buchungen gelesen")
    }

    private func updateWorklog(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("worklog_id").flatMap(UUID.init(uuidString:)), store.worklogs.contains(where: { $0.id == id }) else { return fail("Buchung nicht gefunden.") }
        let t = a.str("category").flatMap { store.findTarget($0) }
        store.updateWorklog(id) { w in
            if let d = a.str("duration").flatMap(Fmt.parseDuration) { w.minutes = d }
            if let s = a.date("start") { w.start = s }
            if let t { w.kind = t.kind; w.moduleID = t.moduleID; w.categoryID = t.categoryID }
            if let act = ActivityKind.parse(a.str("activity")) { w.activity = act }
            if let n = a.str("note") { w.note = n }
        }
        return ok(["status": "geändert"], "Zeitbuchung geändert")
    }

    private func deleteWorklog(_ a: ToolArgs) -> ToolOutcome {
        guard let id = a.str("worklog_id").flatMap(UUID.init(uuidString:)) else { return fail("ID fehlt.") }
        store.worklogs.removeAll { $0.id == id }
        return ok(["status": "gelöscht"], "Zeitbuchung gelöscht")
    }

    private func listUnconfirmed(_ a: ToolArgs) -> ToolOutcome {
        let items = app.pendingConfirmations(days: min(31, max(1, a.int("days") ?? 7)))
        let list = items.map { i -> [String: Any] in
            ["key": i.key, "titel": i.title, "start": Fmt.ai(i.start), "ende": Fmt.ai(i.end), "dauer": Fmt.jira(i.minutes),
             "kategorie": store.label(for: i.target).name, "art": i.activity.label]
        }
        return ok(["offen": list], "\(items.count) offene Termine")
    }

    private func confirmAttendance(_ a: ToolArgs) -> ToolOutcome {
        let keys = Set(a.strings("keys"))
        let chosen = (a.bool("all") ?? false) ? app.pendingConfirmations(days: 7) : app.pendingConfirmations(days: 31).filter { keys.contains($0.key) }
        guard !chosen.isEmpty else { return fail("Keine passenden offenen Termine gefunden (list_unconfirmed liefert die Schlüssel).") }
        let attended = a.bool("attended") ?? true
        var minutes = 0
        for i in chosen {
            if attended { if let w = app.confirm(i) { minutes += w.minutes } } else { app.skip(i) }
        }
        return ok(["anzahl": chosen.count, "gebucht": Fmt.jira(minutes)],
                  attended ? "\(chosen.count) Termine bestätigt (\(Fmt.jira(minutes)))" : "\(chosen.count) Termine als nicht wahrgenommen markiert")
    }

    private func createCategory(_ a: ToolArgs) -> ToolOutcome {
        guard let name = a.str("name") else { return fail("Name fehlt.") }
        if let c = store.timeCategories.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return ok(["id": c.id.uuidString, "hinweis": "existiert bereits"], "Kategorie „\(c.name)“ existiert bereits")
        }
        let c = TimeCategory(name: name, color: ModuleColor.from(a.str("color")) ?? .teal)
        store.timeCategories.append(c)
        return ok(["id": c.id.uuidString], "Kategorie „\(name)“ angelegt")
    }

    // MARK: Planung

    private func weekReview(_ a: ToolArgs) -> ToolOutcome {
        let ws = weekStart(offset: a.int("week_offset") ?? 0)
        let r = WeekReport.make(weekStart: ws, store: store, calendar: cal, includeFree: true)
        let lines = r.lines.map { l -> [String: Any] in
            ["modul": l.name, "ziel_h": Double(l.goal) / 60, "gelernt_h": Double(l.logged) / 60,
             "geplante_bloecke": l.blocksPlanned, "erledigte_bloecke": l.blocksDone]
        }
        let next = WeekReport.make(weekStart: ws.adding(weeks: 1), store: store, calendar: cal)
        let o: [String: Any] = [
            "woche": "KW \(ws.weekNumber) (\(Fmt.weekRange(ws)))",
            "module": lines,
            "gesamt_gelernt_h": Double(r.totalLogged) / 60, "gesamt_ziel_h": Double(r.totalGoal) / 60,
            "aufgaben_faellig": r.tasksDue.map(taskDict), "aufgaben_erledigt": r.tasksDone.map(taskDict),
            "fristen_dieser_woche": r.deadlines.map(deadlineDict),
            "arbeit_h": Double(r.workMinutes) / 60, "vorlesungen_h": Double(r.lectureMinutes) / 60,
            "sonstige_termine_h": Double(r.eventMinutes) / 60, "freie_lernzeit_h": Double(r.freeMinutes) / 60,
            "quizze_gemacht": r.quizzesTaken,
            "naechste_woche": ["fristen": next.deadlines.map(deadlineDict), "arbeit_h": Double(next.workMinutes) / 60,
                               "vorlesungen_h": Double(next.lectureMinutes) / 60]
        ]
        return ok(o, "Wochenbilanz KW \(ws.weekNumber) erstellt")
    }

    private func planBlocks(_ a: ToolArgs) -> ToolOutcome {
        let ws = weekStart(offset: a.int("week_offset") ?? 0)
        let planner = Planner(store: store, calendar: cal)
        let proposal = planner.propose(weekStart: ws)
        let list = proposal.map { b -> [String: Any] in
            ["modul": store.module(b.moduleID)?.name ?? "", "start": Fmt.ai(b.start), "ende": Fmt.ai(b.end), "fokus": b.focus]
        }
        let demands = planner.demands(weekStart: ws).map { ["modul": store.module($0.id)?.name ?? "", "bedarf_min": $0.minutes, "grund": $0.reason] as [String: Any] }
        if proposal.isEmpty {
            return ok(["bloecke": [], "bedarf": demands, "hinweis": "Kein zusätzlicher Bedarf oder keine freien Zeiten gefunden."], "Keine zusätzlichen Lernblöcke nötig")
        }
        if a.bool("commit") ?? false {
            let saved = planner.commit(proposal, sync: app.sync)
            return ok(["eingetragen": list, "anzahl": saved.count], "\(saved.count) Lernblöcke in KW \(ws.weekNumber) eingetragen",
                      attachment: ChatAttachment(kind: .view, id: "calendar:\(Fmt.machineDay.string(from: ws))", label: "Kalender KW \(ws.weekNumber)"))
        }
        return ok(["vorschlag": list, "bedarf": demands, "hinweis": "Noch nicht eingetragen. Zum Eintragen erneut mit commit=true aufrufen."],
                  "Vorschlag: \(proposal.count) Lernblöcke in KW \(ws.weekNumber)",
                  attachment: ChatAttachment(kind: .plan, id: Fmt.machineDay.string(from: ws), label: "Vorschlag prüfen"))
    }

    private func clearBlocks(_ a: ToolArgs) -> ToolOutcome {
        let ws = weekStart(offset: a.int("week_offset") ?? 0)
        let mod = store.findModule(a.str("module"))
        let targets = store.blocks.filter { $0.status == .planned && $0.start >= max(ws, Date()) && $0.start < ws.adding(days: 7) && (mod == nil || $0.moduleID == mod?.id) }
        for b in targets { app.sync.removeBlock(b) }
        return ok(["entfernt": targets.count], "\(targets.count) Lernblöcke entfernt")
    }

    private func addWorkBlock(_ a: ToolArgs) -> ToolOutcome {
        guard let wd = a.int("weekday"), (1...7).contains(wd), let s = Fmt.parseHM(a.str("start")), let e = Fmt.parseHM(a.str("end")), e > s else {
            return fail("Wochentag und Zeiten werden benötigt.")
        }
        store.workBlocks.append(WorkBlock(weekday: wd, startMinutes: s, endMinutes: e, label: a.str("label") ?? "Werkstudent"))
        return ok(["status": "angelegt"], "Arbeitszeit \(Fmt.weekday(wd, short: true)) \(Fmt.hm(s))–\(Fmt.hm(e)) eingetragen")
    }

    private func updatePrefs(_ a: ToolArgs) -> ToolOutcome {
        var p = store.prefs
        if let v = Fmt.parseHM(a.str("study_day_start")) { p.studyDayStart = v }
        if let v = Fmt.parseHM(a.str("study_day_end")) { p.studyDayEnd = v }
        if let v = a.int("max_minutes_per_day") { p.maxStudyMinutesPerDay = v }
        if let v = a.int("block_minutes") { p.blockMinutes = max(20, v) }
        if let v = a.int("break_minutes") { p.breakMinutes = v }
        if let v = a.bool("study_on_weekends") { p.studyOnWeekends = v }
        if let v = a.int("weekend_max_minutes") { p.weekendMaxMinutes = v }
        store.prefs = p
        return ok(["lernfenster": "\(Fmt.hm(p.studyDayStart))–\(Fmt.hm(p.studyDayEnd))", "max_pro_tag_min": p.maxStudyMinutesPerDay,
                   "block_min": p.blockMinutes, "wochenende": p.studyOnWeekends], "Lernzeiten angepasst")
    }

    // MARK: Bedienung

    private func openView(_ a: ToolArgs) -> ToolOutcome {
        switch a.str("view") ?? "" {
        case "today": app.selection = .today
        case "calendar":
            app.selection = .calendar
            if let d = a.date("date") { app.calendarDate = d }
        case "week": app.selection = .week
        case "deadlines": app.selection = .deadlines
        case "cards": app.selection = .cards
        case "module":
            guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
            app.openModule(m.id)
        case "quiz":
            guard let id = a.str("id").flatMap(UUID.init(uuidString:)), store.quizzes.contains(where: { $0.id == id }) else { return fail("Quiz nicht gefunden.") }
            app.sheet = .quiz(id)
        case "document":
            guard let id = a.str("id").flatMap(UUID.init(uuidString:)), store.docs.contains(where: { $0.id == id }) else { return fail("Dokument nicht gefunden.") }
            app.sheet = .doc(id)
        default: return fail("Unbekannte Ansicht.")
        }
        return ok(["status": "geöffnet"], "Ansicht geöffnet")
    }

    private func startTimer(_ a: ToolArgs) -> ToolOutcome {
        guard let m = requireModule(a) else { return fail("Modul nicht gefunden.") }
        let min = a.int("minutes") ?? store.prefs.defaultFocusMinutes
        app.timer.start(moduleID: m.id, minutes: min)
        return ok(["status": "läuft"], "Fokus-Timer \(min) min für \(m.name) gestartet")
    }
}
