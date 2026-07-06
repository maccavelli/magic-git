import 'package:flutter/services.dart';

/// Thin wrapper over the `magicgit/bookmarks` native channel
/// (`macos/Runner/MainFlutterWindow.swift`), which manages macOS
/// security-scoped bookmarks so a local repo folder — picked once through a
/// system panel, the only way to gain a sandbox grant for it at all — can be
/// reopened on a later app launch without re-prompting.
///
/// [startAccessing]/[stopAccessing] must bracket the *entire* time a repo's
/// commands may run, not wrap each individual command: a spawned `git`/`glab`
/// child process only inherits the sandbox grant while it's held open.
class SecurityScopedBookmark {
  static const _channel = MethodChannel('magicgit/bookmarks');

  /// Creates a bookmark for [path] (must already be sandbox-accessible —
  /// i.e. just picked through a system panel, or already under active
  /// access via [startAccessing]). Returns base64-encoded bookmark data to
  /// persist, or null if bookmark creation failed (e.g. non-macOS platform,
  /// or the path isn't actually sandbox-accessible).
  static Future<String?> create(String path) async {
    try {
      return await _channel.invokeMethod<String>('createBookmark', path);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Resolves [bookmarkData] (as returned by [create]) and starts security-
  /// scoped access, returning the resolved absolute path — which may differ
  /// from the path originally bookmarked if the folder was moved/renamed
  /// since. Returns null if resolution or access failed (e.g. the folder was
  /// deleted, or access was revoked) — the caller should fall back to
  /// re-prompting via the folder picker.
  static Future<String?> startAccessing(String bookmarkData) async {
    try {
      return await _channel.invokeMethod<String>(
        'startAccessingBookmark',
        bookmarkData,
      );
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Ends security-scoped access to [path] (as returned by [startAccessing]).
  /// Safe to call even if access was never started (a no-op on the native
  /// side).
  static Future<void> stopAccessing(String path) async {
    try {
      await _channel.invokeMethod<void>('stopAccessingBookmark', path);
    } on PlatformException {
      // Best-effort — nothing more to do if the native side rejects this.
    } on MissingPluginException {
      // Non-macOS platform, or running under `flutter test` with no plugin
      // registered.
    }
  }
}
