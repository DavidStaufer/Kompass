import SwiftUI

/// Schlanker Markdown-Renderer (Überschriften, Listen, Code, Zitate, Tabellen, Inline-Formatierung).
struct MarkdownView: View {
    let text: String
    var baseSize: CGFloat = 13.5

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 9) {
            ForEach(blocks.indices, id: \.self) { i in
                block(blocks[i])
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func block(_ b: MDBlock) -> some View {
        switch b {
        case .heading(let level, let s):
            Text(inline(s))
                .font(.system(size: level == 1 ? baseSize + 8 : (level == 2 ? baseSize + 4 : baseSize + 1.5), weight: level <= 2 ? .bold : .semibold))
                .tracking(level == 1 ? -0.4 : -0.15)
                .padding(.top, level <= 2 ? 6 : 2)
        case .paragraph(let s):
            Text(inline(s)).font(.system(size: baseSize)).lineSpacing(2.5)
        case .list(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { i in
                    let it = items[i]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(it.marker).font(.system(size: baseSize, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        Text(inline(it.text)).font(.system(size: baseSize)).lineSpacing(2)
                    }
                    .padding(.leading, CGFloat(it.level) * 16)
                }
            }
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: baseSize - 1.5, design: .monospaced)).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        case .quote(let s):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(inline(s)).font(.system(size: baseSize)).foregroundStyle(.secondary)
            }
        case .rule:
            Divider().padding(.vertical, 4)
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    ForEach(rows.indices, id: \.self) { r in
                        GridRow {
                            ForEach(rows[r].indices, id: \.self) { c in
                                Text(inline(rows[r][c])).font(.system(size: baseSize - 0.5, weight: r == 0 ? .semibold : .regular))
                            }
                        }
                        if r == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct MDListItem { var level: Int; var marker: String; var text: String }

enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case list([MDListItem])
    case code(String)
    case quote(String)
    case rule
    case table([[String]])
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        var para: [String] = []
        var list: [MDListItem] = []
        var quote: [String] = []
        var table: [[String]] = []
        var code: [String]?

        func flushPara() { if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] } }
        func flushList() { if !list.isEmpty { blocks.append(.list(list)); list = [] } }
        func flushQuote() { if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))); quote = [] } }
        func flushTable() { if !table.isEmpty { blocks.append(.table(table)); table = [] } }
        func flushAll() { flushPara(); flushList(); flushQuote(); flushTable() }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\t", with: "    ")
            let t = line.trimmingCharacters(in: .whitespaces)

            if var c = code {
                if t.hasPrefix("```") { blocks.append(.code(c.joined(separator: "\n"))); code = nil } else { c.append(line); code = c }
                continue
            }
            if t.hasPrefix("```") { flushAll(); code = []; continue }
            if t.isEmpty { flushAll(); continue }

            if t.hasPrefix("#") {
                let level = t.prefix { $0 == "#" }.count
                if level <= 6, t.dropFirst(level).first == " " {
                    flushAll()
                    blocks.append(.heading(level, String(t.dropFirst(level)).trimmed))
                    continue
                }
            }
            if t == "---" || t == "***" || t == "___" { flushAll(); blocks.append(.rule); continue }
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
                list.append(MDListItem(level: min(indent, 4), marker: marker, text: body))
                continue
            }
            if let m = t.firstMatch(of: #/^(\d{1,3}|[a-z])[\.\)] (.*)$/#) {
                flushPara(); flushQuote(); flushTable()
                list.append(MDListItem(level: min(indent, 4), marker: "\(m.1).", text: String(m.2)))
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
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flushAll()
        return blocks
    }
}
