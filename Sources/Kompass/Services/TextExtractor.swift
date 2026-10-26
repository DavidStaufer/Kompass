import Foundation
import PDFKit
import Vision
import Compression
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Holt Text aus hochgeladenen Materialien (PDF, Folien, Word, Bilder, Notebooks …),
/// damit die KI damit arbeiten kann. Gescannte PDFs und Bilder laufen über die
/// Texterkennung von macOS (Vision), komplett lokal.
enum TextExtractor {
    struct Result {
        var text: String
        var pages: Int?
        var usedOCR: Bool
    }

    static let supportedExtensions: Set<String> = [
        "pdf", "txt", "md", "markdown", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm",
        "pptx", "key", "png", "jpg", "jpeg", "heic", "tiff", "gif", "ipynb",
        "py", "java", "c", "cpp", "h", "swift", "js", "ts", "tex", "csv", "json", "m", "r", "sql", "yml", "yaml"
    ]

    static func extract(url: URL) -> Result {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf": return pdf(url)
        case "pptx": return Result(text: pptx(url), pages: nil, usedOCR: false)
        case "docx": return Result(text: docx(url), pages: nil, usedOCR: false)
        case "ipynb": return Result(text: notebook(url), pages: nil, usedOCR: false)
        case "png", "jpg", "jpeg", "heic", "tiff", "gif":
            guard let img = PlatformImage(contentsOfFile: url.path), let cg = Platform.cgImage(img) else {
                return Result(text: "", pages: nil, usedOCR: true)
            }
            return Result(text: ocr(cg), pages: 1, usedOCR: true)
        case "rtf", "rtfd", "doc", "odt", "html", "htm":
            if let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
                return Result(text: a.string, pages: nil, usedOCR: false)
            }
            return Result(text: "", pages: nil, usedOCR: false)
        default:
            if let s = try? String(contentsOf: url, encoding: .utf8) { return Result(text: s, pages: nil, usedOCR: false) }
            if let s = try? String(contentsOf: url, encoding: .isoLatin1) { return Result(text: s, pages: nil, usedOCR: false) }
            return Result(text: "", pages: nil, usedOCR: false)
        }
    }

    // MARK: PDF (mit OCR-Fallback für gescannte Seiten)

    private static func pdf(_ url: URL) -> Result {
        guard let doc = PDFDocument(url: url) else { return Result(text: "", pages: nil, usedOCR: false) }
        var parts: [String] = []
        var usedOCR = false
        let count = doc.pageCount
        for i in 0..<count {
            guard let page = doc.page(at: i) else { continue }
            var t = page.string ?? ""
            if t.trimmed.count < 25, i < 150 {
                // Wahrscheinlich ein Scan → Texterkennung
                let bounds = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2.0
                let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
                let img = page.thumbnail(of: size, for: .mediaBox)
                if let cg = Platform.cgImage(img) {
                    let o = ocr(cg)
                    if !o.trimmed.isEmpty { t = o; usedOCR = true }
                }
            }
            parts.append("[Seite \(i + 1)]\n" + t.trimmed)
        }
        return Result(text: parts.joined(separator: "\n\n"), pages: count, usedOCR: usedOCR)
    }

    static func ocr(_ image: CGImage) -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.recognitionLanguages = ["de-DE", "en-US"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([req]) } catch { return "" }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    // MARK: PowerPoint & Word (ZIP-Container mit XML)

    private static func pptx(_ url: URL) -> String {
        guard let zip = ZipReader(url: url) else { return "" }
        let slides = zip.entries.map(\.name)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }
        var out: [String] = []
        let regex = try? NSRegularExpression(pattern: "<a:t>([^<]*)</a:t>")
        for (i, s) in slides.enumerated() {
            guard let data = zip.data(for: s), let xml = String(data: data, encoding: .utf8), let regex else { continue }
            let ns = xml as NSString
            let texts = regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
            out.append("[Folie \(i + 1)]\n" + decodeXML(texts.joined(separator: " ")))
        }
        return out.joined(separator: "\n\n")
    }

    private static func docx(_ url: URL) -> String {
        guard let zip = ZipReader(url: url), let data = zip.data(for: "word/document.xml"),
              var xml = String(data: data, encoding: .utf8) else {
            // Fallback (z. B. ältere Formate) über das System
            #if os(macOS)
            return (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string ?? ""
            #else
            return ""
            #endif
        }
        xml = xml.replacingOccurrences(of: "</w:p>", with: "\n").replacingOccurrences(of: "<w:tab/>", with: "\t")
            .replacingOccurrences(of: "<w:br/>", with: "\n")
        guard let regex = try? NSRegularExpression(pattern: "<w:t(?: [^>]*)?>([^<]*)</w:t>|(\n)") else { return "" }
        let ns = xml as NSString
        var out = ""
        for m in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            if m.range(at: 1).location != NSNotFound { out += ns.substring(with: m.range(at: 1)) } else { out += "\n" }
        }
        return decodeXML(out)
    }

    private static func slideNumber(_ s: String) -> Int {
        Int(s.replacingOccurrences(of: "ppt/slides/slide", with: "").replacingOccurrences(of: ".xml", with: "")) ?? 0
    }

    private static func decodeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }

    // MARK: Jupyter

    private static func notebook(_ url: URL) -> String {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cells = obj["cells"] as? [[String: Any]] else { return "" }
        return cells.compactMap { cell -> String? in
            let type = cell["cell_type"] as? String ?? "code"
            let src: String
            if let arr = cell["source"] as? [String] { src = arr.joined() } else { src = cell["source"] as? String ?? "" }
            guard !src.trimmed.isEmpty else { return nil }
            return type == "code" ? "```python\n\(src)\n```" : src
        }.joined(separator: "\n\n")
    }
}

/// Einfache Volltextsuche (BM25) über die Materialien – damit die KI die passenden
/// Stellen findet, statt immer alles mitzuschicken.
enum TextSearch {
    struct Chunk {
        let materialID: UUID
        let text: String
        let location: String
    }
    struct Hit {
        let chunk: Chunk
        let score: Double
    }

    static func chunks(materialID: UUID, text: String, size: Int = 1400) -> [Chunk] {
        var out: [Chunk] = []
        var current = ""
        var location = ""
        var currentLocation = ""
        for para in text.components(separatedBy: "\n\n") {
            if let marker = para.firstMatch(of: #/^\[(Seite|Folie) \d+\]/#) { location = String(marker.0).trimmingCharacters(in: CharacterSet(charactersIn: "[]")) }
            if current.count + para.count > size, !current.isEmpty {
                out.append(Chunk(materialID: materialID, text: current, location: currentLocation))
                current = ""
            }
            if current.isEmpty { currentLocation = location }
            current += (current.isEmpty ? "" : "\n\n") + para
            while current.count > size * 2 {
                let idx = current.index(current.startIndex, offsetBy: size)
                out.append(Chunk(materialID: materialID, text: String(current[..<idx]), location: currentLocation))
                current = String(current[idx...])
            }
        }
        if !current.trimmed.isEmpty { out.append(Chunk(materialID: materialID, text: current, location: currentLocation)) }
        return out
    }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 }
    }

    static func search(_ query: String, in chunks: [Chunk], limit: Int = 6) -> [Hit] {
        let q = Set(tokens(query))
        guard !q.isEmpty, !chunks.isEmpty else { return [] }
        let docs = chunks.map { tokens($0.text) }
        let avg = Double(docs.reduce(0) { $0 + $1.count }) / Double(max(1, docs.count))
        var df: [String: Int] = [:]
        for d in docs { for t in Set(d) where q.contains(t) { df[t, default: 0] += 1 } }
        let n = Double(docs.count)
        var hits: [Hit] = []
        for (i, d) in docs.enumerated() {
            var tf: [String: Int] = [:]
            for t in d where q.contains(t) { tf[t, default: 0] += 1 }
            guard !tf.isEmpty else { continue }
            var score = 0.0
            let lengthNorm: Double = 0.25 + 0.75 * Double(d.count) / max(1.0, avg)
            for (t, f) in tf {
                let docFreq = Double(df[t] ?? 0)
                let idf: Double = log(1.0 + (n - docFreq + 0.5) / (docFreq + 0.5))
                let ff = Double(f)
                let tfPart: Double = (ff * 2.2) / (ff + 1.2 * lengthNorm)
                score += idf * tfPart
            }
            hits.append(Hit(chunk: chunks[i], score: score))
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }
}

/// Minimaler ZIP-Leser (für .pptx/.docx) – ohne externe Programme, läuft auf Mac und iPhone.
struct ZipReader {
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
    }

    let data: Data
    let entries: [Entry]

    init?(url: URL) {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe), d.count > 22 else { return nil }
        data = d
        // End of Central Directory suchen (max. 64 KB Kommentar am Ende)
        let sig: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        var eocd: Int?
        var i = d.count - 22
        let lower = max(0, d.count - 66_000)
        while i >= lower {
            if d[d.startIndex + i] == sig[0] && d[d.startIndex + i + 1] == sig[1] && d[d.startIndex + i + 2] == sig[2] && d[d.startIndex + i + 3] == sig[3] { eocd = i; break }
            i -= 1
        }
        guard let e = eocd else { return nil }
        let count = Int(ZipReader.u16(d, e + 10))
        var p = Int(ZipReader.u32(d, e + 16))
        var list: [Entry] = []
        for _ in 0..<count {
            guard p + 46 <= d.count, ZipReader.u32(d, p) == 0x02014b50 else { break }
            let method = ZipReader.u16(d, p + 10)
            let csize = Int(ZipReader.u32(d, p + 20))
            let usize = Int(ZipReader.u32(d, p + 24))
            let nlen = Int(ZipReader.u16(d, p + 28))
            let elen = Int(ZipReader.u16(d, p + 30))
            let clen = Int(ZipReader.u16(d, p + 32))
            let off = Int(ZipReader.u32(d, p + 42))
            guard p + 46 + nlen <= d.count else { break }
            let name = String(data: d.subdata(in: (d.startIndex + p + 46)..<(d.startIndex + p + 46 + nlen)), encoding: .utf8) ?? ""
            list.append(Entry(name: name, method: method, compressedSize: csize, uncompressedSize: usize, localHeaderOffset: off))
            p += 46 + nlen + elen + clen
        }
        entries = list
    }

    func data(for name: String) -> Data? {
        guard let e = entries.first(where: { $0.name == name }) else { return nil }
        let h = e.localHeaderOffset
        guard h + 30 <= data.count, ZipReader.u32(data, h) == 0x04034b50 else { return nil }
        let start = h + 30 + Int(ZipReader.u16(data, h + 26)) + Int(ZipReader.u16(data, h + 28))
        guard start + e.compressedSize <= data.count else { return nil }
        let raw = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + e.compressedSize))
        switch e.method {
        case 0: return raw
        case 8: return ZipReader.inflate(raw, expected: e.uncompressedSize)
        default: return nil
        }
    }

    private static func inflate(_ src: Data, expected: Int) -> Data? {
        let capacity = max(expected, src.count * 4, 1024)
        var dst = Data(count: capacity)
        let written = dst.withUnsafeMutableBytes { (d: UnsafeMutableRawBufferPointer) -> Int in
            src.withUnsafeBytes { (s: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(d.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          s.bindMemory(to: UInt8.self).baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        return dst.prefix(written)
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
    }
    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(d[d.startIndex + o]) | UInt32(d[d.startIndex + o + 1]) << 8 | UInt32(d[d.startIndex + o + 2]) << 16 | UInt32(d[d.startIndex + o + 3]) << 24
    }
}
