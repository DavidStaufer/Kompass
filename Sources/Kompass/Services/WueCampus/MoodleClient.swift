import Foundation

/// Zugriff auf WueCampus (Moodle) über die offizielle Schnittstelle der Moodle-App.
struct MoodleClient {
    static let wueCampus = URL(string: "https://wuecampus.uni-wuerzburg.de/moodle")!

    let site: URL
    let token: String

    struct MoodleError: LocalizedError {
        let code: String
        let message: String
        var errorDescription: String? {
            switch code {
            case "invalidtoken", "accessexception":
                return "Die Anmeldung bei WueCampus ist abgelaufen. Bitte in den Einstellungen neu verbinden."
            default:
                return "WueCampus: \(message)"
            }
        }
        var isAuthError: Bool { code == "invalidtoken" || code == "accessexception" }
    }

    // MARK: Antwort-Modelle

    struct SiteInfo: Decodable {
        let userid: Int
        let fullname: String
        let sitename: String?
        let username: String?
    }

    struct Course: Decodable, Identifiable, Hashable {
        let id: Int
        let fullname: String
        let shortname: String?
        let startdate: Int?
        let enddate: Int?
        let hidden: Bool?

        var displayName: String {
            // Moodle-Namen enthalten oft HTML-Entities
            fullname.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
        }
    }

    struct Section: Decodable {
        let id: Int
        let name: String?
        let modules: [CourseModule]?
    }

    struct CourseModule: Decodable {
        let id: Int
        let name: String?
        let modname: String?
        let url: String?
        let contents: [FileContent]?
    }

    struct FileContent: Decodable {
        let type: String?
        let filename: String?
        let filepath: String?
        let filesize: Int?
        let fileurl: String?
        let timemodified: Int?
        let mimetype: String?
    }

    struct AssignResponse: Decodable {
        struct CourseAssigns: Decodable {
            let id: Int
            let assignments: [Assignment]?
        }
        let courses: [CourseAssigns]?
    }

    struct Assignment: Decodable {
        let id: Int
        let cmid: Int?
        let course: Int?
        let name: String
        let duedate: Int?
        let cutoffdate: Int?
        let timemodified: Int?
        let intro: String?
        /// Anhänge der Aufgabenbeschreibung – hier liegen oft die Übungsblätter
        let introattachments: [FileContent]?
    }

    struct EventsResponse: Decodable { let events: [Event]? }

    struct Event: Decodable {
        let id: Int
        let name: String
        let description: String?
        let courseid: Int?
        let modulename: String?
        let eventtype: String?
        let timestart: Int
        let timeduration: Int?
        let timemodified: Int?
        let location: String?
    }

    // MARK: Aufrufe

    func siteInfo() async throws -> SiteInfo {
        try await call("core_webservice_get_site_info", [:])
    }

    /// Kurse, die gerade laufen (wie „Meine Kurse → Aktuell“ in WueCampus).
    func currentCourses() async throws -> [Course] {
        struct R: Decodable { let courses: [Course] }
        if let r: R = try? await call("core_course_get_enrolled_courses_by_timeline_classification",
                                      ["classification": "inprogress", "limit": "0", "offset": "0", "sort": "fullname"]) {
            return r.courses
        }
        // Fallback: alle eingeschriebenen Kurse
        let info = try await siteInfo()
        return try await call("core_enrol_get_users_courses", ["userid": String(info.userid)])
    }

    func allCourses() async throws -> [Course] {
        let info = try await siteInfo()
        return try await call("core_enrol_get_users_courses", ["userid": String(info.userid)])
    }

    func contents(courseID: Int) async throws -> [Section] {
        try await call("core_course_get_contents", ["courseid": String(courseID)])
    }

    func assignments(courseIDs: [Int]) async throws -> [Assignment] {
        var p: [String: String] = [:]
        for (i, c) in courseIDs.enumerated() { p["courseids[\(i)]"] = String(c) }
        let r: AssignResponse = try await call("mod_assign_get_assignments", p)
        return (r.courses ?? []).flatMap { c in (c.assignments ?? []).map { a in
            Assignment(id: a.id, cmid: a.cmid, course: a.course ?? c.id, name: a.name, duedate: a.duedate,
                       cutoffdate: a.cutoffdate, timemodified: a.timemodified, intro: a.intro, introattachments: a.introattachments)
        } }
    }

    func events(courseIDs: [Int], from: Date, to: Date) async throws -> [Event] {
        var p: [String: String] = [
            "options[userevents]": "1", "options[siteevents]": "0",
            "options[timestart]": String(Int(from.timeIntervalSince1970)),
            "options[timeend]": String(Int(to.timeIntervalSince1970)),
            "options[ignorehidden]": "1"
        ]
        for (i, c) in courseIDs.enumerated() { p["events[courseids][\(i)]"] = String(c) }
        let r: EventsResponse = try await call("core_calendar_get_calendar_events", p)
        return r.events ?? []
    }

    /// Lädt eine Datei (fileurl aus core_course_get_contents) in eine temporäre Datei.
    func download(_ fileURL: String) async throws -> URL {
        guard var comps = URLComponents(string: fileURL) else { throw MoodleError(code: "url", message: "Ungültige Datei-Adresse") }
        var items = comps.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        comps.queryItems = items
        guard let url = comps.url else { throw MoodleError(code: "url", message: "Ungültige Datei-Adresse") }
        var req = URLRequest(url: url)
        req.timeoutInterval = 300
        let (tmp, response) = try await URLSession.shared.download(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MoodleError(code: "http\(http.statusCode)", message: "Download fehlgeschlagen (\(http.statusCode))")
        }
        // Moodle liefert bei Fehlern JSON statt der Datei
        if let head = try? FileHandle(forReadingFrom: tmp).read(upToCount: 200),
           let text = String(data: head, encoding: .utf8), text.hasPrefix("{\"error\"") || text.hasPrefix("{\"exception\"") {
            throw MoodleError(code: "download", message: "Datei konnte nicht geladen werden")
        }
        return tmp
    }

    // MARK: REST

    private func call<T: Decodable>(_ function: String, _ params: [String: String]) async throws -> T {
        var req = URLRequest(url: site.appendingPathComponent("webservice/rest/server.php"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var all = params
        all["wstoken"] = token
        all["wsfunction"] = function
        all["moodlewsrestformat"] = "json"
        req.httpBody = all.map { "\(Self.encode($0.key))=\(Self.encode($0.value))" }.joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw MoodleError(code: "http\(http.statusCode)", message: "Server antwortet mit \(http.statusCode)")
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["exception"] != nil {
            throw MoodleError(code: obj["errorcode"] as? String ?? "error", message: obj["message"] as? String ?? "Unbekannter Fehler")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func encode(_ s: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/[]")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
