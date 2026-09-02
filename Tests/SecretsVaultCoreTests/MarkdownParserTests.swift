import XCTest
import SecretsVaultCore

final class MarkdownParserTests: XCTestCase {

    private func kinds(_ text: String) -> [MDBlock.Kind] { parseMarkdown(text).map(\.kind) }

    func testEmptyInputGivesNoBlocks() {
        XCTAssertEqual(kinds(""), [])
        XCTAssertEqual(kinds("\n\n   \n"), [])
    }

    func testHeadings() {
        XCTAssertEqual(kinds("# One\n## Two\n###### Six\n#"), [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 6, text: "Six"),
            .heading(level: 1, text: ""),
        ])
    }

    func testHashWithoutSpaceIsAParagraph() {
        XCTAssertEqual(kinds("#hashtag"), [.paragraph("#hashtag")])
        XCTAssertEqual(kinds("####### seven"), [.paragraph("####### seven")])
    }

    func testFencedCodePreservesContentVerbatim() {
        let text = "```sh\n  indented\n\nlast\n```\nafter"
        XCTAssertEqual(kinds(text), [.code("  indented\n\nlast"), .paragraph("after")])
    }

    func testUnterminatedFenceRunsToEnd() {
        XCTAssertEqual(kinds("```\na\nb"), [.code("a\nb")])
    }

    func testBulletsMergeMixedMarkers() {
        XCTAssertEqual(kinds("- a\n* b\n+ c\n\n- d"), [.bullets(["a", "b", "c"]), .bullets(["d"])])
    }

    func testNumberedListAcceptsDotAndParen() {
        XCTAssertEqual(kinds("1. a\n2) b\n10. c"), [.numbered(["a", "b", "c"])])
        XCTAssertEqual(kinds("1.no space"), [.paragraph("1.no space")])
    }

    func testQuoteLines() {
        XCTAssertEqual(kinds("> a\n>b\n\nplain"), [.quote(["a", "b"]), .paragraph("plain")])
    }

    func testRules() {
        XCTAssertEqual(kinds("---\n***\n___\n----"), [.rule, .rule, .rule, .paragraph("----")])
    }

    func testParagraphsAreTrimmedAndSplitOnBlankLines() {
        XCTAssertEqual(kinds("  one  \ntwo\n\nthree"), [
            .paragraph("one"), .paragraph("two"), .paragraph("three"),
        ])
    }

    func testIDsAreSequential() {
        XCTAssertEqual(parseMarkdown("a\n\nb\n\n---").map(\.id), [0, 1, 2])
    }

    func testInlineMarkdownKeepsTextAndFallsBackToPlain() {
        XCTAssertEqual(String(inlineMarkdown("**bold** and `code`").characters), "bold and code")
        XCTAssertEqual(String(inlineMarkdown("unbalanced **").characters), "unbalanced **")
    }
}
