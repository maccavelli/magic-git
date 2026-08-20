// Provider scopes configured the way the app configures its own.
//
// A bare ProviderScope/ProviderContainer runs Riverpod in a configuration
// Magic Git never uses: the default retry policy. Under it a failed provider
// never emits AsyncError — the retry-pending state is an AsyncLoading
// carrying the prior error, so `AsyncValue.when` renders `loading`
// indefinitely and every error branch is unreachable. See
// `provider_retry_policy_test.dart`, which pins both halves of that.
//
// Use these in any widget test that expects to reach an error branch, and by
// default in new tests so the harness cannot drift from the app again.

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
