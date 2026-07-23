import Foundation

public struct HelpBook: Codable, Identifiable {
    public var id: String { title }
    public let title: String
    public let version: String
    public let categories: [HelpCategory]
}

public struct HelpCategory: Codable, Identifiable {
    public let id: String
    public let title: String
    public let icon: String
    public let topics: [HelpTopic]
}

public struct HelpTopic: Codable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let keywords: [String]
    public let shortcuts: [KeyboardShortcutRef]?
    public let sections: [HelpSection]
}

public struct KeyboardShortcutRef: Codable, Identifiable {
    public var id: String { label }
    public let label: String
    public let keys: String
}

public struct HelpSection: Codable, Identifiable {
    public var id: String { (title ?? "") + (text ?? "") + String(type.rawValue.hashValue) }
    public let type: SectionType
    public let title: String?
    public let text: String?
    public let items: [String]?
    public let style: CalloutStyle?
    public let code: String?

    public enum SectionType: String, Codable {
        case heading
        case paragraph
        case items
        case callout
        case code
    }

    public enum CalloutStyle: String, Codable {
        case info
        case tip
        case warning
        case caution
    }
}

public class HelpDataLoader {
    public static func loadBook() -> HelpBook {
        // Look up help_book.json in the main app bundle
        if let url = Bundle.main.url(forResource: "help_book", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let book = try? JSONDecoder().decode(HelpBook.self, from: data) {
            return book
        }
        
        // Fallback: check relative directory in build/bundle
        let fallbackPath = NSString(string: #file).deletingLastPathComponent + "/help_book.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackPath)),
           let book = try? JSONDecoder().decode(HelpBook.self, from: data) {
            return book
        }

        return HelpBook(title: "Magic Git Help", version: "1.0", categories: [])
    }
}
