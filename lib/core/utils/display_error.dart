import '../git/git_service.dart';
import '../github/gh_service.dart';
import '../gitlab/glab_service.dart';
import '../ssh/ssh_command_executor.dart';
import '../ssh/ssh_error_messages.dart';

/// The one mapping from a thrown error to the text a user reads in an error
/// dialog or inline error state. Every user-facing error surface routes
/// through here; the output log keeps raw `toString()` detail instead.
///
/// The app's own CLI exceptions ([GitException], [GhException],
/// [GlabException]) carry a curated message plus the failing command's
/// stderr. Their `toString` is a debug string ("GitException: … (exit 128)"),
/// so this strips the class/exit noise and shows the message with the stderr
/// beneath it — stderr is the CLI's own explanation and usually the most
/// useful text on screen. Everything else goes through [humanizeSshError],
/// which maps transport failures to short actionable copy and strips
/// "Exception: " prefixes as a last resort.
String displayError(Object error) {
  if (error is GitException) return _cliFailure(error.message, error.result);
  if (error is GhException) return _cliFailure(error.message, error.result);
  if (error is GlabException) return _cliFailure(error.message, error.result);
  return humanizeSshError(error);
}

/// Heuristic: does a CLI / transport failure read like missing or expired
/// credentials? Matches the phrasings gh/glab actually emit (HTTP 401, "Bad
/// credentials", "not logged in", "To get started with GitLab CLI, please run:
/// glab auth login") and git's HTTPS helper refusals when
/// `GIT_TERMINAL_PROMPT=0` (`could not read Username`, `terminal prompts
/// disabled`) rather than exit codes — glab's exit codes are advisory.
///
/// Used to keep connect-time "not logged in" failures off the Repository
/// panel and file-view pane while the session's background forge login is
/// still in flight.
bool looksLikeAuthFailure(Object error) {
  final text = displayError(error).toLowerCase();
  return text.contains('401') ||
      text.contains('bad credentials') ||
      text.contains('unauthorized') ||
      text.contains('authentication') ||
      text.contains('auth login') ||
      text.contains('not logged in') ||
      text.contains('could not read username') ||
      text.contains('could not read password') ||
      text.contains('terminal prompts disabled');
}

String _cliFailure(String message, SSHCommandResult result) {
  final stderr = result.stderr.trim();
  if (stderr.isEmpty || message.contains(stderr)) return message;
  return '$message\n\n$stderr';
}
