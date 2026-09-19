import Cocoa
import XCTest

@testable import Magic_Git

class HelpDataModelTests: XCTestCase {

    func testHelpBookDecoding() throws {
        let json = """
        {
          "title": "Test Guide",
          "version": "1.0",
          "categories": [
            {
              "id": "cat1",
              "title": "Category 1",
              "icon": "folder",
              "topics": [
                {
                  "id": "top1",
                  "title": "Topic 1",
                  "summary": "Summary 1",
                  "keywords": ["test", "topic"],
                  "shortcuts": [
                    { "label": "Shortcut 1", "keys": "⌘K", "actionId": "global.commandPalette" }
                  ],
                  "sections": [
                    {
                      "type": "paragraph",
                      "text": "Hello world"
                    },
                    {
                      "type": "callout",
                      "title": "Tip",
                      "text": "Callout text",
                      "style": "tip"
                    }
                  ]
                }
              ]
            }
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let book = try JSONDecoder().decode(HelpBook.self, from: data)

        XCTAssertEqual(book.title, "Test Guide")
        XCTAssertEqual(book.version, "1.0")
        XCTAssertEqual(book.categories.count, 1)

        let category = book.categories.first!
        XCTAssertEqual(category.id, "cat1")
        XCTAssertEqual(category.title, "Category 1")
        XCTAssertEqual(category.icon, "folder")
        XCTAssertEqual(category.topics.count, 1)

        let topic = category.topics.first!
        XCTAssertEqual(topic.id, "top1")
        XCTAssertEqual(topic.title, "Topic 1")
        XCTAssertEqual(topic.summary, "Summary 1")
        XCTAssertEqual(topic.keywords, ["test", "topic"])
        XCTAssertEqual(topic.shortcuts?.count, 1)
        XCTAssertEqual(topic.shortcuts?.first?.label, "Shortcut 1")
        XCTAssertEqual(topic.shortcuts?.first?.keys, "⌘K")
        XCTAssertEqual(topic.shortcuts?.first?.actionId, "global.commandPalette")

        XCTAssertEqual(topic.sections.count, 2)
        XCTAssertEqual(topic.sections[0].type, .paragraph)
        XCTAssertEqual(topic.sections[0].text, "Hello world")
        XCTAssertEqual(topic.sections[1].type, .callout)
        XCTAssertEqual(topic.sections[1].style, .tip)
        XCTAssertEqual(topic.sections[1].title, "Tip")
    }

    func testShortcutWithoutActionIdStillDecodes() throws {
        let json = """
        {
          "title": "T",
          "version": "1.0",
          "categories": [{
            "id": "c", "title": "C", "icon": "folder",
            "topics": [{
              "id": "t", "title": "T", "summary": "S",
              "keywords": ["k"],
              "shortcuts": [{ "label": "Go", "keys": "⌘K" }],
              "sections": [{ "type": "paragraph", "text": "Hi" }]
            }]
          }]
        }
        """
        let book = try JSONDecoder().decode(HelpBook.self, from: json.data(using: .utf8)!)
        XCTAssertNil(book.categories.first?.topics.first?.shortcuts?.first?.actionId)
    }

    // MARK: - Search (0053 S1)

    /// A topic whose only match for each probe word lives in one section kind,
    /// so each test proves that kind is searched.
    private func searchFixture() throws -> HelpTopic {
        let json = """
        {
          "id": "t", "title": "Title words", "summary": "Summary words",
          "keywords": ["keyword"],
          "sections": [
            { "type": "items", "items": ["Add to .gitignore from the file tree"] },
            { "type": "code", "code": "git lfs pull" }
          ]
        }
        """
        return try JSONDecoder().decode(HelpTopic.self, from: json.data(using: .utf8)!)
    }

    func testSearchMatchesItems() throws {
        XCTAssertTrue(HelpSearch.matches(try searchFixture(), query: "gitignore"))
    }

    func testSearchMatchesCode() throws {
        XCTAssertTrue(HelpSearch.matches(try searchFixture(), query: "lfs pull"))
    }

    func testEmptyQueryMatchesAll() throws {
        XCTAssertTrue(HelpSearch.matches(try searchFixture(), query: "   "))
    }

    func testSearchIsCaseInsensitive() throws {
        XCTAssertTrue(HelpSearch.matches(try searchFixture(), query: "GITIGNORE"))
        XCTAssertFalse(HelpSearch.matches(try searchFixture(), query: "no such phrase"))
    }

    func testLoadBookFromBundleOrFile() {
        let book = HelpDataLoader.loadBook()
        XCTAssertFalse(book.title.isEmpty)
        XCTAssertFalse(book.categories.isEmpty)

        let tabCategory = book.categories.first { $0.id == "panels" }
        XCTAssertNotNil(tabCategory, "Expected 'panels' category in help_book.json")

        if let tabCat = tabCategory {
            let topicIds = tabCat.topics.map { $0.id }
            XCTAssertTrue(topicIds.contains("tab_repository"))
            XCTAssertTrue(topicIds.contains("tab_history"))
            XCTAssertTrue(topicIds.contains("tab_branches"))
            XCTAssertTrue(topicIds.contains("tab_stashes"))
            XCTAssertTrue(topicIds.contains("tab_forge"))
            XCTAssertTrue(topicIds.contains("tab_worktrees"))
        }

        let troubleshooting = book.categories.first { $0.id == "troubleshooting" }
        XCTAssertEqual(
            troubleshooting?.topics.map { $0.id },
            ["trouble_connection", "trouble_forge", "trouble_refresh", "trouble_access"]
        )
    }
}
