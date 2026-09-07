/// Routes provider failures to the app's own output log (MADR 0034 F1).
///
/// Three mechanisms used to combine into silence. Riverpod's automatic retry is
/// off by design — every async provider declares `retry: noProviderRetry`, so a
/// failure lands in `AsyncError` and stays there. Most UI reads it through
/// `.value ?? const []`, which renders an error as "you have nothing". And
/// nothing observed the failure: the **pop-out window** was the only scope in
/// the app with a `ProviderObserver`, so a store read that threw in the main
/// window produced no retry, no log line and no UI.
///
/// This is the missing third leg. It is deliberately not a fix to the ~49
/// `.value ?? const []` sites: collapsing a *loading* store to an empty list is
/// usually the right call (the create wizard must not block on a store), and
/// the defect was that nothing noticed the *error* case.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../output/output_log.dart';

final class ProviderFailureObserver extends ProviderObserver {
  const ProviderFailureObserver();

  @override
  void providerDidFail(
    ProviderObserverContext context,
    Object error,
    StackTrace stackTrace,
  ) {
    final provider = context.provider;
    final name = provider.name ?? provider.runtimeType.toString();
    final argument = provider.argument;
    final label = argument == null ? name : '$name($argument)';
    final container = context.container;

    // Deferred, not synchronous: `providerDidFail` runs DURING a provider
    // lifecycle event, and reading another provider from inside one risks
    // re-entering the container that is currently mid-failure.
    scheduleMicrotask(() {
      try {
        container
            .read(outputLogProvider.notifier)
            .logError('provider', '$label: $error');
      } catch (_) {
        // The one place in this work where swallowing is correct. A logger
        // that throws while handling a failure turns one problem into two, and
        // the second has no observer to catch it. By the time this microtask
        // runs the container may also be disposed — a torn-down tab must not
        // resurrect its log.
      }
    });
  }
}
