import Foundation

// MARK: - Block model & parser

public struct MDBlock: Identifiable, Equatable {
    public enum Kind: Equatable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(String)
        case bullets([String])
        case numbered([String])
        case quote([String])
        case rule
    }
    public let id: Int
    public let kind: Kind

    public init(id: Int, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

/// Splits markdown into top-level blocks. Deliberately small: fenced code,
/// ATX headings, bullet and numbered lists, block quotes, rules and
/// paragraphs. Inline styling is left to `inlineMarkdown`.
public func parseMarkdown(_ text: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    var nextID = 0
    func add(_ kind: MDBlock.Kind) {
        blocks.append(MDBlock(id: nextID, kind: kind))
        nextID += 1
    }
    func isNumbered(_ t: String) -> Bool {
        t.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil
    }

    let lines = text.components(separatedBy: .newlines)
    var idx = 0
    while idx < lines.count {
        let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("```") {
            var codeLines: [String] = []
            idx += 1
            while idx < lines.count,
                  !lines[idx].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                codeLines.append(lines[idx])
                idx += 1
            }
            idx += 1 // skip closing fence
            add(.code(codeLines.joined(separator: "\n")))
            continue
        }
        if trimmed.isEmpty {
            idx += 1
            continue
        }
        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            add(.rule)
            idx += 1
            continue
        }
        if trimmed.hasPrefix("#") {
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let rest = trimmed.dropFirst(level)
            if level <= 6 && (rest.isEmpty || rest.first == " ") {
                add(.heading(level: level, text: rest.trimmingCharacters(in: .whitespaces)))
                idx += 1
                continue
            }
        }
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
            var items: [String] = []
            while idx < lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("+ ") else { break }
                items.append(String(t.dropFirst(2)))
                idx += 1
            }
            add(.bullets(items))
            continue
        }
        if isNumbered(trimmed) {
            var items: [String] = []
            while idx < lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                guard let r = t.range(of: #"^\d+[.)]\s"#, options: .regularExpression) else { break }
                items.append(String(t[r.upperBound...]))
                idx += 1
            }
            add(.numbered(items))
            continue
        }
        if trimmed.hasPrefix(">") {
            var qlines: [String] = []
            while idx < lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(">") else { break }
                qlines.append(t.dropFirst().trimmingCharacters(in: .whitespaces))
                idx += 1
            }
            add(.quote(qlines))
            continue
        }
        add(.paragraph(trimmed))
        idx += 1
    }
    return blocks
}

/// Inline markdown (bold, italic, code, links) via Foundation; falls back
/// to the plain text when the string does not parse.
public func inlineMarkdown(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attr = try? AttributedString(markdown: s, options: options) {
        return attr
    }
    return AttributedString(s)
}
