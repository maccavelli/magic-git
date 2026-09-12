import 'dart:convert';
import 'dart:io';

/// Identity of a chosen macOS application: what launches it, and what to show.
///
/// MADR 0048 stores the identifier rather than a name or a path, because
/// `open -b` resolves it through Launch Services — so the choice survives the
/// application being moved, renamed or reinstalled, where
/// `open -a 'Visual Studio Code'` did not.
class AppBundle {
  const AppBundle({required this.bundleId, required this.name});

  /// `CFBundleIdentifier`, the only thing a launch uses.
  final String bundleId;

  /// What the Settings row shows, and nothing else. A display name is not an
  /// identity: the editor shown as "Cursor" is `com.todesktop.230313mzl4w4u92`.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is AppBundle && other.bundleId == bundleId && other.name == name;

  @override
  int get hashCode => Object.hash(bundleId, name);

  @override
  String toString() => 'AppBundle($name, $bundleId)';
}

final _identifier = RegExp(
  r'<key>\s*CFBundleIdentifier\s*</key>\s*<string>([^<]*)</string>',
);
final _declaredName = RegExp(
  r'<key>\s*CFBundleName\s*</key>\s*<string>([^<]*)</string>',
);

/// Reads `<appPath>/Contents/Info.plist` and returns the application's
/// identity, or null when [appPath] is not an application bundle, its
/// `Info.plist` cannot be read, or it carries no `CFBundleIdentifier`.
///
/// **Refusing is the point.** A pick stored without an identifier could only be
/// launched by path or by name, which is precisely the failure MADR 0048 exists
/// to remove; and a wrong identifier fails later, at launch, where the user
/// cannot see why. The caller reports the refusal and stores nothing.
///
/// A **binary** plist is refused rather than guessed at: decoding one needs a
/// plist parser, and every application shipping today writes XML here.
AppBundle? readAppBundle(String appPath) {
  final plist = File('$appPath/Contents/Info.plist');
  if (!plist.existsSync()) return null;
  final bytes = plist.readAsBytesSync();
  if (bytes.length >= 8 && String.fromCharCodes(bytes.take(8)) == 'bplist00') {
    return null;
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  final id = _identifier.firstMatch(text)?.group(1)?.trim() ?? '';
  if (id.isEmpty) return null;
  final declared = _declaredName.firstMatch(text)?.group(1)?.trim() ?? '';
  return AppBundle(
    bundleId: id,
    name: declared.isEmpty ? _nameFromPath(appPath) : declared,
  );
}

/// The bundle's own directory name, minus `.app` — the fallback when the plist
/// declares no `CFBundleName`, which is common.
String _nameFromPath(String appPath) {
  final parts = appPath.split('/')..removeWhere((s) => s.isEmpty);
  final base = parts.isEmpty ? appPath : parts.last;
  return base.endsWith('.app') ? base.substring(0, base.length - 4) : base;
}
