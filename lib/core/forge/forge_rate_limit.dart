/// Recognizing a forge's "you are being rate limited" answer.
///
/// Both forges report it in a way that is easy to mistake for an ordinary
/// failure: GitHub answers **403** (not 429) for its primary rate limit and
/// puts the explanation in the body/stderr, while GitLab answers 429. Without
/// this, a burst — page-walking jobs, pipelines and MRs on a repo switch — came
/// back as a bare `GhException`/`GlabException` indistinguishable from a broken
/// remote or a bad token, so the one useful instruction ("wait, then retry")
/// was exactly the one the user never got (0022 M9).
///
/// Detection only. No retry or backoff is attempted: automatically re-issuing
/// requests against a limiter is how a short throttle becomes a long one, and
/// choosing a policy is a design decision, not a bug fix.
library;

/// Phrases both CLIs use when relaying a limiter's response. Matched
/// case-insensitively against stderr/body.
const _rateLimitPhrases = <String>[
  'rate limit',
  'rate-limit',
  'ratelimit',
  'secondary rate limit',
  'too many requests',
  'retry-after',
];

/// Whether [status] and/or [output] indicate a rate limit rather than an
/// ordinary failure.
///
/// A 429 is unambiguous. A 403 is only a rate limit when the text says so —
/// GitHub uses 403 for genuine permission failures too, and reporting "rate
/// limited" for a missing scope would send the user to wait out a problem that
/// waiting cannot fix.
bool isForgeRateLimited({int? status, String output = ''}) {
  if (status == 429) return true;
  final lower = output.toLowerCase();
  final mentionsLimit = _rateLimitPhrases.any(lower.contains);
  if (status == 403 && mentionsLimit) return true;
  // No status to go on (a CLI that only printed to stderr): trust the text.
  return status == null && mentionsLimit;
}

/// The message to show for a rate-limited call, including the wait hint when
/// the response carried one.
String forgeRateLimitMessage(String label, {String output = ''}) {
  final seconds = retryAfterSeconds(output);
  final wait = seconds == null ? '' : ' Try again in ${_humanize(seconds)}.';
  return '$label was rate limited by the forge.$wait';
}

/// Seconds from a `Retry-After: <n>` header, when present. Only the numeric
/// form is read; the HTTP-date form is deliberately ignored rather than parsed
/// approximately, since a wrong number here is worse than none.
int? retryAfterSeconds(String output) {
  final match = RegExp(
    r'retry-after:\s*(\d+)',
    caseSensitive: false,
  ).firstMatch(output);
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

String _humanize(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final minutes = (seconds / 60).ceil();
  return minutes == 1 ? 'about a minute' : 'about $minutes minutes';
}
