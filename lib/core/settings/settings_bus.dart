import 'dart:async';

/// Process-global broadcaster that keeps [AppSettingsNotifier] and
/// [KeymapNotifier] coherent across the app's per-tab [ProviderContainer]s.
///
/// A Riverpod `Notifier` instance is bound to exactly one container, so tabs
/// (each its own root container) get their own settings/keymap notifiers. To
/// keep them in sync, every write announces itself here and every notifier
/// reloads from disk in response — the same disk-broadcast contract the History
/// window already uses across isolates ([AppSettingsNotifier.reloadFromDisk]),
/// now fired in-process too. It is a plain singleton in the same category as
/// `WindowBoundsStore` — reached statically, no Riverpod wiring. Unlike
/// `CommandTelemetry`, which used to sit in this category and no longer does
/// (MADR 0039 F5), a singleton is *right* here: the whole point is to reach
/// every container at once, where telemetry's job was to describe exactly one.
///
/// Echo-termination: only a *write* announces; a reload applies a value-equal
/// state and so triggers no further write, so there is no ping-pong.
class SettingsBus {
  SettingsBus._();
  static final SettingsBus instance = SettingsBus._();

  final _settings = StreamController<void>.broadcast();
  final _keymap = StreamController<void>.broadcast();

  /// Fires after any container persists an app-settings change.
  Stream<void> get onSettingsWritten => _settings.stream;

  /// Fires after any container persists a keymap change.
  Stream<void> get onKeymapWritten => _keymap.stream;

  void notifySettingsWritten() => _settings.add(null);
  void notifyKeymapWritten() => _keymap.add(null);
}
