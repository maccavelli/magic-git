---
status: proposed
date: 2026-08-26
verified: 2026-08-26
approved: 2026-08-26
associated-madr: 0019-MADR-pin-glab-origin-host-on-every-call.md
owner: [Maintainer]
target-milestone: This work cycle
---

# Implement: pin every glab invocation to the repo origin host

Associated MADR:
[0019-MADR-pin-glab-origin-host-on-every-call.md](0019-MADR-pin-glab-origin-host-on-every-call.md)

Stop Forge-tab `glab` calls from falling through to `gitlab.com` (empty
token, HTTP 401, auth-shaped UI) when the repo's origin is a self-hosted
instance. Pin the origin host on every `GlabService` invocation: `GITLAB_HOST`
/ `GITLAB_URI` on subcommands, `--hostname` on `glab api` / GraphQL. Scope
the auth probe to that same host.

A second engineer following only this file, against the tree at `b1c8aa5`,
must produce the same diff.

Approved for execution 2026-08-26.

**Host binary is frozen at glab 1.109.0.** Do not upgrade it as part of this
work. Flag placement below was verified live on `admdevops` against that
binary on 2026-08-26 (see Reassessment).

## Reassessment (2026-08-26)

Maintainer decision: leave `admdevops` on **glab 1.109.0**
(`/home/adm_saxsmith/.local/bin/glab`, `757294c0`). Official 1.110–1.115
notes add artifact-registry, dependency-firewall, Orbit, and (in 1.111)
**keyring-by-default** for `glab auth login`. None of that replaces the
origin pin; 1.111 would change stdin-login storage on a headless SSH
exec. This plan therefore targets 1.109 only.

Live 1.109 checks (env `-i`, no `GITLAB_*`, config token for
`gitlab.example.com`):

| Invocation | Result |
|---|---|
| `glab api --hostname gitlab.example.com user -i` | HTTP 200 |
| `glab api user --hostname gitlab.example.com -i` | HTTP 200 (both positions legal) |
| `glab api --hostname gitlab.example.com graphql -f query=… -i` | HTTP 200 |
| `glab auth status --hostname gitlab.example.com` from `$HOME` | **one** host block, exit 0 |
| `glab mr list --hostname …` | `Unknown flag: --hostname` (exit 0) |

Plan defects this pass removes:

* `test/mutations_test.dart` constructs `GlabService` and pins exact `api`
  argv (`calls.single`) — it was missing from Phase 0 and would fail the
  moment `api()` inserts `--hostname` or shells get-url.
* Phase 2 had two contradictory `graphql` argv snippets and two
  contradictory `extraEnv` expressions.
* Phase 3 left `listIssueComments` / `listMergeRequestNotes` as
  "check at edit time". They are raw `execute(['glab','api',…])`, not
  `api()`.
* Phase 4 would pass a GitHub origin into `glab auth status --hostname`,
  turning the dashboard glab row red on GitHub repos.
* `debugOriginHost` collided with the proposed `debugOriginHostFor`.
* `_runJson` must **not** auto-fill `extraEnv` from origin: `listRepos`
  (`host: 'gitlab.com'`) already passes `hostEnv` which is `null`; an
  auto-fill would pin a self-hosted cwd by accident.

## Goal

**Acceptance criteria**

1. Every repo-scoped `GlabService` method that shells `glab` (Phase 2 / 3
   tables; not create/clone/login which already take explicit `host:`)
   sends `extraEnv: {GITLAB_HOST, GITLAB_URI}` when origin is not
   `gitlab.com`, and sends neither when origin is `gitlab.com` or
   unresolvable.
2. `glab api` and `glab api graphql` argv include `--hostname <origin>`
   immediately after the `api` token when origin is not `gitlab.com`:
   `['glab', 'api', '--hostname', host, <endpoint or graphql>, …]`.
   Subcommands (`mr`, `issue`, `ci`) never get `--hostname`.
3. Page walks resolve origin **once** per public call (the
   `_originHostCache`), not once per page.
4. `AuthProbeService.probe` takes an optional `glabHostname`. The session
   dashboard passes it **only** when `classifyForgeHost(origin) ==
   Forge.gitlab`. Argv is `glab auth status --hostname <origin>`. A mixed
   dump no longer decides the glab row for that repo.
5. GraphQL `project: null` message does not contain `not logged in` or
   `auth login`, so `looksLikeAuthFailure` is false.
6. Existing argv/queue tests stay green via
   `debugOriginHostOverride = 'gitlab.com'` (no `--hostname`, no extra
   get-url). New tests cover the pin without that override.
7. `flutter analyze` exit 0, `dart format` clean on staged files, full
   `flutter test` green. **No `live-forge`.** No glab upgrade.
8. Phase 8 is maintainer verification on `admdevops` / glab 1.109.

## Scope

**In scope**

| # | Work |
|---|---|
| 0 | Test override + helpers so existing argv tests do not consume result queues |
| 1 | `hostnameFlag` + `_originHost` cache |
| 2 | Wire `api()` and `graphql()` |
| 3 | Wire remaining repo-scoped `execute` / `_runJson` / `executeStream`, and `--hostname` on create/clone `glab api` calls that already have `host:` |
| 4 | Origin-scoped `glab auth status --hostname` for GitLab repos only |
| 5 | GraphQL null-project copy |
| 6 | Docs: Architecture §4.1, this plan, MADR freeze note |
| 7 | Full suite |
| 8 | Maintainer live check (not coded) |

**Out of scope** (do not implement)

* Upgrading glab on `admdevops` or anywhere else.
* `GhService` / `GH_HOST`.
* Changing `classifyForgeHost` so `ssh-gitlab.example.com` is GitLab.
* Expanding `CommandFormatter.gitlabTokenVars` beyond `GITLAB_TOKEN` /
  `GITLAB_ACCESS_TOKEN` / `OAUTH_TOKEN` (glab 1.109 login docs).
* `--hostname` on `glab mr` / `issue` / `ci` (1.109 rejects it).
* Executor-level argv injection (would break subcommands).
* Turning token neutralization off.
* Auto-filling `_runJson.extraEnv` from origin.
* `live-forge`, the `.app` build, glab 2.0 `GLAB_*`, `--ssh-hostname` on
  login, unused `ghHostname` on the probe.
* Migrating `listIssueComments` / `listMergeRequestNotes` onto `api()`
  (would add `-i` and change parse). Pin only.

## Prerequisites

* `flutter analyze`, `dart format --output=none --set-exit-if-changed`,
  `flutter test`.
* `lib/core/providers/app_providers.dart` is **binary** to search tools —
  `rg -a`.
* Commit only when executing: one commit per phase, `git commit --no-edit`.
  Never `-m`. Never push.
* **Halt:** if Phase 2 cannot insert `--hostname` after `api` without
  breaking `test/glab_http_test.dart` / `test/mutations_test.dart` result
  queues, stop. Do not teach those fakes to drop get-url calls. The
  override in Phase 0 is the fix.

## Implementation Steps

### Phase 0 — Test seam

**Why first.** `api()` / `jobs()` / `approveMergeRequest` tests queue
HTTP bodies (`glab_http_test.dart`, `mutations_test.dart`). An extra
`git remote get-url origin` would consume the first queued body.
`debugOriginHostOverride = 'gitlab.com'` makes `_originHost` return
that host without shelling, and `hostnameFlag('gitlab.com')` is empty,
so existing argv stays byte-identical once Phase 2 lands.

**File:** `lib/core/gitlab/glab_service.dart`

```dart
/// When non-null, [_originHost] returns this and does not shell git.
/// Production stays null. Argv tests set `'gitlab.com'` (no pin flags).
/// Pin tests leave this null and stub get-url.
@visibleForTesting
String? debugOriginHostOverride;

final Map<String, String?> _originHostCache = {};

Future<String?> _originHost(String repoPath) async {
  if (debugOriginHostOverride != null) return debugOriginHostOverride;
  if (_originHostCache.containsKey(repoPath)) {
    return _originHostCache[repoPath];
  }
  final remote = await _executor.execute(
    repoPath: repoPath,
    gitArgs: ['git', 'remote', 'get-url', 'origin'],
    timeout: const Duration(seconds: 20),
    lane: ExecLane.read,
  );
  final host = remote.isSuccess
      ? forgeHostFromRemoteUrl(remote.stdout.trim())
      : null;
  _originHostCache[repoPath] = host;
  return host;
}

@visibleForTesting
Future<String?> debugLookupOriginHost(String repoPath) =>
    _originHost(repoPath);

@visibleForTesting
void debugClearOriginHostCache() => _originHostCache.clear();

/// `--hostname` argv fragment for `glab api` / GraphQL.
/// Empty for null, blank, and `gitlab.com`.
static List<String> hostnameFlag(String? host) {
  final h = host?.trim();
  if (h == null || h.isEmpty || h == 'gitlab.com') return const [];
  return ['--hostname', h];
}
```

`hostEnv` is unchanged.

**Pin extraEnv (one expression, used everywhere):**

```dart
Map<String, String>? _hostExtraEnv(String? host) =>
    host == null ? null : hostEnv(host);
```

`hostEnv('gitlab.com')` is already `null`, so `_hostExtraEnv('gitlab.com')`
is `null`. Never write `hostEnv(resolved ?? 'gitlab.com')`.

**Test helper (required, not optional).** In
`test/glab_service_test.dart` add:

```dart
GlabService _svc(MockExecutor e) =>
    GlabService(e)..debugOriginHostOverride = 'gitlab.com';
```

Replace every existing `GlabService(executor)` in that file with
`_svc(executor)`. New pin groups construct `GlabService(executor)`
**without** `_svc`.

**Other files — set the override in `setUp` immediately after
`GlabService(...)`:**

| File | Where |
|---|---|
| `test/glab_http_test.dart` | **Both** `setUp`s (~74 and ~312). The second queues `[get-url, graphql]`; override keeps graphql from consuming get-url. |
| `test/mutations_test.dart` | `setUp` ~1712 (`group('GlabService mutations…')`). Pins exact `api` argv. |
| `test/forge_issues_test.dart` | existing `setUp` |
| `test/gh_glab_repo_ops_test.dart` | existing `setUp` |
| `test/branch_protection_test.dart` | existing `setUp` |
| `test/trace_stream_test.dart` | existing `setUp` |

Do **not** set the override on
`test/create_repo_wire_live_test.dart` or
`test/project_issue_wire_live_test.dart`.

**Tests added:** group `hostnameFlag` in `test/glab_service_test.dart`:

* `null` / `''` / `'gitlab.com'` → `[]`
* `'gitlab.example.com'` → `['--hostname', 'gitlab.example.com']`

Existing `hostEnv` tests stay.

**Verification**

```sh
dart format --output=none --set-exit-if-changed \
  lib/core/gitlab/glab_service.dart \
  test/glab_service_test.dart test/glab_http_test.dart \
  test/forge_issues_test.dart test/gh_glab_repo_ops_test.dart \
  test/branch_protection_test.dart test/trace_stream_test.dart \
  test/mutations_test.dart
flutter analyze
flutter test test/glab_service_test.dart test/glab_http_test.dart \
  test/forge_issues_test.dart test/gh_glab_repo_ops_test.dart \
  test/branch_protection_test.dart test/trace_stream_test.dart \
  test/mutations_test.dart
```

Production behaviour unchanged (`debugOriginHostOverride` is null,
`_originHost` unused until Phase 2).

**Commit.**

---

### Phase 1 — Lookup tests (no call-site wiring)

**File:** `test/glab_service_test.dart` group `origin host lookup`.

`GlabService(executor)` **without** override. Stub get-url
`['git','remote','get-url','origin']` →
`git@gitlab.example.com:group/proj.git`; anything else `_fail`.

Call `debugLookupOriginHost(_repo)`.

1. Returns `'gitlab.example.com'`; one `git remote get-url origin` on
   `ExecLane.read`.
2. Second call, same `repoPath`, does not shell git (cache).
3. `debugClearOriginHostCache()` then a third call shells git again.
4. Failed get-url caches null; second call does not retry.
5. `debugOriginHostOverride = 'other.example'` returns that and does
   not shell.

**Verification:** `flutter test test/glab_service_test.dart`

**Commit.**

---

### Phase 2 — Wire `api()` and `graphql()`

**File:** `lib/core/gitlab/glab_service.dart`

`api` (~415). Add optional `String? host`. Resolve, then build argv.
**One** extraEnv expression:

```dart
Future<dynamic> api(
  String repoPath,
  String endpoint, {
  List<String> fields = const [],
  bool paginate = false,
  String method = 'GET',
  String? host,
}) async {
  final resolved = host ?? await _originHost(repoPath);
  final args = <String>[
    'glab',
    'api',
    ...hostnameFlag(resolved),
    endpoint,
    '--method',
    method,
  ];
  if (paginate) args.add('--paginate');
  for (final field in fields) {
    args.addAll(['-f', field]);
  }
  if (!paginate) args.add('-i');
  return _runJson(
    repoPath,
    args,
    'glab api $endpoint',
    expectHeaders: !paginate,
    lane: method == 'GET' ? ExecLane.read : ExecLane.sync,
    extraEnv: _hostExtraEnv(resolved),
  );
}
```

`--hostname` sits after `api` and before the endpoint. Verified on 1.109.

`graphql` (~623). Add optional `String? host`. **One** argv construction
— keep `graphqlArgs` as the `-f` source:

```dart
final resolved = host ?? await _originHost(repoPath);
final gql = graphqlArgs(query, variables: variables);
// gql == ['glab','api','graphql', '-f','query=…', …]
final result = await _executor.execute(
  repoPath: repoPath,
  gitArgs: [
    'glab',
    'api',
    ...hostnameFlag(resolved),
    ...gql.skip(2),
    '-i',
  ],
  lane: ExecLane.read,
  compress: true,
  extraEnv: _hostExtraEnv(resolved),
);
```

Do not rebuild `-f` pairs by hand. Do not omit `-i`.

`projectDashboard` (~685): after a successful get-url, seed the cache
**before** `graphql` so graphql does not shell get-url a second time
(and so `glab_http_test` queued `[get-url, payload]` still lines up
when override is set *or* when the first queue item is that get-url):

```dart
final url = remote.stdout.trim();
_originHostCache[repoPath] = forgeHostFromRemoteUrl(url);
final fullPath = projectPathFromRemote(url);
```

Seed only on `remote.isSuccess`.

`api()` callers (`pipelines`, `jobs`, approve/merge/…, milestones,
labels, releases, protected branches, `repoMergePolicy`,
`mergeRequestDetail` REST fallback) inherit the pin. Do not also
look up origin in those methods.

**Tests — existing.** Override `'gitlab.com'` ⇒ empty `hostnameFlag`,
null extraEnv, no get-url. `mutations_test` exact argv and
`glab_http_test` `calls.single` / `hasLength(2)` stay valid.

**Tests — new** group `api/graphql host pin` in
`test/glab_service_test.dart` (`GlabService` **without** `_svc`):

Stub get-url → `https://gitlab.example.com/group/proj.git`.

| Test | Assert |
|---|---|
| `api GET` self-hosted | argv `['glab','api','--hostname','gitlab.example.com','projects/:id','--method','GET','-i']`; `extraEnv` has `GITLAB_HOST` and `GITLAB_URI` = `gitlab.example.com`; get-url once |
| `api GET` with override `'gitlab.com'` | no `--hostname`; extraEnv null |
| `jobs` two-page walk | get-url **once**, then two `glab api` calls each with `--hostname` |
| `graphql` | argv starts `['glab','api','--hostname','gitlab.example.com','graphql']`, contains `-f query=` and `-i`; extraEnv pinned |
| get-url failure | `api` still runs; no `--hostname`; extraEnv null |

If `resolveOriginUrl` tests fail because `gitArgs[2]` moved, change
those stubs to `contains('user')` / `any((a) => a.startsWith('projects/'))`.
Do not change them speculatively.

**Verification**

```sh
flutter analyze
flutter test test/glab_service_test.dart test/glab_http_test.dart \
  test/mutations_test.dart test/forge_issues_test.dart \
  test/branch_protection_test.dart
```

**Commit.**

---

### Phase 3 — Remaining repo-scoped invocations

Do **not** auto-fill `_runJson.extraEnv`. Each public method that does
not go through `api()`/`graphql()` looks up once:

```dart
final extra = _hostExtraEnv(await _originHost(repoPath));
```

and passes `extraEnv: extra`. Page loops use that `extra` for every
page (cache would also make a per-page `_originHost` cheap; still
resolve once in the method for clarity).

**Subcommands — env only, never `--hostname` (1.109 unknown flag):**

| Method | argv |
|---|---|
| `mergeRequests` | `glab mr list --output json …` via `_runJson` |
| `mergeRequestDetail` | `glab mr view` via `_runJson` (REST fallback already `api()`) |
| `createMergeRequest` | `glab mr create` `execute` |
| `checkoutMergeRequest` | `glab mr checkout` |
| `setMergeRequestDraft` | `glab mr update --draft/--ready` |
| `commentOnMergeRequest` | `glab mr note` |
| `editMergeRequest` | `glab mr update` |
| `listIssues` | `glab issue list` `_runJson` |
| `issueDetail` | `glab issue view` `_runJson` |
| `createIssue` | `glab issue create` |
| `closeIssue` / `reopenIssue` | `glab issue close/reopen` |
| `commentOnIssue` / `editIssue` | `glab issue note` / `update` |
| `traceStream` | `executeStream(['glab','ci','trace', id])` |

**Raw `glab api` `execute` — both `--hostname` and extraEnv.** Do not
route through `api()` (no `-i` change). Insert `hostnameFlag` after
`api`, same as Phase 2:

| Method | today |
|---|---|
| `listIssueComments` | `['glab','api','projects/:fullpath/issues/$iid/notes']` |
| `listMergeRequestNotes` | `['glab','api','projects/:fullpath/merge_requests/$iid/notes']` |

After: `['glab','api', ...hostnameFlag(host), 'projects/:fullpath/…']`
plus `extraEnv: _hostExtraEnv(host)` with `host = await _originHost(repoPath)`.

**Explicit-`host:` `glab api` — add `hostnameFlag(host)` only, keep
existing `hostEnv(host)`. Do not origin-lookup:**

| Method | change |
|---|---|
| `_recordCredentialUsername` | `['glab','api', ...hostnameFlag(host), 'user']`; `config set --host` unchanged |
| `listRepos` | after `'api'`, `...hostnameFlag(host)` |
| `resolveOriginUrl` | both `glab api user` and `glab api projects/…` |

`createRepoInExisting` / `_gitProtocol` already pass `hostEnv` /
`--host`. No `--hostname` (not `glab api`).

**Tests — existing argv** stay under override `'gitlab.com'`.

**Tests — new** group `subcommand host pin` (`GlabService` without `_svc`):

get-url → `git@gitlab.example.com:g/p.git`.

For `mergeRequests`, `createMergeRequest`, `listIssues`, `createIssue`,
`checkoutMergeRequest`, `listIssueComments`, `traceStream`:

* the glab call (not get-url) has `GITLAB_HOST=gitlab.example.com`
* `mr`/`issue`/`ci` argv does **not** contain `--hostname`
* `listIssueComments` argv **does** contain `--hostname gitlab.example.com`
  after `api`
* `mergeRequests` two pages: 1 get-url + 2 `mr list`

One test: override `'gitlab.com'` → `mergeRequests` extraEnv null.

`test/trace_stream_test.dart`: existing `lastArgs` test stays on the
override instance. Add one test without override: stub get-url + stream,
assert `streamCalls.single.extraEnv` contains `GITLAB_HOST`.

**Sweep (required, not optional).** After wiring:

```sh
rg -n "gitArgs:" lib/core/gitlab/glab_service.dart
rg -n "_runJson\(" lib/core/gitlab/glab_service.dart
```

Every `glab` argv is exactly one of:

1. create/clone/login with explicit `host:` + `hostEnv`/`hostnameFlag` as
   in the tables above;
2. repo-scoped via `api()`/`graphql()` (Phase 2);
3. repo-scoped `execute`/`_runJson`/`executeStream` with
   `_originHost` + `_hostExtraEnv` (and `hostnameFlag` iff the argv is
   `glab api`).

No fourth category. `glab config … --host` is (1).

**Verification**

```sh
flutter analyze
flutter test test/glab_service_test.dart test/glab_http_test.dart \
  test/forge_issues_test.dart test/trace_stream_test.dart \
  test/gh_glab_repo_ops_test.dart test/branch_protection_test.dart \
  test/mutations_test.dart
```

**Commit.**

---

### Phase 4 — Origin-scoped auth probe (GitLab repos only)

glab 1.109: `glab auth status --hostname <host>` from `$HOME` prints
**one** host block and exits 0 when that host's config token works.
Without `--hostname`, a mixed dump (gitlab.com 401 + self-hosted OK)
makes `parseGlabAuthStatus` report the first working host — dashboard
green while a command hit gitlab.com.

**File:** `lib/core/forge/auth_status.dart`

```dart
ToolAuth parseGlabAuthStatusForHost(
  String output, {
  required bool present,
  required String host,
}) { … }
```

Reuse `_hostBlocks` / `_blockLoggedIn`. Compare `host` to `block.host`
case-insensitively. Working block → same shape as today's success
(account from that block). Failed block → existing expired-token
detail for **that** host. Missing block → `authenticated: false`,
`host:` the requested host, detail:
`Not authenticated to <host> — run \`glab auth login --hostname <host>\` on the target.`
`present: false` → `ToolAuth.missing('glab')`.
Do **not** fall back to the first working block.

**File:** `lib/core/forge/auth_probe_service.dart`

```dart
Future<TargetAuth> probe({
  required String label,
  required bool isLocal,
  String cwd = '.',
  String? glabHostname,
}) async { … }

Future<ToolAuth> probeForgeCli(
  Forge forge, {
  String cwd = '.',
  String? hostname,
}) async { … }
```

Do not add `ghHostname`. When `glabHostname` is non-empty: argv
`['glab','auth','status','--hostname', glabHostname]`, fold with
`parseGlabAuthStatusForHost`. When empty: today's argv and
`parseGlabAuthStatus`.

**File:** `lib/core/providers/app_providers.dart` (`rg -a`)

`sessionAuthStatusProvider` (~5077). After the connected gate, derive
hostname **only for GitLab origins**:

```dart
String? glabHostname;
final path = repoPath;
if (path != null) {
  final url = await ref.watch(originRemoteUrlProvider(path).future);
  final h = url == null ? null : forgeHostFromRemoteUrl(url);
  if (h != null && classifyForgeHost(h) == Forge.gitlab) {
    glabHostname = h;
  }
}
return AuthProbeService(ref.read(activeExecutorProvider)).probe(
  label: display,
  isLocal: isLocal,
  cwd: path ?? '.',
  glabHostname: glabHostname,
);
```

Need `classifyForgeHost` / `forgeHostFromRemoteUrl` already imported
from `forge.dart` in this library (they are: `forgeProvider` lives here).
If the analyzer complains, add the import; do not duplicate the helpers.

A GitHub origin must **not** become `glab auth status --hostname github.com`.

`forgeAuthProvider` stays unscoped (create/clone prefill). Do not change
it.

**Tests**

* `test/auth_status_test.dart` — `parseGlabAuthStatusForHost`:
  * mixed dump + `gitlab.example.com` → authenticated, that host
  * mixed dump + `gitlab.com` → not authenticated, expired detail
  * dump without that host → not authenticated, "Not authenticated to"
  * `present: false` → missing
  * 1.109 single-block dump (no gitlab.com section) + matching host →
    authenticated
* `test/auth_probe_service_test.dart`:
  * `probe(glabHostname: 'gitlab.example.com')` argv
    `['glab','auth','status','--hostname','gitlab.example.com']`
  * existing tests still expect `['glab','auth','status']`
  * `probeForgeCli(Forge.gitlab, hostname: 'x')` includes `--hostname x`
* `test/forge_detection_test.dart` (pins the residual, no production
  change):

```dart
test('ssh-gitlab.example.com is not a gitlab telltale', () {
  expect(classifyForgeHost('ssh-gitlab.example.com'), Forge.unknown);
});
test('authStatusListsHost does not equate ssh-gitlab with gitlab.example.com', () {
  expect(
    authStatusListsHost(
      'gitlab.example.com\n  ✓ Logged in to gitlab.example.com as u\n',
      'ssh-gitlab.example.com',
    ),
    isFalse,
  );
});
```

`test/dashboard_sheet_test.dart` overrides `sessionAuthStatusProvider`;
leave it.

**Verification**

```sh
flutter analyze
flutter test test/auth_status_test.dart test/auth_probe_service_test.dart \
  test/forge_detection_test.dart test/dashboard_sheet_test.dart
```

**Commit.**

---

### Phase 5 — GraphQL null-project copy

**File:** `lib/core/gitlab/glab_service.dart` ~717

Replace the throw message with:

```dart
'GitLab reports no project at "$fullPath" — the origin path may be '
'wrong, or this token may lack access '
'(GitLab returns an empty result, not an error, in both cases)',
```

Must **not** contain `not logged in` or `auth login`.

**File:** `test/glab_service_test.dart` — existing
`'throws when project is null'` (~784). Keep the throw; add:

```dart
await expectLater(
  service.projectDashboard(_repo),
  throwsA(
    isA<GlabException>().having(
      (e) => e.message,
      'message',
      allOf(
        contains('no project at'),
        isNot(contains('not logged in')),
        isNot(contains('auth login')),
      ),
    ),
  ),
);
```

That test already stubs get-url + GraphQL `project: null`. Override
`'gitlab.com'` via `_svc` is fine.

**File:** `test/forge_list_error_test.dart` — add:

```dart
expect(
  looksLikeAuthFailure(
    Exception(
      'GitLab reports no project at "g/p" — the origin path may be '
      'wrong, or this token may lack access '
      '(GitLab returns an empty result, not an error, in both cases)',
    ),
  ),
  isFalse,
);
```

**Verification**

```sh
flutter test test/glab_service_test.dart --plain-name "throws when project is null"
flutter test test/forge_list_error_test.dart
```

**Commit.**

---

### Phase 6 — Docs

1. [docs/ARCHITECTURE_PLAN.md](ARCHITECTURE_PLAN.md) §4.1: cwd is a
   backstop; Magic Git always passes `GITLAB_HOST`/`GITLAB_URI` for
   subcommands and `--hostname` for `glab api` / GraphQL, from
   `git remote get-url origin`. Stdin login unchanged. Do not retarget
   the §4.3 version guard at 1.115.
2. [docs/0019-MADR-pin-glab-origin-host-on-every-call.md](0019-MADR-pin-glab-origin-host-on-every-call.md)
   More Information: one sentence that the host binary stays 1.109.0
   (1.111 keyring-by-default is the reason not to bump with this work).
   Leave MADR `status: proposed` until the decision is accepted.
3. This file's README index row stays plan `proposed`. After execution,
   set this plan to `executed` with date + outcome (0017 style).

No `AGENTS.md`.

**Commit.**

---

### Phase 7 — Full suite

```sh
dart format --output=none --set-exit-if-changed \
  lib/core/gitlab/glab_service.dart \
  lib/core/forge/auth_status.dart \
  lib/core/forge/auth_probe_service.dart \
  lib/core/providers/app_providers.dart \
  test/glab_service_test.dart test/glab_http_test.dart \
  test/forge_issues_test.dart test/trace_stream_test.dart \
  test/gh_glab_repo_ops_test.dart test/branch_protection_test.dart \
  test/mutations_test.dart test/auth_status_test.dart \
  test/auth_probe_service_test.dart test/forge_detection_test.dart \
  test/forge_list_error_test.dart
flutter analyze
flutter test
```

No `--run-skipped` / `-t live-forge`.

If `calls.first` is get-url, Phase 0 override was missed — fix the
construction site, do not drop the assertion.

If `provider_retry_policy_test.dart` fails, a new async provider lacks
`retry: noProviderRetry`. This plan must not add providers.

**Commit** only leftover format/analyze fixes.

---

### Phase 8 — Maintainer live check (not coded)

glab **1.109.0** on `admdevops`, through Magic Git's SSH session:

1. No stored GitLab token. Open `~/gitrepos/ansible` and
   `~/gitrepos/tf-okd-sbx`. Forge MR list loads (empty `[]` is success);
   Project dashboard has no sign-in callout; output log shows
   `--hostname gitlab.example.com` on `glab api` and/or
   `GITLAB_HOST=gitlab.example.com` on `glab mr`.
2. Repeat with a stored GitLab token (neutralization on). Pin still
   present; login still stdin.
3. Dashboard glab row names `gitlab.example.com` while a GitLab repo is
   active; a GitHub repo must not run
   `glab auth status --hostname github.com`.

If (1) is HTTP 401 against gitlab.com, capture the formatted command
and stop. Do not edit the bastion `config.yml` `host:` default. Do not
upgrade glab.

## Verification

| Criterion | How |
|---|---|
| `--hostname` + env on `api` / `graphql` | Phase 2; 1.109 live-checked |
| env on subcommands; `--hostname` on raw `glab api` notes | Phase 3 + rg sweep |
| one lookup per public call | Phase 1 cache + Phase 2 `jobs` walk |
| dashboard scoped to GitLab origin only | Phase 4 |
| null-project copy not auth-shaped | Phase 5 |
| analyze / format / full suite | Phase 7 |
| bastion / 1.109 | Phase 8 |

## Rollout and Rollback

**Rollout.** Library + tests + docs. No schema, entitlements, or glab
install. Unsigned `--install` is the maintainer's choice after Phase 8.

**Rollback.** Revert phase commits newest-first. No bastion config or
binary is modified.

**Residuals**

* `GhService` host pin.
* `classifyForgeHost('ssh-gitlab.example.com')` remains `unknown`;
  insteadOf on get-url is what classifies `admdevops` remotes as GitLab.
* `glab auth login --ssh-hostname` when raw origin host ≠ get-url host.
* glab 2.0 `GLAB_*` env rename.
* Empty `hosts.gitlab.com.token` on the bastion (operator cleanup).
* glab upgrade (explicitly declined; 1.111 keyring default).
)
