/// The app's provider retry policy: never retry a failed provider.
///
/// Riverpod 3 retries by default (exponential backoff to ~6s). Magic Git's
/// provider failures are overwhelmingly deterministic — a bad path, a
/// signed-out CLI, an HTTP 4xx — so a retry only delays the error the user
/// needs to see. Manual refresh and the remote watcher already re-drive on
/// demand.
///
/// This is not merely a UX preference. Under the default policy a failed
/// provider never emits `AsyncError` at all: the retry-pending state is an
/// `AsyncLoading` carrying the prior error, so `isReloading` is true and
/// `AsyncValue.when` — whose `skipLoadingOnReload` defaults to false —
/// renders its `loading` branch indefinitely. Every scope the app creates
/// must use this, and so must any test that expects to reach an error
/// branch; see `test/helpers/app_scope.dart` and
/// `test/provider_retry_policy_test.dart`, which pin both halves of that.
///
/// Signature matches riverpod's `Retry` typedef, which the package declares
/// (`src/core/provider_container.dart`) but does not export.
Duration? noProviderRetry(int retryCount, Object error) => null;
