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

Map<String, dynamic> _topicById(Map<String, dynamic> book, String id) {
  for (final cat in book['categories'] as List<dynamic>) {
    for (final top in (cat as Map<String, dynamic>)['topics'] as List) {
      final topic = top as Map<String, dynamic>;
      if (topic['id'] == id) return topic;
    }
  }
  fail('topic $id is missing from help_book.json');
}

Iterable<Map<String, dynamic>> _allShortcuts(Map<String, dynamic> book) sync* {
  for (final cat in book['categories'] as List<dynamic>) {
    for (final top in (cat as Map<String, dynamic>)['topics'] as List) {
      final topic = top as Map<String, dynamic>;
      for (final sc in topic['shortcuts'] as List<dynamic>? ?? const []) {
        yield sc as Map<String, dynamic>;
      }
    }
  }
}

/// Maps a [KeyBinding] to the Help key token `_parseChord` leaves after
/// modifiers (↩, ⌫, Space, ",", "=", "-", letter).
String _bindingKeyToken(KeyBinding binding) {
  final key = LogicalKeyboardKey(binding.keyId);
  if (key == LogicalKeyboardKey.enter ||
      key == LogicalKeyboardKey.numpadEnter) {
    return '↩';
  }
  if (key == LogicalKeyboardKey.backspace) return '⌫';
  if (key == LogicalKeyboardKey.space) return 'Space';
  if (key == LogicalKeyboardKey.comma) return ',';
  if (key == LogicalKeyboardKey.escape) return '⎋';
  if (key == LogicalKeyboardKey.equal) return '=';
  if (key == LogicalKeyboardKey.minus) return '-';
  final label = key.keyLabel;
  return label.isEmpty ? '?' : label.toUpperCase();
}

bool _chordEquals(
  ({bool meta, bool shift, bool alt, bool control, String key}) parsed,
  KeyBinding binding,
) {
  if (parsed.meta != binding.meta ||
      parsed.shift != binding.shift ||
      parsed.alt != binding.alt ||
      parsed.control != binding.control) {
    return false;
  }
  final helpKey = parsed.key == '−' ? '-' : parsed.key;
  return helpKey.toUpperCase() == _bindingKeyToken(binding).toUpperCase();
}

String _topicBlob(Map<String, dynamic> book, String id) =>
    jsonEncode(_topicById(book, id));

void main() {
  group('help_book.json validation', () {
    late Map<String, dynamic> jsonBook;

    setUpAll(() {
      final file = File('macos/Runner/help_book.json');
      expect(
        file.existsSync(),
        isTrue,
        reason: 'help_book.json must exist in macos/Runner/',
      );
      jsonBook = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    });

    test('book header contains title and version', () {
      expect(jsonBook['title'], equals('Magic Git User Guide'));
      expect(jsonBook['version'], equals('2.0'));
    });

    test('categories follow the 0010 information architecture', () {
      final categoryIds = (jsonBook['categories'] as List<dynamic>)
          .map((c) => (c as Map<String, dynamic>)['id'] as String)
          .toList();
      expect(categoryIds, [
        'getting_started',
        'workspace',
        'panels',
        'files',
        'commands',
        'safety',
      ]);
      expect(categoryIds, isNot(contains('tabs')));
      expect(categoryIds, isNot(contains('features')));
      expect(categoryIds, isNot(contains('troubleshooting')));
      final book = File('macos/Runner/help_book.json').readAsStringSync();
      expect(book, isNot(contains('Main Application Tabs')));
    });

    test('every locked topic id exists in its category, in order', () {
      const expected = <String, List<String>>{
        'getting_started': [
          'overview',
          'quickstart',
          'clone_create',
          'tabs_workspaces',
        ],
        'workspace': [
          'workspace_chrome',
          'file_view_and_output',
          'dashboard_recovery_activity',
          'settings',
        ],
        'panels': [
          'tab_repository',
          'tab_history',
          'tab_branches',
          'tab_stashes',
          'tab_forge',
          'tab_worktrees',
        ],
        'files': [
          'viewer_and_remote_edit',
          'diffs_blame_history',
          'drag_and_drop',
          'secondary_windows',
        ],
        'commands': ['feature_palette', 'menus_and_keymap'],
        'safety': ['feature_ssh', 'undo_recovery', 'tool_health', 'output_log'],
      };
      for (final cat in jsonBook['categories'] as List<dynamic>) {
        final category = cat as Map<String, dynamic>;
        final ids = (category['topics'] as List<dynamic>)
            .map((t) => (t as Map<String, dynamic>)['id'] as String)
            .toList();
        expect(
          ids,
          expected[category['id'] as String],
          reason: 'topic order in ${category['id']}',
        );
      }
    });

    test('all topics have required fields and non-empty sections', () {
      for (final cat in jsonBook['categories'] as List<dynamic>) {
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
          expect(topic['keywords'] as List<dynamic>, isNotEmpty);
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

    test('Help does not teach the 0010 HIGH lies', () {
      final book = File('macos/Runner/help_book.json').readAsStringSync();
      const forbidden = [
        'rewrite HEAD',
        'optionally include untracked',
        'Open, Merged, Closed, Mine',
        'Sync / Fetch Remotes',
        'drop the folder',
        "new remote host or if a server's fingerprint",
      ];
      for (final phrase in forbidden) {
        expect(book, isNot(contains(phrase)), reason: phrase);
      }
      expect(
        _topicBlob(jsonBook, 'tab_worktrees'),
        isNot(contains('multi-tab workspace')),
      );
    });

    test('keyboard shortcuts are properly structured when present', () {
      var shortcutCount = 0;
      for (final shortcut in _allShortcuts(jsonBook)) {
        expect(shortcut['label'], isNotEmpty);
        expect(shortcut['keys'], isNotEmpty);
        shortcutCount++;
      }
      expect(shortcutCount, greaterThan(0));
    });

    test('⌘⇧B in Help only ever means checkout', () {
      final checkout = kKeymapActions.firstWhere(
        (a) => a.id == 'history.checkout',
      );
      final binding = checkout.defaultBindings.single;
      expect(binding.meta, isTrue);
      expect(binding.shift, isTrue);
      expect(binding.keyId, LogicalKeyboardKey.keyB.keyId);

      var checked = 0;
      for (final shortcut in _allShortcuts(jsonBook)) {
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
                '⌘⇧B is bound to history.checkout — Help must not teach it '
                'as "${shortcut['label']}"',
          );
        }
      }
      expect(checked, greaterThan(0));
    });

    test('every shortcut chip binds a keymap actionId and verb', () {
      const stopWords = {
        'the',
        'a',
        'an',
        'to',
        'of',
        'in',
        'on',
        'for',
        'and',
        'or',
        'view',
        'sheet',
        'panel',
        'selected',
        'all',
        'with',
        'file',
        'files',
        'log',
        'state',
        'last',
        'working',
      };
      const overrides = <String, String>{
        'global.openSettings': 'settings',
        'global.showShortcuts': 'shortcut',
        'global.toggleOutput': 'output',
        'global.toggleFileView': 'file view',
        'global.toggleDashboard': 'dashboard',
        'global.toggleRecovery': 'recovery',
        'commit.confirm': 'commit',
        'repository.forcePush': 'lease',
      };
      String firstVerb(String label) => label
          .toLowerCase()
          .split(RegExp('[^a-z]+'))
          .firstWhere((w) => w.isNotEmpty && !stopWords.contains(w));

      for (final shortcut in _allShortcuts(jsonBook)) {
        final actionId = shortcut['actionId'] as String?;
        expect(
          actionId,
          isNotNull,
          reason: 'chip "${shortcut['label']}" is missing actionId',
        );
        expect(kKeymapActionsById.containsKey(actionId), isTrue);
        final action = kKeymapActionsById[actionId!]!;
        expect(action.defaultBindings, isNotEmpty, reason: actionId);
        expect(
          _chordEquals(
            _parseChord(shortcut['keys'] as String),
            action.defaultBindings.first,
          ),
          isTrue,
          reason:
              '$actionId keys ${shortcut['keys']} ≠ '
              '${action.defaultBindings.first.label}',
        );
        final helpLabel = (shortcut['label'] as String).toLowerCase();
        final required = overrides[actionId] ?? firstVerb(action.label);
        expect(
          helpLabel,
          contains(required),
          reason:
              '$actionId label "${shortcut['label']}" must contain "$required"',
        );
      }
    });

    test('menus_and_keymap catalogs every default-bound keymap action', () {
      final catalog = _topicById(jsonBook, 'menus_and_keymap');
      final ids = {
        for (final sc in catalog['shortcuts'] as List<dynamic>)
          (sc as Map<String, dynamic>)['actionId'] as String,
      };
      for (final action in kKeymapActions) {
        if (action.defaultBindings.isEmpty) continue;
        expect(
          ids,
          contains(action.id),
          reason: '${action.id} missing from menus_and_keymap',
        );
      }
    });

    test('required facts appear in their topics', () {
      const required = <String, List<String>>{
        'overview': [
          'six sidebar panels',
          'File tabs',
          '⌘?',
          '⌘/',
          'factory-default',
          'Keyboard Mappings',
        ],
        'quickstart': [
          'Connections Manager',
          'Recent Repositories',
          'Add existing repository',
          'password',
          'Connection interrupted',
          'Stop Retrying',
          'Connection lost',
          'Start Fresh',
        ],
        'clone_create': [
          'Clone repository',
          'Create repository',
          'Destination',
          'Review',
          'partial folder',
        ],
        'tabs_workspaces': [
          '⌘T',
          'Close Tab',
          '⌘W',
          '8',
          'Saved Workspaces',
          'uncommitted',
          'conflicts',
        ],
        'workspace_chrome': [
          '720',
          '1200',
          'Fetch',
          'Pull',
          'Push',
          'Sync',
          'Review',
          'Commit',
          'Investigate',
          'Minimal',
        ],
        'file_view_and_output': ['1200', 'Pin', 'Output'],
        'dashboard_recovery_activity': [
          'Dashboard',
          'Recovery',
          'reflog',
          'Activity',
        ],
        'settings': [
          'Command timeouts',
          '--no-gpg-sign',
          'Fast-forward only',
          'Auto-fetch',
          'Known Hosts',
          'Keyboard Mappings',
          'Comfortable',
        ],
        'tab_repository': [
          'Conflicts',
          'Staged',
          'Untracked',
          'Hide reviewed',
          'Mark Resolved',
          'task dock',
          'Amend Last Commit',
          'Abort',
        ],
        'tab_history': [
          'author:',
          'file:',
          'Hide merges',
          'Reset',
          'minimap',
          'filter bar',
        ],
        'tab_branches': [
          'Browse',
          'Review',
          'Fetch & Prune',
          'New worktree',
          'Publish',
        ],
        'tab_stashes': [
          '--include-untracked',
          'Stash with Message',
          '--index',
          'Clear all',
        ],
        'tab_forge': [
          'Inbox',
          'Browse',
          'merge readiness',
          'New Issue',
          'auto-merge',
        ],
        'tab_worktrees': [
          'Overview',
          'Changes',
          'nested',
          'Lock',
          'Prune',
          'security-scoped',
        ],
        'viewer_and_remote_edit': [
          'Code',
          'Preview',
          'Open in Default App',
          'temp',
        ],
        'diffs_blame_history': ['blame', '--follow', 'LFS', 'gitignore'],
        'drag_and_drop': ['Esc', 'cherry-pick', 'Stage', 'Unstage'],
        'secondary_windows': ['detached', 'pop-out', 'key equivalent'],
        'feature_palette': [
          'go:',
          'git:',
          'forge:',
          'app:',
          'branch:',
          'commit:',
          'file:',
          'stash:',
          'worktree:',
        ],
        'menus_and_keymap': [
          'factory-default',
          '⌘?',
          '⌘/',
          'File',
          'Repository',
          'Branch',
          'Stash',
          'Forge',
          'Worktree',
        ],
        'feature_ssh': ['TOFU', 'Host Key Changed', 'local', 'password'],
        'undo_recovery': ['Undo Git Operation', 'Nothing to redo', 'staging'],
        'tool_health': [
          'live connection',
          'Scan environment',
          'sideload',
          'essential',
        ],
      };
      for (final MapEntry(key: id, value: phrases) in required.entries) {
        final text = _topicBlob(jsonBook, id);
        for (final phrase in phrases) {
          expect(
            text,
            contains(phrase),
            reason: 'topic $id must contain "$phrase"',
          );
        }
      }

      final fileView = _topicBlob(jsonBook, 'file_view_and_output');
      expect(fileView.contains('⇧⌘E') || fileView.contains('⌘⇧E'), isTrue);
      expect(fileView.contains('⇧⌘O') || fileView.contains('⌘⇧O'), isTrue);
      final dashboard = _topicBlob(jsonBook, 'dashboard_recovery_activity');
      expect(dashboard.contains('⇧⌘D') || dashboard.contains('⌘⇧D'), isTrue);
      final secondary = _topicBlob(jsonBook, 'secondary_windows');
      expect(secondary.contains('⇧⌘H') || secondary.contains('⌘⇧H'), isTrue);
    });

    test('0010 OUT seams are not taught as working', () {
      final book = File('macos/Runner/help_book.json').readAsStringSync();
      expect(book, isNot(contains('issue:')));
      expect(book, isNot(contains('request:')));
      expect(book, isNot(contains('ci:')));
      expect(book.toLowerCase(), isNot(contains('hybrid title bar')));
      expect(book.toLowerCase(), isNot(contains('native title bar')));
      expect(
        _topicBlob(jsonBook, 'tab_worktrees'),
        isNot(contains('multi-tab workspace')),
      );
      expect(book.toLowerCase(), isNot(contains('on startup')));

      for (final cat in jsonBook['categories'] as List<dynamic>) {
        for (final top in (cat as Map<String, dynamic>)['topics'] as List) {
          final topic = top as Map<String, dynamic>;
          final text = jsonEncode(topic);
          final mentionsInspector =
              text.contains('Focus Inspector') ||
              text.toLowerCase().contains('inspector pane');
          if (mentionsInspector) {
            expect(
              text.contains('not populated') || text.contains('unused'),
              isTrue,
              reason: '${topic['id']} mentions inspector without unused',
            );
          }
        }
      }
    });
  });
}
