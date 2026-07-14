/// Interprets a probed [RemoteEnvironment] against the [kToolCatalog] — the one
/// layer that knows about both, and the reason the catalog itself stays
/// dependency-free (the probe imports the catalog, so the catalog must not
/// import the probe).
library;

import '../ssh/environment_probe.dart';
import 'tool_catalog.dart';

/// How serious the overall tool situation is, for a one-line summary.
enum ToolHealthLevel { ok, warning, error }

/// A single-line summary of tool health for the current host, shared by the
/// Settings summary line and the main-window banner so both read identically.
class ToolHealthReport {
  final ToolHealthLevel level;
  final String message;
  const ToolHealthReport(this.level, this.message);
}

/// Distills [env] into one actionable line. Order of concern: disconnected →
/// ok (nothing to check yet), a missing required tool → error, a missing
/// feature tool → warning, an outdated tool → warning, else ok. Only relevant
/// tools for the detected OS are considered (a Linux host is never faulted for
/// lacking macOS's fswatch).
ToolHealthReport summarizeToolHealth(RemoteEnvironment env) {
  if (env.os == 'unknown') {
    return const ToolHealthReport(
      ToolHealthLevel.ok,
      'Connect to a repository to check installed tools.',
    );
  }
  final relevant = kToolCatalog.where((t) => t.relevantOn(env.os));
  ToolSpec? missingEssential, missingFeature, outdated;
  for (final spec in relevant) {
    if (!env.has(spec.bin)) {
      if (spec.tier == ToolTier.essential) {
        missingEssential ??= spec;
      } else if (spec.tier == ToolTier.feature) {
        missingFeature ??= spec;
      }
      continue;
    }
    final vStr = env.versionOf(spec.bin);
    final v = vStr == null ? null : ToolVersion.parse(vStr);
    if (spec.minVersion != null && v != null && v < spec.minVersion!) {
      outdated ??= spec;
    }
  }
  if (missingEssential != null) {
    return ToolHealthReport(
      ToolHealthLevel.error,
      '${missingEssential.bin} is not installed — required.',
    );
  }
  if (missingFeature != null) {
    return ToolHealthReport(
      ToolHealthLevel.warning,
      '${missingFeature.bin} is not installed — some features unavailable.',
    );
  }
  if (outdated != null) {
    return ToolHealthReport(
      ToolHealthLevel.warning,
      '${outdated.bin} is out of date.',
    );
  }
  return const ToolHealthReport(ToolHealthLevel.ok, 'All tools detected.');
}
