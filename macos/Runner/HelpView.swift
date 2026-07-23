import SwiftUI

public struct HelpView: View {
    public let book: HelpBook
    @State private var selectedTopicID: String?
    @State private var searchText: String = ""

    public init(book: HelpBook) {
        self.book = book
        // Default select first topic if available
        _selectedTopicID = State(initialValue: book.categories.first?.topics.first?.id)
    }

    private var allTopics: [HelpTopic] {
        book.categories.flatMap { $0.topics }
    }

    private var filteredTopics: [HelpTopic] {
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return allTopics
        }
        let query = searchText.lowercased()
        return allTopics.filter { topic in
            topic.title.lowercased().contains(query) ||
            topic.summary.lowercased().contains(query) ||
            topic.keywords.contains(where: { $0.lowercased().contains(query) }) ||
            (topic.shortcuts?.contains(where: { $0.label.lowercased().contains(query) || $0.keys.lowercased().contains(query) }) ?? false) ||
            topic.sections.contains(where: { ($0.text?.lowercased().contains(query) ?? false) || ($0.title?.lowercased().contains(query) ?? false) })
        }
    }

    private var selectedTopic: HelpTopic? {
        allTopics.first(where: { $0.id == selectedTopicID }) ?? book.categories.first?.topics.first
    }

    public var body: some View {
        NavigationSplitView {
            List(selection: $selectedTopicID) {
                if !searchText.isEmpty {
                    Section("Search Results (\(filteredTopics.count))") {
                        ForEach(filteredTopics) { topic in
                            NavigationLink(value: topic.id) {
                                Label(topic.title, systemImage: "doc.text")
                            }
                        }
                    }
                } else {
                    ForEach(book.categories) { category in
                        Section(category.title) {
                            ForEach(category.topics) { topic in
                                NavigationLink(value: topic.id) {
                                    Label(topic.title, systemImage: category.icon)
                                }
                            }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            .listStyle(.sidebar)
        } detail: {
            if let topic = selectedTopic {
                HelpTopicDetailView(topic: topic)
            } else {
                Text("Select a topic from the sidebar")
                    .foregroundColor(.secondary)
            }
        }
        .searchable(text: $searchText, prompt: "Search Help Topics & Shortcuts...")
        .frame(minWidth: 780, minHeight: 500)
    }
}

struct HelpTopicDetailView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    Text(topic.title)
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text(topic.summary)
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                // Keyboard Shortcut Badges Header (if present)
                if let shortcuts = topic.shortcuts, !shortcuts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keyboard Shortcuts")
                            .font(.headline)
                        
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 8) {
                            ForEach(shortcuts) { shortcut in
                                HStack {
                                    Text(shortcut.label)
                                        .font(.subheadline)
                                    Spacer()
                                    Text(shortcut.keys)
                                        .font(.system(.caption, design: .monospaced))
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(5)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 5)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                }
                                .padding(8)
                                .background(Color.secondary.opacity(0.06))
                                .cornerRadius(8)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Divider()

                // Sections
                ForEach(topic.sections) { section in
                    SectionView(section: section)
                }
            }
            .padding(24)
        }
    }
}

struct SectionView: View {
    let section: HelpSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch section.type {
            case .heading:
                if let text = section.text {
                    Text(text)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .padding(.top, 8)
                }

            case .paragraph:
                if let text = section.text {
                    Text(text)
                        .font(.body)
                        .lineSpacing(4)
                }

            case .items:
                if let items = section.items {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .fontWeight(.bold)
                                    .foregroundColor(.accentColor)
                                Text(item)
                                    .font(.body)
                            }
                        }
                    }
                }

            case .callout:
                CalloutBoxView(
                    title: section.title ?? "Note",
                    text: section.text ?? "",
                    style: section.style ?? .info
                )

            case .code:
                if let code = section.code {
                    Text(code)
                        .font(.system(.body, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                }
            }
        }
    }
}

struct CalloutBoxView: View {
    let title: String
    let text: String
    let style: HelpSection.CalloutStyle

    private var accentColor: Color {
        switch style {
        case .info: return .blue
        case .tip: return .green
        case .warning: return .orange
        case .caution: return .red
        }
    }

    private var iconName: String {
        switch style {
        case .info: return "info.circle.fill"
        case .tip: return "lightbulb.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .caution: return "xmark.octagon.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(accentColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(accentColor)

                Text(text)
                    .font(.body)
                    .foregroundColor(.primary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accentColor.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            Rectangle()
                .fill(accentColor)
                .frame(width: 4),
            alignment: .leading
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
