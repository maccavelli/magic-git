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
/// `CommandTelemetry.instance` / `WindowBoundsStore` — reached statically, no
/// Riverpod wiring.
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
