import SwiftUI
import AppKit

// MARK: - Block model & parser

struct MDBlock: Identifiable {
    enum Kind {
        case heading(level: Int, text: String)
        case paragraph(String)
        case code(String)
        case bullets([String])
        case numbered([String])
        case quote([String])
        case rule
    }
    let id: Int
    let kind: Kind
}

func parseMarkdown(_ text: String) -> [MDBlock] {
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

func inlineMarkdown(_ s: String) -> AttributedString {
    let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    if let attr = try? AttributedString(markdown: s, options: options) {
        return attr
    }
    return AttributedString(s)
}

// MARK: - Views

struct MarkdownPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(parseMarkdown(text)) { block in
                    blockView(block)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .textSelection(.enabled)
        case .code(let code):
            CodeBlockView(code: code)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inlineMarkdown(item)).textSelection(.enabled)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n + 1).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inlineMarkdown(item)).textSelection(.enabled)
                    }
                }
            }
        case .quote(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(inlineMarkdown(line))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
            }
        case .rule:
            Divider()
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .system(size: 26, weight: .bold)
        case 2: return .system(size: 21, weight: .bold)
        case 3: return .system(size: 17, weight: .semibold)
        default: return .system(size: 15, weight: .semibold)
        }
    }
}

struct CodeBlockView: View {
    let code: String
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy code")
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
    }
}
