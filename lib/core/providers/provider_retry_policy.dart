/// The app's provider retry policy: never retry a failed provider.
///
/// Riverpod 3 retries by default (exponential backoff to ~6s). Magic Git's
/// provider failures are overwhelmingly deterministic — a bad path, a
/// signed-out CLI, an HTTP 4xx — so a retry only delays the error the user
/// needs to see. Manual refresh and the remote watcher already re-drive on
/// demand.
///
/// This is not merely a UX preference. Under the default policy a failed provider stays in `AsyncLoading` for
/// **~38 s** (10 retries, exponential 200 ms doubling capped at 6.4 s) before
/// it finally emits `AsyncError` — far longer than any widget test can pump,
/// so in practice the error branch is unreachable. The retry-pending state is
/// an `AsyncLoading` carrying the prior error, so `isReloading` is true and
/// `AsyncValue.when` (whose `skipLoadingOnReload` defaults to false) renders
/// `loading` throughout. `Error` subtypes and `ProviderException` are exempt
/// from retry and surface immediately; the app's own `GitException` /
/// `GhException` / `GlabException` all implement `Exception`, so the failures
/// that matter are exactly the retried ones.
///
/// Every async provider declares this itself (0017), so the policy travels
/// with the provider and survives `overrideWith` — a bare `ProviderScope` in
/// a test resolves failures exactly as the app does. The three production
/// scopes pass it too, as a backstop for anything unannotated.
/// `test/provider_retry_policy_test.dart` pins all of it.
///
/// Signature matches riverpod's `Retry` typedef, which the package declares
/// (`src/core/provider_container.dart`) but does not export.
Duration? noProviderRetry(int retryCount, Object error) => null;
