import SwiftUI

/// Schlanker Markdown-Renderer (Überschriften, Listen, Code, Zitate, Tabellen, Inline-Formatierung).
/// `Equatable`: Parsen ist teuer – bei gleichem Text überspringt SwiftUI den Body.
struct MarkdownView: View, Equatable {
    let text: String
    var baseSize: CGFloat = 13.5

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(MarkdownParser.parse(text)) { b in
                MarkdownBlockView(block: b.kind, baseSize: baseSize)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MarkdownBlockView: View {
    let block: MDBlock.Kind
    let baseSize: CGFloat

    var body: some View {
        switch block {
        case .heading(let level, let s):
            Text(Self.inline(s))
                .scaledFont(size: level == 1 ? baseSize + 8 : (level == 2 ? baseSize + 4 : baseSize + 1.5), weight: level <= 2 ? .bold : .semibold)
                .tracking(level == 1 ? -0.4 : -0.15)
                .padding(.top, level <= 2 ? 6 : 2)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let s):
            Text(Self.inline(s)).scaledFont(size: baseSize).lineSpacing(2.5)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items) { it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(it.marker).scaledFont(size: baseSize, weight: .medium).monospacedDigit().foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(Self.inline(it.text)).scaledFont(size: baseSize).lineSpacing(2)
                    }
                    .padding(.leading, CGFloat(it.level) * 16)
                    .accessibilityElement(children: .combine)
                }
            }
        case .code(let code):
            ScrollView(.horizontal) {
                Text(code).scaledFont(size: baseSize - 1.5, design: .monospaced).padding(10)
            }
            .scrollIndicators(.hidden)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(Self.inline(s)).scaledFont(size: baseSize).foregroundStyle(.secondary)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(rows) { row in
                        GridRow {
                            ForEach(row.cells) { cell in
                                Text(Self.inline(cell.text)).scaledFont(size: baseSize - 0.5, weight: row.id == 0 ? .semibold : .regular)
                            }
                        }
                        if row.id == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.hidden)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    private static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Ein Element eines geparsten Dokuments. Die `id` ist die Reihenfolge im Dokument –
/// beim Streamen wächst der Text nur hinten, frühere Blöcke behalten so ihre Identität.
struct MDListItem: Identifiable { var id: Int; var level: Int; var marker: String; var text: String }

struct MDTableRow: Identifiable {
    struct Cell: Identifiable { var id: Int; var text: String }
    var id: Int
    var cells: [Cell]
}

struct MDBlock: Identifiable {
    enum Kind {
        case heading(Int, String)
        case paragraph(String)
        case list([MDListItem])
        case code(String)
        case quote(String)
        case rule
        case table([MDTableRow])
    }
    var id: Int
    var kind: Kind
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var kinds: [MDBlock.Kind] = []
        var para: [String] = []
        var list: [MDListItem] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flushPara() { if !para.isEmpty { kinds.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !list.isEmpty { kinds.append(.list(list)); list = [] } }
        func flushQuote() { if !quote.isEmpty { kinds.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushTable() {
            guard !table.isEmpty else { return }
            kinds.append(.table(table.enumerated().map { r, cells in
                MDTableRow(id: r, cells: cells.enumerated().map { MDTableRow.Cell(id: $0.offset, text: $0.element) })
            }))
            table = []
        }
        func flushAll() { flushPara(); flushList(); flushQuote(); flushTable() }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)

            if var c = code {
                if t.hasPrefix("```") { kinds.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(line); code = c }
                continue
            }
            if t.hasPrefix("```") { flushAll(); code = []; continue }
            if t.isEmpty { flushAll(); continue }

            if t.hasPrefix("#") {
                let level = t.prefix { $0 == "#" }.count
                if level <= 6, t.dropFirst(level).first == " " {
                    flushAll()
                    kinds.append(.heading(level, String(t.dropFirst(level)).trimmed))
                    continue
                }
            }
            if t == "---" || t == "***" || t == "___" { flushAll(); kinds.append(.rule); continue }
            if t.hasPrefix(">") {
                flushPara(); flushList(); flushTable()
                quote.append(String(t.dropFirst()).trimmed)
                continue
            }
            if t.hasPrefix("|") && t.hasSuffix("|") && t.count > 2 {
                flushPara(); flushList(); flushQuote()
                let cells = t.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmed }
                if cells.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { continue }
                table.append(cells)
                continue
            }
            let indent = line.prefix { $0 == " " }.count / 2
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") {
                flushPara(); flushQuote(); flushTable()
                var body = String(t.dropFirst(2))
                var marker = "•"
                if body.hasPrefix("[ ] ") { marker = "☐"; body = String(body.dropFirst(4)) }
                else if body.hasPrefix("[x] ") || body.hasPrefix("[X] ") { marker = "☑"; body = String(body.dropFirst(4)) }
                list.append(MDListItem(id: list.count, level: min(indent, 4), marker: marker, text: body))
                continue
            }
            if let m = t.firstMatch(of: #/^(\d{1,3}|[a-z])[\.\)] (.*)$/#) {
                flushPara(); flushQuote(); flushTable()
                list.append(MDListItem(id: list.count, level: min(indent, 4), marker: "\(m.1).", text: String(m.2)))
                continue
            }
            if !list.isEmpty && indent > 0 {
                // Fortsetzung eines Listenpunkts
                list[list.count - 1].text += " " + t
                continue
            }
            flushList(); flushQuote(); flushTable()
            para.append(t)
        }
        if let c = code { kinds.append(.code(c.joined(separator: "\n"))) }
        flushAll()
        return kinds.enumerated().map { MDBlock(id: $0.offset, kind: $0.element) }
    }
}
