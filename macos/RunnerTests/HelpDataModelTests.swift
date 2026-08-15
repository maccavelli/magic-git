import Cocoa
import XCTest

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

        XCTAssertEqual(topic.sections.count, 2)
        XCTAssertEqual(topic.sections[0].type, .paragraph)
        XCTAssertEqual(topic.sections[0].text, "Hello world")
        XCTAssertEqual(topic.sections[1].type, .callout)
        XCTAssertEqual(topic.sections[1].style, .tip)
        XCTAssertEqual(topic.sections[1].title, "Tip")
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
    }
}
