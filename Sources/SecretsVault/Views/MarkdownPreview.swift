import SwiftUI
import AppKit
import SecretsVaultCore

// MARK: - Views

struct MarkdownPreview: View {
    let text: String
    @EnvironmentObject var themes: ThemeManager

    private var theme: Theme { themes.current }

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
        .themedBackground(theme.contentBackground)
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(inlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(theme.resolvedHeading)
                .padding(.top, level <= 2 ? 6 : 2)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(inlineMarkdown(text))
                .foregroundStyle(theme.resolvedTextPrimary)
                .textSelection(.enabled)
        case .code(let code):
            CodeBlockView(code: code)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(theme.resolvedTextSecondary)
                        Text(inlineMarkdown(item))
                            .foregroundStyle(theme.resolvedTextPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(n + 1).")
                            .foregroundStyle(theme.resolvedTextSecondary)
                            .monospacedDigit()
                        Text(inlineMarkdown(item))
                            .foregroundStyle(theme.resolvedTextPrimary)
                            .textSelection(.enabled)
                    }
                }
            }
        case .quote(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(inlineMarkdown(line))
                        .foregroundStyle(theme.resolvedTextSecondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(theme.resolvedQuoteBar)
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
    @EnvironmentObject var themes: ThemeManager
    @State private var copied = false

    private var theme: Theme { themes.current }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code.isEmpty ? " " : code)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(theme.resolvedCodeText)
                    .textSelection(.enabled)
                    .padding(12)
            }
            Button {
                ClipboardService.copyConcealed(code)
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : theme.resolvedTextSecondary)
            }
            .buttonStyle(.borderless)
            .help("Copy — clipboard clears after 30 seconds")
            .padding(8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.resolvedCodeBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.resolvedCodeBorder)
        )
    }
}
