import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('help_book.json validation', () {
    late Map<String, dynamic> jsonBook;

    setUpAll(() {
      final file = File('macos/Runner/help_book.json');
      expect(file.existsSync(), isTrue, reason: 'help_book.json must exist in macos/Runner/');
      final content = file.readAsStringSync();
      jsonBook = jsonDecode(content) as Map<String, dynamic>;
    });

    test('book header contains title and version', () {
      expect(jsonBook['title'], equals('Magic Git User Guide'));
      expect(jsonBook['version'], isNotEmpty);
    });

    test('categories array contains required sections', () {
      final categories = jsonBook['categories'] as List<dynamic>;
      expect(categories, isNotEmpty);

      final categoryIds = categories.map((c) => (c as Map<String, dynamic>)['id'] as String).toList();
      expect(categoryIds, containsAll([
        'getting_started',
        'tabs',
        'features',
        'troubleshooting',
      ]));
    });

    test('all 6 main application tabs have complete support topics', () {
      final categories = jsonBook['categories'] as List<dynamic>;
      final tabsCategory = categories.firstWhere(
        (c) => (c as Map<String, dynamic>)['id'] == 'tabs',
      ) as Map<String, dynamic>;

      final topics = tabsCategory['topics'] as List<dynamic>;
      final topicIds = topics.map((t) => (t as Map<String, dynamic>)['id'] as String).toList();

      expect(topicIds, containsAll([
        'tab_repository',
        'tab_history',
        'tab_branches',
        'tab_stashes',
        'tab_forge',
        'tab_worktrees',
      ]));
    });

    test('all topics have required fields and non-empty sections', () {
      final categories = jsonBook['categories'] as List<dynamic>;

      for (final cat in categories) {
        final category = cat as Map<String, dynamic>;
        expect(category['id'], isNotEmpty);
        expect(category['title'], isNotEmpty);
        expect(category['icon'], isNotEmpty);

        final topics = category['topics'] as List<dynamic>;
        expect(topics, isNotEmpty);

        for (final top in topics) {
          final topic = top as Map<String, dynamic>;
          expect(topic['id'], isNotEmpty);
          expect(topic['title'], isNotEmpty);
          expect(topic['summary'], isNotEmpty);

          final keywords = topic['keywords'] as List<dynamic>;
          expect(keywords, isNotEmpty);

          final sections = topic['sections'] as List<dynamic>;
          expect(sections, isNotEmpty);

          for (final sec in sections) {
            final section = sec as Map<String, dynamic>;
            final type = section['type'] as String;
            expect(
              ['heading', 'paragraph', 'items', 'callout', 'code'],
              contains(type),
              reason: 'Invalid section type: $type in topic ${topic['id']}',
            );

            if (type == 'callout') {
              expect(
                ['info', 'tip', 'warning', 'caution'],
                contains(section['style']),
                reason: 'Invalid callout style in topic ${topic['id']}',
              );
            }
          }
        }
      }
    });

    test('keyboard shortcuts are properly structured when present', () {
      final categories = jsonBook['categories'] as List<dynamic>;
      int shortcutCount = 0;

      for (final cat in categories) {
        final topics = (cat as Map<String, dynamic>)['topics'] as List<dynamic>;
        for (final top in topics) {
          final topic = top as Map<String, dynamic>;
          if (topic.containsKey('shortcuts') && topic['shortcuts'] != null) {
            final shortcuts = topic['shortcuts'] as List<dynamic>;
            for (final sc in shortcuts) {
              final shortcut = sc as Map<String, dynamic>;
              expect(shortcut['label'], isNotEmpty);
              expect(shortcut['keys'], isNotEmpty);
              shortcutCount++;
            }
          }
        }
      }

      expect(shortcutCount, greaterThan(0), reason: 'Expected keyboard shortcut references in topics');
    });
  });
}
