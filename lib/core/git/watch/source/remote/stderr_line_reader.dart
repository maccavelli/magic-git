import '../../../bounded_watch.dart';

/// One meaningful thing a watcher said on stderr.
sealed class StderrLine {
  const StderrLine();
}

/// The watcher took its claim and started: the arm succeeded (MADR 0044).
final class ReadinessMarker extends StderrLine {
  const ReadinessMarker();
}

/// A lock refusal named the watcher that holds the repository.
final class LockHeldBy extends StderrLine {
  const LockHeldBy(this.token);
  final String token;
}

/// A line worth showing the user, within the per-arm budget.
final class Diagnostic extends StderrLine {
  const Diagnostic(this.line);
  final String line;
}

final _lockHeldBy = RegExp(r'mg-watch: lock held by (\S+)');

/// Reads a watcher's stderr into [StderrLine]s.
///
/// Pure: it decides what each line means and leaves what to do about it to the
/// arm — completing the readiness race, remembering the incumbent, logging.
///
/// Three rules it keeps:
///
/// * **only the exact marker** settles an arm. Any line would have armed on
///   inotifywait's own startup chatter and silently disabled the exclusion the
///   lock exists for;
/// * **startup chatter is dropped** by prefix. `Setting up watches` and
///   `Watches established` arrive on every arm and used to spend two of the
///   diagnostic budget right where a real message lands (MADR 0041 F8). A
///   prefix list cannot swallow a message nobody has seen yet;
/// * **a refusal line is both** an incumbent and a diagnostic — the user should
///   see who holds the repository.
final class StderrLineReader {
  StderrLineReader({
    required this.maxDiagnosticLines,
    required this.maxBufferChars,
  });

  /// Diagnostics forwarded per arm; later ones are dropped.
  final int maxDiagnosticLines;

  /// Past this, an unterminated line is dropped rather than buffered.
  final int maxBufferChars;

  var _buffer = '';
  var _diagnostics = 0;

  /// Lines inotifywait prints on every arm, which say nothing about this one.
  static bool isStartupNoise(String line) =>
      line.startsWith('Setting up watches') ||
      line.startsWith('Watches established');

  /// Adds [chunk] and returns what its complete lines said, in order.
  List<StderrLine> add(String chunk) {
    _buffer += chunk;
    final out = <StderrLine>[];
    var start = 0;
    var i = _buffer.indexOf('\n', start);
    while (i >= 0) {
      final line = _buffer.substring(start, i).trim();
      start = i + 1;
      if (line == watchArmedMarker) {
        out.add(const ReadinessMarker());
      } else {
        final held = _lockHeldBy.firstMatch(line);
        if (held != null) out.add(LockHeldBy(held[1]!));
        if (line.isNotEmpty &&
            !isStartupNoise(line) &&
            _diagnostics < maxDiagnosticLines) {
          _diagnostics++;
          out.add(Diagnostic(line));
        }
      }
      i = _buffer.indexOf('\n', start);
    }
    if (start > 0) _buffer = _buffer.substring(start);
    if (_buffer.length > maxBufferChars) _buffer = '';
    return out;
  }
}
