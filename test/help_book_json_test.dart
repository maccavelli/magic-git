import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';

/// Splits a Help chord string like "⌘⇧B" into modifier flags + the key part.
({bool meta, bool shift, bool alt, bool control, String key}) _parseChord(
  String keys,
) {
  var meta = false;
  var shift = false;
  var alt = false;
  var control = false;
  var rest = keys;
  var progressed = true;
  while (progressed && rest.isNotEmpty) {
    progressed = true;
    if (rest.startsWith('⌘')) {
      meta = true;
      rest = rest.substring(1);
    } else if (rest.startsWith('⇧')) {
      shift = true;
      rest = rest.substring(1);
    } else if (rest.startsWith('⌥')) {
      alt = true;
      rest = rest.substring(1);
    } else if (rest.startsWith('⌃')) {
      control = true;
      rest = rest.substring(1);
    } else {
      progressed = false;
    }
  }
  return (meta: meta, shift: shift, alt: alt, control: control, key: rest);
}

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

    // 0009 H18: Help once taught ⌘⇧B as "Toggle All Branches Filter" while
    // the keymap binds that chord to history.checkout — following Help could
    // detach HEAD. Any Help entry using the checkout chord must say checkout.
    // (Phase 10.5 / M27 grows this to a full Help-vs-keymap audit.)
    test('⌘⇧B in Help only ever means checkout', () {
      final checkout = kKeymapActions.firstWhere(
        (a) => a.id == 'history.checkout',
      );
      final binding = checkout.defaultBindings.single;
      expect(binding.meta, isTrue);
      expect(binding.shift, isTrue);
      expect(binding.keyId, LogicalKeyboardKey.keyB.keyId);

      var checked = 0;
      for (final cat in jsonBook['categories'] as List<dynamic>) {
        final topics = (cat as Map<String, dynamic>)['topics'] as List<dynamic>;
        for (final top in topics) {
          final topic = top as Map<String, dynamic>;
          final shortcuts = topic['shortcuts'] as List<dynamic>? ?? const [];
          for (final sc in shortcuts) {
            final shortcut = sc as Map<String, dynamic>;
            final chord = _parseChord(shortcut['keys'] as String);
            if (chord.meta &&
                chord.shift &&
                !chord.alt &&
                !chord.control &&
                chord.key.toUpperCase() == 'B') {
              checked++;
              expect(
                (shortcut['label'] as String).toLowerCase(),
                contains('checkout'),
                reason:
                    '⌘⇧B is bound to history.checkout ("${checkout.label}") — '
                    'Help must not teach it as "${shortcut['label']}" '
                    '(topic ${topic['id']})',
              );
            }
          }
        }
      }
      expect(
        checked,
        greaterThan(0),
        reason: 'the History topic should teach ⌘⇧B as checkout',
      );
    });

    // 0009 M27: every Help chord that collides with a keymap default must
    // describe the same verb — a taught chord that runs something else is
    // exactly the ⌘⇧B/checkout trap H18 closed. Verbs are compared by
    // significant-word overlap with the owning action's label; any scope's
    // owner counts, since non-overlapping scopes may legitimately share a
    // chord.
    test('every Help chord agrees with the keymap action that owns it', () {
      const stopWords = {
        'the', 'a', 'an', 'to', 'of', 'in', 'on', 'for', 'and', 'or',
        'view', 'sheet', 'panel', 'selected', 'all', 'with', 'file', 'files',
        'log', 'state', 'last', 'working', //
      };
      Set<String> words(String s) => s
          .toLowerCase()
          .split(RegExp('[^a-z]+'))
          .where((w) => w.isNotEmpty && !stopWords.contains(w))
          .toSet();
      String keyPartOf(KeyBinding b) => b.label.replaceAll(
        RegExp('[⌃⌥⇧⌘]'),
        '',
      );

      for (final cat in jsonBook['categories'] as List<dynamic>) {
        final topics = (cat as Map<String, dynamic>)['topics'] as List<dynamic>;
        for (final top in topics) {
          final topic = top as Map<String, dynamic>;
          final shortcuts = topic['shortcuts'] as List<dynamic>? ?? const [];
          for (final sc in shortcuts) {
            final shortcut = sc as Map<String, dynamic>;
            final chord = _parseChord(shortcut['keys'] as String);
            final owners = kKeymapActions.where(
              (action) => action.defaultBindings.any(
                (b) =>
                    b.meta == chord.meta &&
                    b.shift == chord.shift &&
                    b.alt == chord.alt &&
                    b.control == chord.control &&
                    keyPartOf(b).toUpperCase() == chord.key.toUpperCase(),
              ),
            );
            if (owners.isEmpty) continue; // chord unbound (native ⌘, etc.)
            final helpWords = words(shortcut['label'] as String);
            expect(
              owners.any(
                (a) => words(a.label).intersection(helpWords).isNotEmpty,
              ),
              isTrue,
              reason:
                  'Help teaches "${shortcut['label']}" for '
                  '${shortcut['keys']}, but the keymap binds that chord to '
                  '${owners.map((a) => '${a.id} ("${a.label}")').join(', ')} '
                  '(topic ${topic['id']})',
            );
          }
        }
      }
    });
  });
}
