---
status: "in-progress"
verified: 2026-09-19  # checked against the code at d67953c: shipped deliverables located, supersessions traced (0054 follow-up)
date: 2026-09-18
associated-madr: "0052-MADR-sidebar-info-card-location-row-and-plain-connections-button.md"
---

# Implement the sidebar Location row, the plain Connections button, and one repository name

Associated MADR:
[0052-MADR-sidebar-info-card-location-row-and-plain-connections-button.md](0052-MADR-sidebar-info-card-location-row-and-plain-connections-button.md)
(`accepted`, 2026-09-18).

## Goal

Ship the three changes the MADR decides, each proven by a test that has been seen to fail:

1. **One repository name.** The tab title, window title, sidebar Repository row and every pane's
   status bar show the same name: the tab alias when the tab has one, else the last directory of the
   repo path. All four derive it from one function, replacing seven hand-written copies.
2. **A Location row** in the sidebar info card, under Repository: the SSH host (tooltip
   `username@host:port` for a saved connection), or `This Mac` for a local session.
3. **A fixed `Connections` label** on the connections-manager button, which still opens the manager.

## Scope

**In scope**, and the only files this plan may touch:

| file | phase | change |
|---|---|---|
| `lib/features/tabs/tab_ui_providers.dart` | 1 | add `repositoryDisplayName` and `repositoryDisplayNameProvider` |
| `test/repository_display_name_test.dart` | 1 | new |
| `lib/features/repository/repo_status_view.dart` | 2 | status bar name from the provider |
| `lib/features/history/history_view.dart` | 2 | same |
| `lib/features/branches/branches_view.dart` | 2 | same |
| `lib/features/stash/stash_view.dart` | 2 | same |
| `lib/features/worktrees/worktrees_view.dart` | 2 | same, for the repository site only (line 791); the `Worktree:` site (line 747) is untouched |
| `lib/features/forge/forge_workspace.dart` | 2 | same |
| `lib/features/tabs/tabs_host.dart` | 2 | `windowTitleProvider` uses the provider |
| `lib/features/tabs/tab_strip.dart` | 2 | tab title uses `repositoryDisplayName` |
| `test/repository_name_source_test.dart` | 2 | new source scan |
| `lib/features/switcher/current_repo_indicator.dart` | 3 | `SessionInfoCard`, `_InfoRow`, `CurrentLocationIndicator`; Repository row uses the provider |
| `lib/features/app_shell.dart` | 3 | mount `SessionInfoCard` in place of `CurrentRepoIndicator` |
| `test/session_info_card_test.dart` | 3 | new |
| `test/repository_name_parity_test.dart` | 3 | new |
| `test/app_shell_test.dart` | 3 | one layout test added |
| `lib/features/switcher/connection_switcher.dart` | 4 | fixed `Connections` label |
| `test/connection_switcher_test.dart` | 4 | two label tests replaced, one tap test added |
| this plan, the MADR, `docs/README.md` | 0, each phase, 5 | records |

**Out of scope:** user-provided repository labels (MADR F7); the command palette's tab entries, which
read `aliasFor` for their own purpose; the `Worktree: <name>` status-bar text; `LogoutButton`; the
landing screen's Connections Manager button. Touching any other file is a deviation: stop and prompt.

## Conventions used by every phase

**SDK check**, before the first command of each session:

```sh
flutter --version | head -1          # must print Flutter 3.47.2
flutter pub get --enforce-lockfile   # must print "Got dependencies!"
```

If either disagrees, use `./.flutter-sdk/bin/flutter` for every command in this plan.

**Gate**, run before every commit. Each status is captured, never piped:

```sh
LOG=<scratchpad>/p<N>-gate.log
dart format --output=none --set-exit-if-changed <every .dart file the phase staged>; FMT=$?
flutter analyze > "$LOG.analyze" 2>&1; AN=$?
flutter test <the phase's test files> > "$LOG.targeted" 2>&1; TT=$?
flutter test > "$LOG.full" 2>&1; FULL=$?
```

All four must be `0`. The full run's last line is read in full and recorded in the execution record.
A failure is read from the whole log, not a `grep` of it.

**Commit**, per phase: `git add` the phase's files by explicit path (never `-A`), then
`git commit --no-edit`, then `git log -1 --format=%B` to read the hook's message back. Code commits and
execution-record commits are separate: the code commit first, then a docs commit that appends
"Phase N, executed" to this plan.

**Seen to fail.** A new test is written and run **before** the change it guards, and its failure is
recorded: file, test name, and the failing expectation's text. That run is in the real tree, but only
because the code under test has not been written yet; nothing is broken on purpose there. Every
deliberate breakage ("mutation") runs in a scratch worktree, never the real tree, through one script,
`<scratchpad>/mutate.py`, written in Phase 1 and reused:

- It takes a mutation list: `(file, old, new, test_file, expected_failing_test_name)`.
- It runs `git worktree add --detach <scratchpad>/wt0052 HEAD` and
  `flutter pub get --enforce-lockfile --offline` inside it.
- For each mutation it asserts `old` occurs exactly once, writes the edit, asserts the new text is
  present, runs `flutter test <test_file>` with a timeout, and saves the whole output to
  `<scratchpad>/mut-<n>.log`. It then requires a non-zero exit **and** the expected test name in the
  failure output, and restores the file from `HEAD` inside the worktree
  (`git -C <worktree> checkout HEAD -- <file>`). That restore touches only the scratch worktree this
  script created.
- It finishes with `git worktree remove --force <scratchpad>/wt0052`, again only the worktree it created.
- It prints one verdict line per mutation and exits non-zero if any mutation survived.

A mutation that fails to compile does not count: the log must show the named test failing. If it
shows a compile error, the mutation is rewritten.

## Implementation Steps

### Phase 0 — Baseline and records

1. Run the SDK check.
2. Run the full gate's `flutter analyze` and `flutter test` on the unmodified tree. Record the analyzer
   result and the full suite's final line verbatim. The expected figure is `+4160 ~3: All tests
   passed!`, from after `2d0ebb5`. If it differs, record the real figure and use it as the baseline.
3. Commit the records (docs only): the MADR (renamed, amended, `accepted`), `docs/README.md` and this
   plan.

**Acceptance:** tree clean after the commit; baseline figures recorded under "Phase 0, executed".

### Phase 1 — The shared name function and provider

1. **Write the tests first:** `test/repository_display_name_test.dart`.
   - `repositoryDisplayName` group, pure function:
     - T1.1 `repositoryDisplayName('/srv/backend-src')` is `backend-src`.
     - T1.2 `repositoryDisplayName('/srv/backend-src/')` is `backend-src`.
     - T1.3 with `alias: 'Backend'` it is `Backend`.
     - T1.4 with `alias: '   '` it is `backend-src`.
     - T1.5 with `alias: '  Backend  '` it is `Backend`.
     - T1.6 with `alias: null` it is `backend-src`.
   - `repositoryDisplayNameProvider` group: a `ProviderContainer(retry: (_, _) => null)` overriding
     `connectionProvider` with a stub `ConnectionController` whose state is connected, with
     `repoPath: '/srv/backend-src'`.
     - T1.7 no alias: `container.read(repositoryDisplayNameProvider('/srv/backend-src'))` is `backend-src`.
     - T1.8 after `container.read(tabAliasProvider.notifier).set('Backend')`, the same read is `Backend`.
     - T1.9 with that alias set, `repositoryDisplayNameProvider('/srv/other')` is `other`. The alias
       applies only to the session's repo.
     - T1.10 reactivity: `container.listen` on the provider for `/srv/backend-src`, then set the alias
       to `Backend`, then to `''`. The listener sees `Backend`, then `backend-src`.
2. Run the file. It must fail to compile, because the symbols do not exist yet. That is **not** the
   seen-to-fail evidence for this phase; the mutations in step 5 are.
3. **Implement** in `lib/features/tabs/tab_ui_providers.dart`, adding the imports
   `../../core/providers/app_providers.dart` (for `connectionProvider`) and
   `../../core/utils/posix_path.dart` (for `basename`):

   ```dart
   /// The one name for a repository across the tab title, window title, sidebar
   /// Repository row and status bar (MADR 0052): the tab's alias when it has
   /// one, else the last directory of [repoPath].
   String repositoryDisplayName(String repoPath, {String? alias}) {
     final trimmed = alias?.trim() ?? '';
     return trimmed.isEmpty ? basename(repoPath) : trimmed;
   }

   /// [repositoryDisplayName] for [repoPath] in this tab. The tab's alias names
   /// the tab's own repository, so it applies only when [repoPath] is the
   /// session's; a pane naming any other path gets that path's basename.
   final repositoryDisplayNameProvider = Provider.family<String, String>((
     ref,
     repoPath,
   ) {
     final active = ref.watch(connectionProvider.select((c) => c.repoPath));
     final alias = ref.watch(tabAliasProvider);
     return repositoryDisplayName(
       repoPath,
       alias: repoPath == active ? alias : null,
     );
   });
   ```

   The provider is synchronous, so the retry-policy scan (`provider_retry_policy_test.dart`, which
   matches `FutureProvider|StreamProvider|AsyncNotifierProvider`) does not apply to it.
4. Run the gate. Record the new test count.
5. **Mutations** (after the code commit, in the scratch worktree):

   | # | file | mutation | must fail |
   |---|---|---|---|
   | M1.1 | `tab_ui_providers.dart` | `alias: repoPath == active ? alias : null,` → `alias: alias,` | T1.9 |
   | M1.2 | `tab_ui_providers.dart` | `final trimmed = alias?.trim() ?? '';` → `final trimmed = alias ?? '';` | T1.5 |
   | M1.3 | `tab_ui_providers.dart` | `return trimmed.isEmpty ? basename(repoPath) : trimmed;` → `return basename(repoPath);` | T1.3 |
   | M1.4 | `tab_ui_providers.dart` | `final alias = ref.watch(tabAliasProvider);` → `final alias = ref.read(tabAliasProvider);` | T1.10 |

**Acceptance:** T1.1–T1.10 pass; M1.1–M1.4 each fail their named test; gate green; code commit, then
the execution-record commit.

### Phase 2 — Status bar, window title and tab title use the shared name

1. **Write the source scan first:** `test/repository_name_source_test.dart`. It reads every `.dart`
   file under `lib/` and finds each `repositoryName:` named argument. The argument's text runs from the
   match to the next line that begins, after whitespace, with an identifier and a colon. It asserts:
   - exactly **7** occurrences exist. A scan that finds none, or finds an unexpected new site, fails
     loudly, and a new site is a decision to make, not to absorb;
   - exactly **1** of them contains `'Worktree: `, and that one is in `worktrees_view.dart`;
   - each of the other **6** contains `repositoryDisplayNameProvider(`;
   - none of the 7 contains `.split('/')`.

   Run it on the unmodified tree. It must fail on the "contains `repositoryDisplayNameProvider(`"
   assertion, naming the first unconverted file. Record that failure; it is the scan's seen-to-fail
   evidence.
2. **Convert the six status-bar sites.** Each old expression must occur exactly once, asserted before
   replacing:

   | file | old | new |
   |---|---|---|
   | `repo_status_view.dart` | `repositoryName: pathSegments.isEmpty ? repoPath : pathSegments.last,` | `repositoryName: ref.watch(repositoryDisplayNameProvider(repoPath)),` |
   | `history_view.dart` | `'Repository: ${widget.repoPath.split('/').where((part) => part.isNotEmpty).lastOrNull ?? widget.repoPath}'` | `'Repository: ${ref.watch(repositoryDisplayNameProvider(widget.repoPath))}'` |
   | `branches_view.dart` | `'Repository: ${pathParts.isEmpty ? repoPath : pathParts.last}'` | `'Repository: ${ref.watch(repositoryDisplayNameProvider(repoPath))}'` |
   | `stash_view.dart` | same old | same new |
   | `worktrees_view.dart` | same old; the file has exactly one `Repository: ` site, at line 791 | same new |
   | `forge_workspace.dart` | same old | same new |

   Then:
   - Add `import '../tabs/tab_ui_providers.dart';` to each file that lacks it (`branches_view.dart`
     already has it).
   - Run `flutter analyze`. For each `unused_local_variable` it reports on a `pathParts` or
     `pathSegments` local in these six files, delete that declaration. Delete nothing it does not
     report. A local still used elsewhere in its method stays.
3. **Window title**, in `tabs_host.dart`'s `windowTitleProvider`, replace

   ```dart
     final alias = ref.watch(tabAliasProvider);
     final segments = repoPath.split('/').where((seg) => seg.isNotEmpty);
     final name = alias ?? (segments.isEmpty ? repoPath : segments.last);
   ```

   with `final name = ref.watch(repositoryDisplayNameProvider(repoPath));`. The provider's session gate
   is always true here, because `repoPath` is the session's.
4. **Tab title**, in `tab_strip.dart`, replace

   ```dart
       : (TabsController.current?.aliasFor(tab) ??
             (tab.repoPath != null ? basename(tab.repoPath!) : 'Connecting…'));
   ```

   with

   ```dart
       : (tab.repoPath != null
             ? repositoryDisplayName(
                 tab.repoPath!,
                 alias: TabsController.current?.aliasFor(tab),
               )
             : (TabsController.current?.aliasFor(tab) ?? 'Connecting…'));
   ```

   and add `import 'tab_ui_providers.dart';`. The tab calls the pure function with its own alias rather
   than the session-gated provider, because a tab is titled before its session has a `repoPath`: the
   alias identity comes from `savedReferencePath` (`tabs_controller.dart:162-185`). Today's
   behaviour, which shows the alias while connecting, is preserved exactly. Remove the
   `posix_path.dart` import only if `flutter analyze` reports it unused.
5. Rerun the scan; it must pass. Run the existing tests that pin the touched surfaces, unchanged:
   `test/tabs_host_test.dart` (its alias title test expects `Backend (main) — Magic Git`) and
   `test/tabs_controller_test.dart`.
6. Run the gate. The 48 goldens in `test/workspace_golden_test.dart` must pass unchanged: with no
   alias, every status bar renders the same text as before.
7. **Mutations** (scratch worktree):

   | # | file | mutation | must fail |
   |---|---|---|---|
   | M2.1 | `stash_view.dart` | revert that site to the Phase-2 "old" expression, and restore its `pathParts` declaration if one was deleted | the scan's provider assertion |
   | M2.2 | `worktrees_view.dart` | `'Worktree: ` → `'Checkout: ` at line 747 | the scan's worktree-exception count |

**Acceptance:** scan seen failing before and passing after; M2.1 and M2.2 fail; existing tab and title
tests unchanged and green; goldens unchanged; gate green; two commits.

### Phase 3 — The info card: Repository row on the shared name, and the Location row

1. **Write the tests first.**
   - **`test/session_info_card_test.dart`.** Its harness is an `UncontrolledProviderScope` over a
     `ProviderContainer` that overrides:
     - `connectionProvider`, with a stub;
     - `statusProvider`, with a clean status;
     - `savedConnectionsProvider` and `savedLocalReposProvider`, with given lists.

     It pumps `SessionInfoCard` in `MacosApp` → `MacosWindow` → `ContentArea`, as
     `current_repo_indicator_test.dart` does. Tooltips are matched with a `MacosTooltip` message
     predicate; glyphs with a `MacosIcon` predicate on `icon`.
     - L1 saved SSH: state is connected SSH, `host: 'build01.example.com'`, `connectionId: 'c1'`,
       `connectionLabel: 'Build box'`, `repoPath: '/srv/repo'`. Saved is
       `SavedConnection(id: 'c1', label: 'Build box', host: 'build01.example.com', port: 2222,
       username: 'deploy', repoPath: '/srv/repo')`. Expect:
       - `Location` and `build01.example.com` each `findsOneWidget`;
       - `Build box` `findsNothing`;
       - a tooltip `deploy@build01.example.com:2222`;
       - a `CupertinoIcons.globe` icon.
     - L2 ad-hoc SSH: `connectionId: null`, `host: 'adhoc.example.com'`. The value and the tooltip are
       both `adhoc.example.com`.
     - L3 local: `backend: ConnectionBackend.local`, `connectionLabel: 'my-local-repo'`,
       `repoPath: '/Users/u/code/proj'`. Expect:
       - `This Mac` shown, with tooltip `On this Mac` and a `CupertinoIcons.desktopcomputer` icon;
       - `Local` and `my-local-repo` each `findsNothing`.
     - C1 card shape: the `Repository` caption's `dy` is less than the `Location` caption's. Exactly
       one `Container` under `SessionInfoCard` has a `BoxDecoration` whose top border is
       `MacosColors.separatorColor`.
     - R1 alias: `container.read(tabAliasProvider.notifier).set('Backend')`, then pump. `Backend` shows,
       `repo` does not, and the Repository tooltip still starts with `/srv/repo`.
     - R2 labels stay out: saved connection `c1` carries `repoLabels: {'/srv/repo': 'Website'}`.
       `Website` `findsNothing` and `repo` shows.
   - **`test/repository_name_parity_test.dart`**, the MADR's parity check, in one tab container:
     - `SharedPreferences.setMockInitialValues({})`.
     - A `TabsController(workspaceStore: SavedWorkspaceStore(), containerFactory: …)` whose factory
       overrides:
       - `connectionProvider`, with a stub that is connected SSH, `connectionId: 'c1'`,
         `repoPath: '/srv/backend-src'`;
       - `statusProvider`, clean, head `main`;
       - `stashesProvider('/srv/backend-src')`, with `[]`;
       - `savedConnectionsProvider`, with `c1` carrying `repoLabels: {'/srv/backend-src': 'Website'}`;
       - `repoWatchProvider('/srv/backend-src')`, with an empty stream.
     - Set `TabsController.current = controller`, and reset it to `null` in `addTearDown`.
     - `await controller.aliasesReady`. `ensureInitialTab()`, then `openOrFocus` twice:
       - the tab under test: `connectionId: 'c1'`, `repoPath: '/srv/backend-src'`,
         `savedKind: SavedRepositoryKind.ssh`;
       - a second tab on `/srv/other`, so the strip renders (it hides with one tab).
     - Pump `TabsScope(controller)` → `UncontrolledProviderScope(tab.container)` → `MacosApp`, with a
       `Column` of `TabStrip`, a `SizedBox(height: 60, child: CurrentRepoIndicator())` and an
       `Expanded(StashView(repoPath: '/srv/backend-src'))`, at a 1200×800 surface.
     - P1 no alias:
       - the tab chip and the Repository row each show `backend-src`; scope each finder with
         `find.descendant` of `TabStrip` and `CurrentRepoIndicator`;
       - the stash status bar shows `Repository: backend-src`;
       - `tab.container.read(windowTitleProvider)` starts with `backend-src`.
     - P2 alias: `await controller.setAlias(tab, 'Backend')`, then pump. The same four surfaces show
       `Backend`, `Backend`, `Repository: Backend`, and a title starting `Backend`.
     - P3 labels stay out: in both states, `find.text('Website')` `findsNothing`.
     - P1, P2 and P3 are three separate `testWidgets`, each building its own controller through one
       shared helper, so a failure names the state that broke.

     If the second tab's container disturbs the first tab's pump, for example because
     `TabsController.current` changes the active container, that is a deviation: stop and prompt.
     Do not reshape the test to avoid it.
   - **`test/app_shell_test.dart`, one test:** "the connected sidebar shows the whole info card and
     button stack at 761×480".
     - Surface: `tester.view.physicalSize = const Size(761, 480)`, `devicePixelRatio = 1`.
     - Pump `AppShell` connected SSH, `host: 'build01.example.com'`, `repoPath: '/srv/repo'`, with
       `repoWatchProvider('/srv/repo')` an empty stream, both saved-list providers `[]`, and
       `SharedPreferences` mocked. Then `pump()` and `pump(100 ms)`, as `app_shell_undo_test.dart`
       does.
     - Expect `find.text('Location')` `findsOneWidget`, the rect of `find.text('Logout')` to have
       `bottom <= 480`, and the `Location` rect to have `top >= 0`.
     - Expect `tester.takeException()` to be `isNull`. This test must **not** use the file's
       `_drainTestFontOverflow`, which would swallow exactly the overflow under test. If an exception
       arises from outside the sidebar (a pane's test-font overflow at this width), that is a
       deviation: stop and prompt.
   - Run all three files. Each must fail: `SessionInfoCard` and `CurrentLocationIndicator` do not
     exist, the row ignores the alias, and there is no `Location`. Record each failure. The parity
     file's **P2 row assertion** is the evidence that matters, since the tab, status bar and window
     already follow the alias after Phase 2. Before running, confirm that the file compiles against
     the current tree, since it uses only `CurrentRepoIndicator`, which exists. Only then read P2's
     failure as meaningful.
2. **Implement** in `lib/features/switcher/current_repo_indicator.dart`:
   - a private `_InfoRow({icon, caption, value, tooltip, trailing})`:
     - `Padding(EdgeInsets.symmetric(horizontal: 12, vertical: 4))` → `MacosTooltip(message: tooltip)` →
       `Row`;
     - the `Row` holds `MacosIcon(icon, size: 15, color: MacosColors.systemBlueColor)`, `SizedBox(width: 8)`,
       and an `Expanded` `Column(mainAxisSize: min, crossAxisAlignment: start)`;
     - the `Column` holds the grey `caption1` caption, then the value (`maxLines: 1`, ellipsis, `body`
       w600), then `trailing` when non-null;
     - these are exactly today's styles, lifted from the current row;
   - `CurrentRepoIndicator` renders `_InfoRow(icon: CupertinoIcons.folder_fill, caption: 'Repository',
     value: ref.watch(repositoryDisplayNameProvider(repoPath)), tooltip: _tooltip(repoPath, status),
     trailing: status == null ? null : _statusCluster(typography, status))`. It keeps its early
     `SizedBox.shrink()` when `repoPath` is null. It no longer draws its own top border;
   - `CurrentLocationIndicator`:
     - a local session renders `_InfoRow(icon: CupertinoIcons.desktopcomputer, caption: 'Location',
       value: 'This Mac', tooltip: 'On this Mac')`;
     - otherwise it looks up `connectionId` in `ref.watch(savedConnectionsProvider).value ?? const []`
       with `where(…).firstOrNull`;
     - `value` is `host ?? connectionLabel ?? 'Connected'`, today's fallback chain;
     - `tooltip` is `'${conn.username}@${conn.host}:${conn.port}'` when found, else `value`;
     - the icon is `CupertinoIcons.globe`;
   - `SessionInfoCard`:
     - a `Container` with today's single top border (`MacosColors.separatorColor`) and
       `EdgeInsets.symmetric(vertical: 4)`;
     - its child is `const Column(mainAxisSize: MainAxisSize.min, children: [CurrentRepoIndicator(),
       CurrentLocationIndicator()])`;
   - update the file's doc comments, which today say the row "sits directly above the
     ConnectionSwitcher".

   Imports: add `../../core/storage/saved_connection.dart` and `../tabs/tab_ui_providers.dart`, and
   remove `posix_path.dart` if `flutter analyze` reports it unused.
3. In `app_shell.dart`, replace `CurrentRepoIndicator(),` in the sidebar `bottom` column with
   `SessionInfoCard(),`, and update the two comments above it.
4. Rerun the three files; all must pass. `test/current_repo_indicator_test.dart` must pass
   **unmodified**.
5. Run the gate.
6. **Mutations** (scratch worktree):

   | # | file | mutation | must fail |
   |---|---|---|---|
   | M3.1 | `current_repo_indicator.dart` | `value: 'This Mac',` → `value: 'Local',` | L3 |
   | M3.2 | `current_repo_indicator.dart` | `'${conn.username}@${conn.host}:${conn.port}'` → `'${conn.username}@${conn.host}'` | L1 |
   | M3.3 | `current_repo_indicator.dart` | `value: ref.watch(repositoryDisplayNameProvider(repoPath)),` → `value: basename(repoPath),`, adding the `posix_path` import back if it was removed | R1 and parity P2 |
   | M3.4 | `current_repo_indicator.dart` | insert `SizedBox(height: 600),` as the first child of `SessionInfoCard`'s `Column`, dropping that `Column`'s `const` | the 761×480 layout test |

**Acceptance:** all new tests seen failing and then passing; `current_repo_indicator_test.dart`
unmodified and green; M3.1–M3.4 fail; gate green; two commits.

### Phase 4 — The Connections button

1. **Write the tests first.** In `test/connection_switcher_test.dart`, replace the two tests at lines
   348–379 ("switcher button shows the server host for an SSH session" and "switcher button shows
   "Local" for a local session, not the repo name") with:
   - B1 "switcher button reads Connections for an SSH session": the same SSH state as the old test.
     `Connections` `findsOneWidget`, and `build01.example.com` `findsNothing`.
   - B2 "switcher button reads Connections for a local session": the same local state. `Connections`
     `findsOneWidget`; `Local`, `This Mac` and `my-local-repo` each `findsNothing`.
   - B3 "tapping the switcher opens the connections manager": SSH state; tap `find.text('Connections')`,
     `pumpAndSettle`, then `find.byType(ConnectionsPanel)` `findsOneWidget`.

   Run the file. B1 and B2 must fail, because today's button shows the host and `Local`. B3 passes
   before the change, and that is expected: it pins existing behaviour the change must keep. Record
   all three results.
2. **Implement** in `connection_switcher.dart`'s `ConnectionSwitcher.build`:
   - replace the four-field `select` with `final isConnected = ref.watch(connectionProvider.select((c)
     => c.isConnected));`;
   - delete the `label` computation and its comment (lines 47–53);
   - render `'Connections'` in the `Text`;
   - leave the early `SizedBox.shrink()`, the glyph, style, `HoverPop` and `onPressed` untouched;
   - update the class doc comment to say the label is fixed and the session's location lives in the
     info card.
3. Rerun the file; all its tests pass. Run the gate.
4. **Mutation** (scratch worktree): M4.1 changes `'Connections',` in `ConnectionSwitcher`'s `Text` to
   `'Manage',`. It must fail B1, B2 and B3.

**Acceptance:** B1 and B2 seen failing, then passing; B3 green throughout; M4.1 fails; gate green; two
commits.

### Phase 5 — Close

1. Final gate on the whole tree. Record `flutter analyze` and the full suite's last line verbatim, and
   the delta from the Phase 0 baseline. It should equal the tests this plan added: 10 + 1 + 6 + 3 + 1,
   and +1 net in `connection_switcher_test.dart` (two replaced, three added). That is 22.
2. Set this plan to `executed`, or `complete` once the maintainer's manual check below is done. Set
   the MADR's `verified:` date, and update the `docs/README.md` row with commits and the status.
3. Update the memory notes `remote-repo-labels` and `magic-git-project` with where the naming
   function lives.
4. Commit the records (docs only).

## Verification

Automated, all in the gate:

- `test/repository_display_name_test.dart`: T1.1–T1.10.
- `test/repository_name_source_test.dart`: every repository-naming status-bar site uses the provider.
- `test/session_info_card_test.dart`: L1–L3, C1, R1, R2.
- `test/repository_name_parity_test.dart`: P1–P3, covering tab, row, status bar and window title,
  with and without an alias.
- `test/app_shell_test.dart`: the 761×480 layout test.
- `test/connection_switcher_test.dart`: B1–B3.
- Unchanged and green: `current_repo_indicator_test.dart`, `tabs_host_test.dart`,
  `tabs_controller_test.dart`, the 48 goldens.
- Every mutation M1.1–M4.1 recorded as failing its named test, with the log path.

**Manual, maintainer only:** in the built app (`./build_macos.sh --unsigned --install`), with an SSH
session and a local one:
- the card reads Repository / Location with the host or `This Mac`, and the button reads
  `Connections`;
- after **Rename Tab** in Saved Workspaces, the tab, window title, Repository row and status bar all
  change together.

## Rollout and Rollback

It ships in the next build; there is no migration or stored-format change. Aliases and saved
connections are read, never written. Each phase is its own code commit, so rollback is `git revert` of
that commit, in reverse phase order. Phases 3 and 4 depend on Phase 1, and Phase 2's scan test would
need reverting with Phase 2.

## Execution record

### Phase 0, executed

2026-09-18. `flutter --version`: 3.47.2, matching `FLUTTER_VERSION`. `flutter pub get
--enforce-lockfile`: "Got dependencies!". Baseline on `626f64b` plus these records:
`flutter analyze` "No issues found!" (exit 0); full `flutter test` `+4160 ~3: All tests passed!`
(exit 0), as expected. Records committed: the MADR (renamed, amended, `accepted`),
`docs/README.md`, and this plan.

### Phase 1, executed

**Code commit** `f7d7b9d`: `repositoryDisplayName` and `repositoryDisplayNameProvider` in
`lib/features/tabs/tab_ui_providers.dart`, as written in step 3. Tests are in
`test/repository_display_name_test.dart`, T1.1–T1.10.

**Red first.** The file failed to compile before the implementation
(`Method not found: 'repositoryDisplayName'`), as step 2 predicted. That is not the evidence.

**Note, not a deviation.** On its first green run T1.10 failed: `Expected: ['backend-src', 'Backend',
'backend-src']`, `Actual: ['backend-src']`. Riverpod 3 delivers a dependant's update on the next
flush, not synchronously. The test now `await container.pump()`s after each alias change; the
assertion is unchanged.

**Gate.** `dart format`: 0 changed. `flutter analyze`: No issues found (exit 0). Targeted: `+10: All
tests passed!`. Full `flutter test`: `+4170 ~3: All tests passed!` (exit 0), +10 on the baseline.

**Mutations**, run by `<scratchpad>/mutate.py` in a detached scratch worktree at `f7d7b9d`, which was
then removed. Each named test failed on its assertion, not on compilation:

| # | failing test | failure |
|---|---|---|
| M1.1 | T1.9 | `Expected: 'other'`, `Actual: 'Backend'` |
| M1.2 | T1.5 | the untrimmed alias returned |
| M1.3 | T1.3 | `backend-src` returned for alias `Backend` |
| M1.4 | T1.10 | the listener saw only the initial value |

**The mutation script was itself seen to fail.** A comment-only edit (M0) was reported `SURVIVED` with
exit 1, so a kill is not an artefact of the harness.

### Phase 2, executed

**Code commit** `54508dc`. The six status-bar sites, `windowTitleProvider` and the tab title now use
the shared name, as in steps 2–4. `flutter analyze` then reported exactly six unused items, and only
those were deleted:
- the `pathParts` locals in `branches_view.dart:595`, `forge_workspace.dart:50`, `stash_view.dart:371`
  and `worktrees_view.dart:789`;
- the `pathSegments` local in `repo_status_view.dart:1649`;
- the `posix_path.dart` import in `tab_strip.dart`.

**Red first.** `test/repository_name_source_test.dart` ran on the unconverted tree. It found 7 sites
and failed on the provider assertion, naming the first: `lib/features/repository/repo_status_view.dart
names the repository itself: repositoryName: pathSegments.isEmpty ? repoPath : pathSegments.last,`.

**Gate.**
- `dart format`: 0 changed across 9 files.
- `flutter analyze`: No issues found (exit 0).
- Targeted (the scan, `tabs_host_test.dart`, `tabs_controller_test.dart`, all unchanged except the new
  scan): `+24: All tests passed!`. The alias window-title test, `Backend (main) — Magic Git`, passed
  unmodified.
- Full `flutter test`: `+4171 ~3: All tests passed!` (exit 0), +1. That includes the 48 goldens,
  unchanged.

**Mutations** (scratch worktree at `54508dc`, removed afterwards):
- **M2.1** puts a hand-split name back at the Stashes site. It is **killed**: `Expected: contains
  'repositoryDisplayNameProvider('`. It is written as an inline `split('/')` expression rather than by
  restoring the deleted `pathParts` local; the effect on the scan is identical and it compiles alone.
- **M2.2** renames the `Worktree:` exception. Its first anchor, `'Worktree: `, matched twice in
  `worktrees_view.dart`: the status bar at line 749 and a row label at line 1217. The script refused
  to guess. With the anchor narrowed to `'Worktree: ${tabParts` it is **killed**: `Expected: an object
  with length of <1>`, `Actual: … []`.

### Phase 3, executed

**Code commit** `5124375`.
- `lib/features/switcher/current_repo_indicator.dart` now holds `SessionInfoCard` (one top border),
  the private `_InfoRow`, `CurrentRepoIndicator` on `repositoryDisplayNameProvider`, and
  `CurrentLocationIndicator`.
- `app_shell.dart` mounts `SessionInfoCard` in place of `CurrentRepoIndicator`.
- `posix_path.dart` is no longer imported by the indicator, since the analyzer reported it unused.

**Plan-text correction.** Step 2 says the `_InfoRow` `Column` holds "then `trailing` when non-null".
That contradicts the same step's governing sentence, "these are exactly today's styles, lifted from
the current row": today the status cluster sits in the `Row`, after the `Expanded` column. The
implementation follows today's row, putting `trailing` in the `Row`. The step is left as written,
annotated here.

**Harness details, not deviations.**
- The parity test calls `controller.activate(tab.id)` after opening the second tab, so the tab under
  test is the active one, as it is in the app. The second tab did not disturb the first.
- `saved_workspace_set.dart` had to be imported for `SavedRepositoryKind`.
- Running two test files in one `flutter test` call, one of which could not compile, made the
  compiler exit and marked the other as failing too. Each red run was therefore repeated on its own.

**Red first**, each run on its own before the implementation:
- `session_info_card_test.dart` did not compile (`Method not found: 'SessionInfoCard'`); its
  mutations below are the evidence.
- `repository_name_parity_test.dart` compiled against the tree. P1 and P3 passed. **P2 failed on its
  second assertion, `reason: Repository row`**: `Found 0 widgets with text "Backend" descending from …
  CurrentRepoIndicator`. Its first assertion, the tab title, had passed, confirming that Phase 2
  already carried the tab onto the alias.
- `app_shell_test.dart`'s new test: `Found 0 widgets with text "Location"`. The six existing tests
  passed.

**Green.** Card `+6`, parity `+3`, shell `+7`. `current_repo_indicator_test.dart` `+4`, **unmodified**
(no diff). The 761×480 test passed with `takeException()` null, so the out-of-sidebar overflow the
plan warned of did not occur.

**Gate.** `dart format` set 2 test files and the check then reported 0 changed. `flutter analyze`: No
issues found (exit 0). Full `flutter test`: `+4181 ~3: All tests passed!` (exit 0), +10.

**Mutations** (scratch worktree at `5124375`, removed afterwards), all **killed**:

| # | mutation | failing test | failure |
|---|---|---|---|
| M3.1 | `'This Mac'` → `'Local'` | L3 | `This Mac` not found |
| M3.2 | tooltip loses `:port` | L1 | tooltip `deploy@build01.example.com:2222` not found |
| M3.3a | row value → hand-split basename | R1 | `Backend` not found |
| M3.3b | same mutation | parity P2 | `Found 0 widgets with text "Backend"` under `CurrentRepoIndicator` |
| M3.4 | `SizedBox(height: 600)` in the card | 761×480 layout | `RenderFlex overflowed by 464 pixels`; `Logout` bottom `909.0`, expected `<= 480` |

M3.3 uses an inline `split('/')` rather than `basename`, since the file no longer imports
`posix_path.dart`; the effect is identical.

### Phase 4, executed

**Code commit** `10dc081`. In `ConnectionSwitcher`:
- the four-field `select` became `isConnected` only;
- the `label` computation and its stale comment ("the label is the repo name") are gone;
- the `Text` reads `'Connections'`;
- the class doc says the label is fixed and the location lives in the card.

The early `SizedBox.shrink()`, glyph, style, `HoverPop` and `onPressed` are unchanged.

**Red first.** The two old label tests were replaced by B1–B3 and run before the change. B1 and B2
failed with `Found 0 widgets with text "Connections"`; B3 passed, as intended.

**Plan inconsistency, resolved by the plan's own intent.** Step 1 asks B3 both to "tap
`find.text('Connections')`" and to pass *before* the change. Before the change there is no
`Connections` text, so both cannot hold. B3 taps `find.byType(ConnectionSwitcher)` instead, which
keeps the purpose the plan gives it: pinning, across the change, that the button still opens the
manager. As a consequence, step 4's claim that M4.1 fails "B1, B2 and B3" cannot hold either: M4.1
changes only the label, which B3 no longer reads. The label is guarded by B1 and B2.

**Gate.** `dart format`: 0 changed. `flutter analyze`: No issues found (exit 0). Targeted: `+16: All
tests passed!`. Full `flutter test`: `+4182 ~3: All tests passed!` (exit 0), +1 net: two tests
replaced by three.

**Mutation** (scratch worktree at `10dc081`, removed afterwards). **M4.1**, `'Connections'` →
`'Manage'`, is **killed**: B1 and B2 fail (`[E]` on both).

### Phase 5, executed

**Final gate**, on `10dc081`: `flutter analyze` "No issues found!" (exit 0). Full `flutter test`:
`+4182 ~3: All tests passed!` (exit 0). That is **+22 on the Phase 0 baseline of 4160**, the figure step
1 predicted: 10 + 1 + 6 + 3 + 1 + 1.

**Status is `executed`, not `complete`.** Every automated criterion holds, and every mutation M1.1–M4.1
failed its named test; the only exception is B3, as explained under Phase 4. The Verification
section's manual check has not been run; only the maintainer can run it:
- in the built app, the card reads Repository / Location, and the button reads Connections;
- after **Rename Tab**, the tab, window title, Repository row and status bar all change together.

This plan becomes `complete` once that check is done.

**Commits:** `2eed288` (records), `f7d7b9d`, `54508dc`, `5124375` and `10dc081` (code), with one
execution-record commit per phase. None of them is pushed.

### Post-execution change (2026-09-18): location glyph parity, MADR Amendment 0052.1

The maintainer reported mismatched glyphs across the tab, status bar and Location row. This was a new
request after execution, not a deviation. It was executed under the same conventions:

**Code commit** `83c55ff`, 14 files:
- new: `lib/features/common/session_location.dart`;
- `repository_context.dart`: the `isLocal` field;
- `repository_context_bar.dart`, `tab_strip.dart` and `current_repo_indicator.dart`: the glyph now
  comes from `sessionLocationIcon`;
- the six pane files, seven sites: `isLocal: connection.isLocal`;
- tests: the parity test gains P4 (remote) and P5 (local) and mounts `SessionInfoCard` in place of the
  bare row; the source test gains the snapshot `isLocal` scan; L3 expects `folder`.

**Red first.**
- The scan found all 7 snapshot constructions and failed on `repo_status_view.dart builds a snapshot
  without isLocal`.
- P4 failed on `reason: both tab chips` (the tab showed `desktopcomputer`).
- P5 failed on `reason: Location row` (it showed `desktopcomputer`): the tab and status bar already
  showed `folder` for local. That is exactly the reported bug.

**Gate.** `dart format` set one file, then reported 0 changed. `flutter analyze`: No issues found; the
first run caught a `const` constructor around the function call, which was fixed. Full `flutter
test`: `+4185 ~3: All tests passed!` (+3).

**Goldens cannot see this change.** The 48 goldens passed unchanged. `flutter test` does not load the
icon font, so every glyph renders as the same placeholder box, and an icon swap is invisible to a
golden. The parity test asserts the `IconData` each surface is given, which is what can fail.

**Mutations** (scratch worktree at `83c55ff`, removed afterwards), all **killed**:

| # | mutation | failing test | on |
|---|---|---|---|
| I1 | swap the glyphs in `sessionLocationIcon` | P4, P5 | all surfaces |
| I2 | tab strip back to `desktopcomputer` | P4 | `reason: both tab chips` |
| I3 | status bar back to a fixed `folder` | P4 | `reason: status bar` |
| I4 | drop `isLocal:` from the Stashes snapshot | the snapshot scan | Stashes |

### Post-execution change (2026-09-18): manager and landing rows, MADR Amendment 0052.2

**Code commit** `42d409e`. `connection_switcher.dart` has four icon sites, and `connection_landing.dart`
has one, all moved to `sessionLocationIcon`. Tests: `connection_landing_test.dart` gains "recent rows
show the globe…". `connection_switcher_test.dart` gains M1–M3, and its `_pump` takes an optional
connection state.

**Red first.** All four new tests failed, each with `Found 0 widgets` for the expected glyph in the
named row:
- landing `app`;
- M1 `Build box`;
- M2 `adhoc.example.com (unsaved)`;
- M3 `proj (unsaved)`.

The finder picks the nearest `Row` above the title, so on its own a "found 0" could mean a finder that
never matches. The green run rules that out, since every one of those finders then finds exactly one
glyph.

**Gate.** `grep -rn desktopcomputer lib` finds nothing (exit 1). `dart format`: one file set, then 0
changed. `flutter analyze`: No issues found. Full `flutter test`: `+4189 ~3: All tests passed!` (+4).

**Mutations** (scratch worktree at `42d409e`, removed afterwards), all **killed**:

| # | mutation | failing test |
|---|---|---|
| J1 | saved SSH row back to `desktopcomputer` | M1 |
| J2 | unsaved SSH row back to `desktopcomputer` | M2 |
| J3 | active local row back to `folder_fill` | M1 (plain folder not found in `My Local Repo`) |
| J4 | unsaved local row back to `folder_fill` | M3 |
| J5 | landing remote row back to `desktopcomputer` | "recent rows show the globe…" |

