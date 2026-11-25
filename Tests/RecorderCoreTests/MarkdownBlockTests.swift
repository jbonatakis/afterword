#if canImport(XCTest)
import XCTest
#endif
@testable import RecorderCore

final class MarkdownBlockTests: XCTestCase {
    func testCallSummaryFromIssue9() {
        let markdown = """
        - **Alice:**
          - Finished the migration.
          - Starting the review today.
        - **Bob:** out until Thursday.
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "•", depth: 0, text: "**Alice:**"),
            .listItem(marker: "•", depth: 1, text: "Finished the migration."),
            .listItem(marker: "•", depth: 1, text: "Starting the review today."),
            .listItem(marker: "•", depth: 0, text: "**Bob:** out until Thursday.")
        ])
    }

    func testMixedListsAndTabStops() {
        let markdown = """
        10. Plan
          \t+ Design
            * Review
            \t3.\tRead [the spec](https://example.com)
                4. Sign off
            + Ship
        11. Follow up
          1) Email
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "10.", depth: 0, text: "Plan"),
            .listItem(marker: "•", depth: 1, text: "Design"),
            .listItem(marker: "•", depth: 1, text: "Review"),
            .listItem(marker: "3.", depth: 2, text: "Read [the spec](https://example.com)"),
            .listItem(marker: "4.", depth: 2, text: "Sign off"),
            .listItem(marker: "•", depth: 1, text: "Ship"),
            .listItem(marker: "11.", depth: 0, text: "Follow up"),
            .listItem(marker: "1)", depth: 1, text: "Email")
        ])
    }

    func testUnevenIndentationAndBlankLines() {
        let markdown = """
          * First
                - Child

             - Another child
              - Grandchild
          * Second
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "•", depth: 0, text: "First"),
            .listItem(marker: "•", depth: 1, text: "Child"),
            .listItem(marker: "•", depth: 1, text: "Another child"),
            .listItem(marker: "•", depth: 2, text: "Grandchild"),
            .listItem(marker: "•", depth: 0, text: "Second")
        ])
    }

    func testOrderedListReturnsDirectlyFromGrandchildToRoot() {
        let markdown = """
        8. Release
           1. Prepare
              1. Package
        9. Publish
           1. Notify
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "8.", depth: 0, text: "Release"),
            .listItem(marker: "1.", depth: 1, text: "Prepare"),
            .listItem(marker: "1.", depth: 2, text: "Package"),
            .listItem(marker: "9.", depth: 0, text: "Publish"),
            .listItem(marker: "1.", depth: 1, text: "Notify")
        ])
    }

    func testFencesKeepRawIndentationAndIgnoreListMarkers() {
        let markdown = """
        - Parent
          ````md
            1. literal
        ```
        - still literal
          ````
          - Child
        ~~~
          * unterminated
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "•", depth: 0, text: "Parent"),
            .code("    1. literal\n```\n- still literal"),
            .listItem(marker: "•", depth: 1, text: "Child"),
            .code("  * unterminated")
        ])
    }

    func testTableTakesPrecedenceAndEndsPreviousList() {
        let markdown = """
        - Old list
          + Child
        1. Header | Value
        :--- | ---:
        - Cell | **bold**
            + New list
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "•", depth: 0, text: "Old list"),
            .listItem(marker: "•", depth: 1, text: "Child"),
            .table([["1. Header", "Value"], ["- Cell", "**bold**"]]),
            .listItem(marker: "•", depth: 0, text: "New list")
        ])
    }

    func testProseAndOtherBlockBoundaries() {
        let markdown = """
        - Old list
        2.5 seconds
        1.no-space
        -not-a-bullet
          7. New list
        ***
        ## Heading
        > Quote
        """
        XCTAssertEqual(MarkdownBlock.parse(markdown), [
            .listItem(marker: "•", depth: 0, text: "Old list"),
            .text("2.5 seconds 1.no-space -not-a-bullet"),
            .listItem(marker: "7.", depth: 0, text: "New list"),
            .rule, .heading("Heading"), .quote("Quote")
        ])
    }
}
