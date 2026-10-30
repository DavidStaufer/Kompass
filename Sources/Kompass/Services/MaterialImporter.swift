import Foundation

@MainActor
enum MaterialImporter {
    /// Kopiert Dateien (oder ganze Ordner) in die Kompass-Bibliothek des Moduls und extrahiert den Text im Hintergrund.
    @discardableResult
    static func importFiles(_ urls: [URL], moduleID: UUID, kind: MaterialKind? = nil, store: DataStore) -> Int {
        var files: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
                while let f = e?.nextObject() as? URL {
                    if TextExtractor.supportedExtensions.contains(f.pathExtension.lowercased()) { files.append(f) }
                }
            } else {
                files.append(url)
            }
        }
        var added = 0
        for url in files.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let id = UUID()
            let ext = url.pathExtension.lowercased()
            let name = url.deletingPathExtension().lastPathComponent
            var mat = Material(id: id, title: prettify(name), kind: kind ?? MaterialKind.guess(from: url.lastPathComponent),
                               fileName: ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)", originalName: url.lastPathComponent)
            mat.lectureNumber = lectureNumber(in: name)
            let dest = Paths.materialFile(moduleID, mat)
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                continue
            }
            store.updateModule(moduleID) { $0.materials.append(mat) }
            added += 1
            extract(materialID: id, moduleID: moduleID, file: dest, store: store)
        }
        return added
    }

    /// Übernimmt eine heruntergeladene Datei (z. B. aus WueCampus) als Material.
    static func importDownloaded(_ tmp: URL, fileName: String, title: String, kind: MaterialKind, moduleID: UUID,
                                 sourceKey: String, sourceModified: Date, store: DataStore) {
        let id = UUID()
        let ext = (fileName as NSString).pathExtension.lowercased()
        var mat = Material(id: id, title: title, kind: kind, fileName: ext.isEmpty ? id.uuidString : "\(id.uuidString).\(ext)", originalName: fileName)
        mat.lectureNumber = lectureNumber(in: title) ?? lectureNumber(in: (fileName as NSString).deletingPathExtension)
        mat.sourceKey = sourceKey
        mat.sourceModified = sourceModified
        let dest = Paths.materialFile(moduleID, mat)
        do { try FileManager.default.moveItem(at: tmp, to: dest) } catch { try? FileManager.default.copyItem(at: tmp, to: dest) }
        store.updateModule(moduleID) { $0.materials.append(mat) }
        extract(materialID: id, moduleID: moduleID, file: dest, store: store)
    }

    /// Fügt einen Text (z. B. eingefügte Notizen) als Material hinzu.
    static func addText(_ text: String, title: String, kind: MaterialKind, moduleID: UUID, store: DataStore) -> Material {
        let id = UUID()
        var mat = Material(id: id, title: title, kind: kind, fileName: "\(id.uuidString).md", originalName: "\(title).md")
        try? text.write(to: Paths.materialFile(moduleID, mat), atomically: true, encoding: .utf8)
        mat.status = text.trimmed.isEmpty ? .empty : .ready
        mat.charCount = text.count
        store.updateModule(moduleID) { $0.materials.append(mat) }
        store.setText(text, for: id, moduleID: moduleID)
        return mat
    }

    static func extract(materialID: UUID, moduleID: UUID, file: URL, store: DataStore) {
        store.updateMaterial(materialID) { $0.status = .extracting }
        Task.detached(priority: .utility) {
            let result = TextExtractor.extract(url: file)
            await MainActor.run {
                store.setText(result.text, for: materialID, moduleID: moduleID)
                store.updateMaterial(materialID) { m in
                    m.charCount = result.text.count
                    m.pageCount = result.pages
                    m.usedOCR = result.usedOCR
                    m.status = result.text.trimmed.isEmpty ? .empty : .ready
                }
            }
        }
    }

    /// Setzt unterbrochene Extraktionen nach einem Neustart fort.
    static func resumePending(store: DataStore) {
        for m in store.modules {
            for mat in m.materials where mat.status == .extracting {
                extract(materialID: mat.id, moduleID: m.id, file: Paths.materialFile(m.id, mat), store: store)
            }
        }
    }

    private static func prettify(_ s: String) -> String {
        s.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "  ", with: " ").trimmed
    }

    private static func lectureNumber(in s: String) -> Int? {
        let l = s.lowercased()
        let patterns = [#"(?:vl|vorlesung|lecture|kapitel|chapter|lec|blatt|sheet|übung|uebung|exercise)[\s_\-]*0*(\d{1,2})"#, #"^0*(\d{1,2})[\s_\-]"#]
        for p in patterns {
            if let r = try? NSRegularExpression(pattern: p), let m = r.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
               let range = Range(m.range(at: 1), in: l) { return Int(l[range]) }
        }
        return nil
    }
}
