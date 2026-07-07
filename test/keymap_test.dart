// Keyboard-shortcut registry: KeyBinding encode/decode + equality,
// resolveShortcuts()'s null-handler skipping, and KeymapNotifier's
// diff-based persistence, reset, and conflict detection.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/keymap.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('KeyBinding', () {
    test('encode/decode round-trips every flag', () {
      const binding = KeyBinding(
        meta: true,
        shift: true,
        alt: false,
        control: true,
        keyId: 42,
      );
      final decoded = KeyBinding.decode(binding.encode());
      expect(decoded, binding);
    });

    test('equality is structural, not identity', () {
      final a = KeyBinding.fromKey(LogicalKeyboardKey.keyP, meta: true, shift: true);
      final b = KeyBinding.fromKey(LogicalKeyboardKey.keyP, shift: true, meta: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('decode rejects malformed input instead of throwing', () {
      expect(KeyBinding.decode('garbage'), isNull);
      expect(KeyBinding.decode('11:notanumber'), isNull);
    });

    test('label renders macOS modifier glyphs', () {
      final binding = KeyBinding.fromKey(
        LogicalKeyboardKey.keyP,
        meta: true,
        shift: true,
      );
      expect(binding.label, '⇧⌘P');
    });
  });

  group('resolveShortcuts', () {
    test('skips actions with a null handler', () {
      final keymap = {
        'a': [KeyBinding.fromKey(LogicalKeyboardKey.keyA)],
        'b': [KeyBinding.fromKey(LogicalKeyboardKey.keyB)],
      };
      var fired = false;
      final bindings = resolveShortcuts(keymap, {
        'a': () => fired = true,
        'b': null,
      });
      expect(bindings.length, 1);
      bindings.values.single();
      expect(fired, isTrue);
    });

    test('maps every binding for a multi-binding action to the same callback', () {
      final keymap = {
        'a': [
          KeyBinding.fromKey(LogicalKeyboardKey.keyA),
          KeyBinding.fromKey(LogicalKeyboardKey.keyB, meta: true),
        ],
      };
      final bindings = resolveShortcuts(keymap, {'a': () {}});
      expect(bindings.length, 2);
    });
  });

  group('KeymapNotifier', () {
    test('starts at the built-in defaults', () {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final state = c.read(keymapProvider);
      expect(state['global.refresh'], [
        KeyBinding.fromKey(LogicalKeyboardKey.keyR, meta: true),
      ]);
    });

    test('setBindings persists only the diff from default', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final custom = KeyBinding.fromKey(LogicalKeyboardKey.keyZ, meta: true);
      await c.read(keymapProvider.notifier).setBindings('global.refresh', [custom]);
      expect(c.read(keymapProvider)['global.refresh'], [custom]);

      // A second, independent container reloading from the same storage picks
      // up the override (asynchronously, like AppSettingsNotifier) and leaves
      // every un-touched action at its default.
      final c2 = ProviderContainer();
      addTearDown(c2.dispose);
      final loaded = Completer<Map<String, List<KeyBinding>>>();
      c2.listen(keymapProvider, (_, next) {
        if (!loaded.isCompleted && listEquals(next['global.refresh'], [custom])) {
          loaded.complete(next);
        }
      });
      c2.read(keymapProvider); // build() kicks the async _load
      final state = await loaded.future.timeout(const Duration(seconds: 2));
      expect(state['global.openSettings'], kKeymapActionsById['global.openSettings']!.defaultBindings);
    });

    test('resetAction restores just that action', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      final defaults = c.read(keymapProvider)['global.refresh'];
      await c.read(keymapProvider.notifier).setBindings(
        'global.refresh',
        [KeyBinding.fromKey(LogicalKeyboardKey.keyZ, meta: true)],
      );
      await c.read(keymapProvider.notifier).resetAction('global.refresh');
      expect(c.read(keymapProvider)['global.refresh'], defaults);
    });

    test('resetAll restores every action', () async {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);

      await c.read(keymapProvider.notifier).setBindings(
        'global.refresh',
        [KeyBinding.fromKey(LogicalKeyboardKey.keyZ, meta: true)],
      );
      await c.read(keymapProvider.notifier).setBindings(
        'repository.fetch',
        [KeyBinding.fromKey(LogicalKeyboardKey.keyY, meta: true)],
      );
      await c.read(keymapProvider.notifier).resetAll();

      final state = c.read(keymapProvider);
      for (final action in kKeymapActions) {
        expect(state[action.id], action.defaultBindings);
      }
    });

    test(
      'a single malformed override entry does not discard the others',
      () async {
        final custom = KeyBinding.fromKey(LogicalKeyboardKey.keyZ, meta: true);
        SharedPreferences.setMockInitialValues({
          'keymapOverrides': jsonEncode({
            'global.refresh': [custom.encode()],
            'repository.fetch': 123, // malformed: not a list of encoded strings
          }),
        });
        final c = ProviderContainer();
        addTearDown(c.dispose);

        final loaded = Completer<Map<String, List<KeyBinding>>>();
        c.listen(keymapProvider, (_, next) {
          if (!loaded.isCompleted &&
              listEquals(next['global.refresh'], [custom])) {
            loaded.complete(next);
          }
        });
        c.read(keymapProvider); // build() kicks the async _load

        final state = await loaded.future.timeout(const Duration(seconds: 2));
        // The valid override applied…
        expect(state['global.refresh'], [custom]);
        // …and the malformed one fell back to its own default rather than
        // wiping out *every* customization (the pre-fix behavior).
        expect(
          state['repository.fetch'],
          kKeymapActionsById['repository.fetch']!.defaultBindings,
        );
      },
    );

    test(
      'a user edit before _load resolves is not clobbered by stored overrides',
      () async {
        final stored = KeyBinding.fromKey(LogicalKeyboardKey.keyY, meta: true);
        final userChoice = KeyBinding.fromKey(
          LogicalKeyboardKey.keyZ,
          meta: true,
        );
        SharedPreferences.setMockInitialValues({
          'keymapOverrides': jsonEncode({
            'global.refresh': [stored.encode()],
          }),
        });
        final c = ProviderContainer();
        addTearDown(c.dispose);

        // Kick build()/_load, then immediately set a different binding before
        // the async load can apply the stored override.
        c.read(keymapProvider);
        await c
            .read(keymapProvider.notifier)
            .setBindings('global.refresh', [userChoice]);

        // Give _load room to (wrongly) fire; the user's edit must win.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(c.read(keymapProvider)['global.refresh'], [userChoice]);
      },
    );

    test('conflictsFor finds another action sharing a binding in an overlapping scope', () {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(keymapProvider.notifier);

      // 'repository.fetch' and 'global.refresh' both currently use distinct
      // defaults; point fetch's binding at refresh's to create a conflict.
      final refreshBinding = c.read(keymapProvider)['global.refresh']!.single;
      final conflicts = notifier.conflictsFor('repository.fetch', refreshBinding);
      expect(conflicts.map((a) => a.id), contains('global.refresh'));
    });

    test('no shipped default binding conflicts within an overlapping scope', () {
      // Guards every default in kKeymapActions (not just the ones added in a
      // given change): if two actions in the same category — or any action and
      // a global one — share a default binding, conflictsFor surfaces it, and
      // this fails with the offending pair. Runs against the pristine default
      // keymap, so it's a pure check of the shipped defaults.
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(keymapProvider.notifier);
      for (final action in kKeymapActions) {
        for (final binding in action.defaultBindings) {
          final conflicts = notifier.conflictsFor(action.id, binding);
          expect(
            conflicts,
            isEmpty,
            reason:
                '${action.id} default ${binding.label} collides with '
                '${conflicts.map((a) => a.id).join(', ')}',
          );
        }
      }
    });

    test('every action id is unique', () {
      final ids = kKeymapActions.map((a) => a.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('the expanded action set ships the expected new defaults', () {
      KeyBinding only(String id) => kKeymapActionsById[id]!.defaultBindings.single;
      expect(
        only('global.showShortcuts'),
        KeyBinding.fromKey(LogicalKeyboardKey.slash, meta: true),
      );
      expect(
        only('repository.sync'),
        KeyBinding.fromKey(LogicalKeyboardKey.keyY, meta: true, shift: true),
      );
      expect(
        only('repository.forcePush'),
        KeyBinding.fromKey(LogicalKeyboardKey.keyU, meta: true, control: true),
      );
      expect(
        only('history.copySha'),
        KeyBinding.fromKey(LogicalKeyboardKey.keyC, meta: true),
      );
      expect(
        only('stashes.drop'),
        KeyBinding.fromKey(LogicalKeyboardKey.backspace, meta: true),
      );
      expect(
        only('gitlab.merge'),
        KeyBinding.fromKey(LogicalKeyboardKey.keyM, meta: true, shift: true),
      );
      expect(
        only('viewer.wordWrap'),
        KeyBinding.fromKey(LogicalKeyboardKey.keyZ, alt: true),
      );
      // The new categories are represented so the mappings/cheat-sheet sheets
      // render a section for each.
      final categories = kKeymapActions.map((a) => a.category).toSet();
      expect(
        categories.containsAll([
          KeymapCategory.history,
          KeymapCategory.stashes,
          KeymapCategory.gitlab,
          KeymapCategory.viewer,
        ]),
        isTrue,
      );
    });

    test('conflictsFor ignores non-overlapping scopes', () {
      SharedPreferences.setMockInitialValues({});
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final notifier = c.read(keymapProvider.notifier);

      // 'branches.newBranch' and 'commit.confirm' are both non-global and in
      // different categories, so a shared binding between them isn't a
      // conflict.
      final branchBinding = c.read(keymapProvider)['branches.newBranch']!.single;
      final conflicts = notifier.conflictsFor('commit.confirm', branchBinding);
      expect(conflicts, isEmpty);
    });
  });
}
