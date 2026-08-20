// Provider scopes configured the way the app configures its own.
//
// Since 0017 every async provider declares `retry: noProviderRetry` itself,
// so a bare ProviderScope is no longer a trap: the policy travels with the
// provider and survives overrideWith. These helpers remain the tidy default
// — they apply the policy to anything unannotated, and they keep a test's
// scope matching the app's if more scope configuration is added later.
//
// For the record of what the default policy does, and why the annotation
// matters, see `provider_retry_policy_test.dart`: a failed provider sits in
// AsyncLoading for ~38 s (10 retries) before emitting AsyncError, and
// `when()` renders `loading` throughout.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:remote_magic_git/core/providers/provider_retry_policy.dart';
import 'package:riverpod/misc.dart' show Override;

/// A [ProviderScope] with the app's own policy applied.
ProviderScope appProviderScope({
  List<Override> overrides = const [],
  List<ProviderObserver> observers = const [],
  Key? key,
  required Widget child,
}) => ProviderScope(
  key: key,
  retry: noProviderRetry,
  overrides: overrides,
  observers: observers,
  child: child,
);

/// The [ProviderContainer] equivalent, for tests that read providers directly
/// or drive an [UncontrolledProviderScope].
ProviderContainer appProviderContainer({
  List<Override> overrides = const [],
  List<ProviderObserver> observers = const [],
}) => ProviderContainer(
  retry: noProviderRetry,
  overrides: overrides,
  observers: observers,
);
