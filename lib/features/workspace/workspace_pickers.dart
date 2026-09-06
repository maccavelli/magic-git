/// The two "choose a directory" gestures the clone and create sheets share:
/// the native macOS folder panel, and the remote host's directory browser.
///
/// Standalone functions rather than sheet methods or a mixin, following
/// `workspace_registration.dart` — there is exactly one implementation to
/// reason about, and neither sheet inherits anything from the other. Each
/// returns the chosen path and nothing else; the caller owns its own
/// `setState`, its "picker in flight" flag, and what it does with the result,
/// because those differ between the sheets and between the two create-sheet
/// call sites.
library;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/widgets.dart';
import 'package:macos_ui/macos_ui.dart';

import '../common/escape_dismissible.dart';
import 'remote_directory_browser.dart';

/// Opens the native folder panel. Null means the user cancelled **or** no
/// picker was available — under `flutter test`, or a transient platform
/// failure. Both cases mean "keep whatever you had", so callers treat them
/// identically and there is nothing for them to catch.
Future<String?> pickLocalDirectory() async {
  try {
    return await getDirectoryPath(confirmButtonText: 'Choose');
  } catch (_) {
    return null;
  }
}

/// Browses the provisioned host's filesystem. Null means the user dismissed
/// the browser without choosing.
///
/// The caller must have provisioned the session first ([ensureProvisioned]);
/// this only presents the sheet. An empty [initialPath] is normalised to null
/// so the browser starts at its own default rather than at "".
Future<String?> browseRemoteDirectory(
  BuildContext context, {
  String? initialPath,
}) {
  final start = initialPath?.trim() ?? '';
  return showMacosSheet<String>(
    context: context,
    builder: (_) => EscapeDismissible(
      child: RemoteDirectoryBrowserSheet(
        initialPath: start.isEmpty ? null : start,
      ),
    ),
  );
}
