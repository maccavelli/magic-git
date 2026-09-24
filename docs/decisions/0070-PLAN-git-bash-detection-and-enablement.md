---
status: "in-progress"
date: 2026-09-23
associated-madr: "0070-MADR-native-windows-hosts-over-ssh.md"
verified: 2026-09-23
---

# Implement the first Windows slice: detect Git Bash, offer to make it the SSH shell, and list it as a dependency

Associated MADR:
[0070-MADR-native-windows-hosts-over-ssh.md](0070-MADR-native-windows-hosts-over-ssh.md)
(Amendment 0070.1 records why this slice comes first).

## Goal

Connecting to a Windows host whose SSH default shell is not Git Bash stops with a clear,
actionable prompt instead of "not a git repository":

* **Git Bash is installed but not the SSH shell:** a warning that says so, with:
  * an **Enable** button that sets it over the existing SSH connection;
  * the **exact PowerShell command** in a copyable field, for running it by hand in an elevated
    PowerShell;
  * **Reconnect**.
* **Git Bash is not found:** the prompt says so, gives the install command (`winget install --id
  Git.Git -e`), and points at Settings for a custom path.
* **Git Bash is already the SSH shell:** the connection proceeds on the existing POSIX layer, as
  MADR 0070's option O2 describes.

Git Bash appears in Settings beside `git`, `gh` and `glab`, with its own custom-path field, and in
the environment health sheet for Windows hosts.

## Scope

**Files, by phase.** Touching any other file is a deviation: stop and prompt.

| File | Phase | Change |
|---|---|---|
| `lib/core/ssh/windows_host_probe.dart` (new) | 1 | The PowerShell probe script, its encoded command line, the result type and parser, and the enable-command builder. |
| `lib/core/ssh/ssh_command_executor.dart` | 1 | `remoteVersion` getter; `executeRaw` for the few commands that must reach the host's own shell unformatted. |
| `lib/core/ssh/ssh_client_manager.dart` | 1 | Expose the connected client's `remoteVersion`. |
| `test/ssh_command_executor_test.dart` | 1 (D1) | `executeRaw` sends exactly the given text; `remoteVersion` passes through. |
| `test/shell_injection_canon_test.dart` | 1 (D1) | The probe's raw line under the canon's attack strings. |
| `test/host_script_coverage_test.dart` | 1 (D2) | `windowsHostProbeScript` registered as executed. |
| `test/provider_ref_after_await_scan_test.dart` | 3 (D3) | The allowlist keyed by provider name, not line number. |
| `lib/features/settings/settings_sheet.dart` | 5 (D4) | The override field's example path comes from the catalog. |
| `test/help_book_json_test.dart` | 5 (D5) | `windows_hosts` in the locked topic list (35 topics), and its label anchors. |
| `lib/core/settings/tool_catalog.dart` | 2 | A `bash` entry (Windows only), and Windows install hints. |
| `lib/core/ssh/environment_probe.dart` | 2 | `uname` values `MINGW*`, `MSYS*` and `CYGWIN*` map to `os: 'windows'`; the display name. |
| `lib/core/settings/app_settings.dart` | 2 | The doc comment listing overridable tools. |
| `lib/core/providers/app_providers.dart` | 3 | `ConnectionState.windowsShellPrompt`; the Windows check in `connect()`; `enableGitBashShell()`. |
| `lib/features/common/copyable_command_block.dart` (new) | 4 | The health sheet's copy row, extracted and made selectable. |
| `lib/features/settings/environment_health_sheet.dart` | 4 | Uses the shared block. |
| `lib/features/connection/windows_shell_prompt_sheet.dart` (new) | 4 | The prompt. |
| `lib/features/app_shell.dart` | 4 | Shows the prompt, as it shows the host-key prompt (`app_shell.dart:877`). |
| `macos/Runner/help_book.json` | 5 | A "Windows hosts" topic. |
| Tests (new) | 1–4 | `windows_host_probe_test.dart`, `windows_shell_prompt_test.dart`, `copyable_command_block_test.dart`. |
| Tests (existing) | 2–4 | `connection_env_reset_test.dart` or the connect-flow test it lives beside, plus any catalog or health-sheet test the `bash` entry changes. The exact list is recorded when Phase 2 runs, from the failures. |
| Records | 0, 5 | This plan, MADR 0070's amendment, `docs/README.md`, `docs/architecture.md` (one paragraph). |

**Out of scope, deliberately.**
* MADR 0070's layered dialect: the `GitBashBridge`, `WindowsArgv` and `HostPath` types, the
  PowerShell watcher, tree-kill and SFTP.
* Making every feature work under Git Bash. This slice gets a Windows host connected on the
  existing POSIX layer. Whatever still breaks under Git Bash is recorded in Phase 5's device gate
  and becomes input to the next plan, not a fix here.

## Facts this plan is built on

* The connect sequence is:
  1. handshake;
  2. `_resolveEnvironment` (the POSIX probe, `app_providers.dart:1476`);
  3. `validateRepoPath` (`:1530`).

  On a `cmd.exe` host step 2 fails silently (`environment_probe.dart:111-114`) and step 3 reports
  the wrong cause (0070 F3).
* Every command the executor sends goes through `CommandFormatter.format`
  (`ssh_command_executor.dart:910`), which prefixes POSIX text. There is no unformatted path, so the
  Windows probe needs one.
* `SSHClient.remoteVersion` exists (dartssh2 3.3.0, `ssh_client.dart:364`), and the client manager
  already logs it (`ssh_client_manager.dart:969`).
* `ConnectionState.hostKeyPrompt` (`app_providers.dart:806`), shown by a listener in `AppShell`
  (`app_shell.dart:877`), is the house pattern for a connect that needs the user's decision. It
  shows whichever flow started the connect: the form, a recent connection, or a reconnect.
* Tool paths: `binaryOverrides` is one global map keyed by tool name (`app_settings.dart:48`). The
  overridable list, the probe's `command -v` list and the health sheet all derive from
  `kToolCatalog` (`tool_catalog.dart:127`). A tool gets its Settings field by being in the catalog.
* The health sheet's copy row (`environment_health_sheet.dart:513`) is private: a label, a copy
  button, and a monospace block.
* Windows OpenSSH: the default shell is set by `HKLM\SOFTWARE\OpenSSH\DefaultShell`; the documented
  command is `New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell -Value "<path>"
  -PropertyType String -Force`, run elevated. PowerShell 5.1 is on every supported Windows, and
  `-EncodedCommand` takes Base64 of UTF-16LE (0070 F5, F7).
* `pwsh` 7 is installed on the development Mac (`/usr/local/bin/pwsh`), so the probe script can be
  parsed and partly run in tests here.

## Design decisions made in this plan

**D-a. Detect Windows without assuming a shell.** After the handshake, if `remoteVersion` contains
`Windows` (A1 in the MADR), the app sends **one raw command** that every Windows default shell runs
the same way:

```text
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand <Base64 UTF-16LE>
```

The Base64 alphabet contains no character that `cmd.exe`, PowerShell or bash treats specially, and
the argument `-EncodedCommand` does not look like a path, so MSYS leaves it alone. The fallback: if
`remoteVersion` does not name Windows but the POSIX probe's stderr carries the `cmd.exe` signature
(`is not recognized as an internal or external command`), the same probe runs. So a Windows host
behind a customised banner is still recognised.

**D-b. What the probe reports** (ASCII `KEY=value` lines, one per fact; nothing Git prints passes
through PowerShell):

| Key | Source |
|---|---|
| `MGW_PS` | `$PSVersionTable.PSVersion` |
| `MGW_DEFAULT_SHELL` | `Get-ItemPropertyValue HKLM:\SOFTWARE\OpenSSH DefaultShell`, empty if unset (unset means `cmd.exe`) |
| `MGW_GIT_ROOT` | `InstallPath` from `HKLM:\SOFTWARE\GitForWindows`, else `HKCU:\SOFTWARE\GitForWindows` |
| `MGW_BASH` | the first existing of: the Settings override for `bash` (passed into the script), `<root>\bin\bash.exe`, `%ProgramFiles%\Git\bin\bash.exe` |
| `MGW_GIT` | `(Get-Command git -ErrorAction SilentlyContinue).Source` |
| `MGW_ADMIN` | whether the session's token is in the Administrators role, so the prompt can say in advance whether **Enable** can work |

Every lookup uses `-ErrorAction SilentlyContinue`, so a missing key is an empty value, not a
failure.

**D-c. The decision table** (in `connect()`, before `_resolveEnvironment`):

| Default shell | Git Bash found | Outcome |
|---|---|---|
| a `bash.exe` path | — | proceed; the POSIX layer runs |
| anything else | yes | stop; `windowsShellPrompt` = *installed, not active* |
| anything else | no | stop; `windowsShellPrompt` = *not installed* |
| (probe failed) | — | stop with the probe's own error text, never "not a git repository" |

**D-d. Enable.** **Enable** runs the documented `New-ItemProperty` command through the same raw
encoded path, with the discovered `bash.exe` path.
* **On success:** reconnect automatically, because `sshd` reads `DefaultShell` when it starts a
  session. This is assumption A10, checked in Phase 5; if it needs a service restart, the prompt
  says so and offers `Restart-Service sshd` as a second copyable command.
* **On access denied:** the prompt keeps the copyable command and explains that it must be run in
  an elevated PowerShell on the host.
* **Nothing else is ever changed on the host.** In particular not `New-Item -Force` on the key,
  which in the registry provider would replace the key's other values.

**D-e. The exact command shown** is built by one function and shown byte-for-byte as run:

```powershell
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Program Files\Git\bin\bash.exe' -PropertyType String -Force
```

Single-quoted, with any `'` in the path doubled (PowerShell's literal-string rule).

**D-f. The Settings entry.** A catalog entry:
`ToolSpec(bin: 'bash', tier: ToolTier.essential, onlyOs: 'windows', purpose: 'Windows hosts: Git
Bash, from Git for Windows, runs Magic Git's commands as the OpenSSH default shell.', docsUrl:
'https://gitforwindows.org/')`.

It gets the custom-path field automatically. The value is a Windows path; the probe tests it first
(D-b). `relevantOn('windows')` keeps it out of the doctor on POSIX hosts, and on a disconnected
panel it is listed like the others. The POSIX probe resolving `bash` on Linux hosts is harmless: no
command's `argv[0]` is `bash` (the inventory in MADR 0070 found none), so the rewrite never fires.
Phase 2 pins that with a test.

## Implementation Steps

Each phase ends with `flutter analyze`, the phase's tests, `dart format --set-exit-if-changed` on
touched files, and one commit (`git commit --no-edit`). A step that cannot be done as written is a
deviation: stop and prompt.

### Phase 0 — Records and negative rehearsal

0.1. MADR 0070 Amendment 0070.1; `docs/README.md` row for this plan.
0.2. In a scratch clone of `HEAD`, write each new test file and run it against the unmodified
     tree. Expected: compile failures for missing symbols, recorded as such. The behavioural
     negatives follow in each phase, and each check is seen to fail before its code lands.

### Phase 1 — The probe and the raw path

1.1. `ssh_client_manager.dart`: `remoteVersion` of the current client.
1.2. `ssh_command_executor.dart`:
     * `String? get remoteVersion`;
     * `Future<SSHCommandResult> executeRaw(String command, {Duration timeout, ExecLane lane})`,
       sent to `client.execute` exactly as given, with the existing byte budget, telemetry and lane
       scheduling, and without `CommandFormatter`.

     The doc comment states the contract: callers pass only commands whose every character is
     safe under any shell, as Base64 is. ~~The file's injection canon test is extended to scan
     `executeRaw` call sites and fail if any passes anything but a `WindowsHostProbe` constant or
     builder output.~~ **Replaced (D1):** pinned behaviourally. `shell_injection_canon_test.dart`
     feeds its attack strings in as the Settings Bash path and asserts the raw line is the fixed
     prefix plus Base64 only, with the attack text only inside a PowerShell literal once decoded.
     `ssh_command_executor_test.dart` asserts, through `FakeSshClient`, that `executeRaw` sends
     exactly the given text.
1.3. `windows_host_probe.dart`:
     * `const kWindowsHostProbeScript` (the PowerShell of D-b, with a `{{BASH_OVERRIDE}}` slot
       filled by a single-quoted literal);
     * `String encodedPowerShellCommand(String script)` (UTF-16LE → Base64 → the D-a line);
     * `WindowsHostFacts.parse(String stdout)`;
     * `bool isWindowsBanner(String? remoteVersion)`;
     * `bool looksLikeCmdExe(String stderr)`;
     * `String enableGitBashCommand(String bashPath)` (D-e).
1.4. Tests (`windows_host_probe_test.dart`):
     * **Parser:** full facts; missing keys; CRLF endings; an extra banner line; empty output.
     * **Encoding:** decoding the Base64 as UTF-16LE gives back the script exactly; the line
       contains only `[A-Za-z0-9+/= .-]`.
     * **Enable command:** golden for the standard path; a path containing `'`; a path with
       spaces.
     * **Under `pwsh` (skipped with a stated reason when `pwsh` is absent):**
       * the script parses with no errors (`[System.Management.Automation.Language.Parser]::ParseInput`);
       * run with `-EncodedCommand` on macOS, where there is no registry, it prints every key with
         empty values and exits 0. This is the "missing key is empty, not a failure" contract.
     * **Seen to fail:** each of these is run once against a deliberately broken builder or parser
       in the scratch clone, and the failure is recorded.

### Phase 2 — Git Bash as a dependency

2.1. `tool_catalog.dart`:
     * the D-f entry;
     * `installHints` for `os == 'windows'`: `git`/`bash` → `winget install --id Git.Git -e`;
       `gh` → `winget install --id GitHub.cli -e`; `glab` → `winget install --id GLab.GLab -e`.
2.2. `environment_probe.dart`: `MINGW*`, `MSYS*` and `CYGWIN*` → `'windows'`; display name
     `Windows`.
2.3. `app_settings.dart`: the doc comment's tool list.
2.4. Tests:
     * `bash` is overridable and relevant only on `windows`;
     * the Settings sheet shows a Bash path field;
     * a `MINGW64_NT-10.0` probe line maps to `windows`;
     * no remote command's `argv[0]` is `bash`: a scan of `lib/` for `gitArgs: ['bash'` that must
       stay empty, seen to fail by adding one in the scratch clone;
     * existing tests that count catalog entries or health rows are updated, each named in the
       execution record.

### Phase 3 — The connect decision

3.1. `ConnectionState.windowsShellPrompt` (a `WindowsShellPrompt` value: `kind` {`notActive`,
     `notInstalled`, `probeFailed`}, the facts, and the enable command), cleared on every new
     connect like `hostKeyPrompt`.
3.2. In `connect()`, after the handshake and before `_resolveEnvironment`: run D-a and D-c. Stop
     with the prompt set and `phase` failed, and an `error` that names the real cause, e.g. "This
     Windows host's SSH shell is cmd.exe; Magic Git needs Git Bash as the shell." The attempt-token
     checks mirror the surrounding code.
3.3. `_resolveEnvironment`'s failure path: when its stderr matches `looksLikeCmdExe`, run the
     Windows probe (the D-a fallback) instead of returning an empty environment.
3.4. `enableGitBashShell()`:
     * runs the enable command raw;
     * on success, reconnects with the same profile;
     * on failure, keeps the prompt with the host's error text.
3.5. Tests, with fakes in the style of `connection_env_reset_test.dart`:
     * a Windows banner with the shell unset and Git Bash present → prompt `notActive`, and
       `validateRepoPath` never runs;
     * not present → `notInstalled`;
     * shell = bash → no prompt, and the connect proceeds;
     * a POSIX host → the probe is never sent;
     * enable succeeds → a second connect with the same profile;
     * enable is denied → the prompt stays, with the text.

     Each is seen to fail against a mutated decision table in the scratch clone.

### Phase 4 — The prompt and the copyable command

4.1. `copyable_command_block.dart`: a label, a Copy button (`Clipboard.setData`), and a
     `SelectableText` in the existing monospace style. It replaces `_hintRow`'s body, and the health
     sheet's visible output is unchanged.
4.2. `windows_shell_prompt_sheet.dart`: title and one-paragraph cause per kind; for `notActive`,
     the found path, **Enable**, the copyable command (D-e), and a note that it needs an
     administrator (worded from `MGW_ADMIN`). For `notInstalled`, the winget command and **Open
     Settings** to set a custom Bash path. **Reconnect** and **Cancel** in both.
4.3. `app_shell.dart`: a listener on `windowsShellPrompt`, beside the host-key listener, showing
     the sheet.
4.4. Tests:
     * each kind renders its text;
     * **Copy** puts the exact D-e string on the clipboard (via the platform clipboard mock);
     * the command text is selectable;
     * **Enable** calls the notifier;
     * the health sheet still renders its hints (existing tests), now through the shared block.

     The copy test is seen to fail by copying a trimmed string in the scratch clone.

### Phase 5 — Device gate and records

5.1. `./build_macos.sh --unsigned`, with `--install` only if the maintainer asks.
5.2. **On the maintainer's Windows host**, each recorded PASS/FAIL with what was seen. The
     repository's hooks path is pinned, so no AI hook runs:

     | Item | Steps | PASS when |
     |---|---|---|
     | A1 banner | Connect; read the log line `SSH handshake remote=…`. | It names Windows. |
     | Not active | With the default shell unset, connect. | The prompt appears with the Git Bash path; no "not a git repository". |
     | Copy | Press Copy; paste into an elevated PowerShell on the host. | It runs without edits. |
     | Enable | Press Enable from an administrator account. | The key is set (`Get-ItemProperty HKLM:\SOFTWARE\OpenSSH`), and the reconnect proceeds (A10). |
     | Denied | Press Enable from a standard account. | The prompt stays and says why; nothing on the host changed. |
     | Git Bash active | Connect again. | Connected; status and history load. Every feature seen failing is listed, not fixed. |
     | Settings | Set a custom Bash path; reconnect. | The probe reports that path. |
5.3. MADR 0070: record A1 and A10 as confirmed or amended, plus the failures listed in 5.2's last
     rows, as input to the next plan. `docs/architecture.md`: one paragraph ("Windows hosts are
     supported when Git Bash is their SSH shell; the app detects and offers it").
     `docs/README.md` statuses.
5.4. `dart run scripts/tools/records.dart check` → `0 finding(s)`; the docs tests pass; commit.
     (Path updated 2026-09-23: `tool/` moved to `scripts/tools/` in `394665d`.)

## Verification

| Check | Command | Pass condition |
|---|---|---|
| Static analysis | `flutter analyze` | `No issues found!` |
| Probe, encoding, enable command | `flutter test test/windows_host_probe_test.dart` | all pass; the `pwsh` cases run here, not skipped |
| Connect decision | `flutter test test/connection_env_reset_test.dart` (and the Phase 3 file) | all pass |
| Prompt and copy | `flutter test test/windows_shell_prompt_test.dart test/copyable_command_block_test.dart` | all pass |
| Injection canon | `flutter test test/shell_injection_canon_test.dart` | passes; `executeRaw` sites limited |
| Full suite | `flutter test > "$LOG" 2>&1; STATUS=$?` | `STATUS` 0; 0 `[E]` |
| Each new check | scratch clone, mutated code | seen to fail, message recorded |
| Device | Phase 5.2 | every row recorded |
| Records | `dart run scripts/tools/records.dart check` | `0 finding(s)` |

## Acceptance Criteria

* AC1 — Connecting to a Windows host never reports "not a git repository" because of the shell; it
  reports the shell.
* AC2 — With Git Bash installed but not active, the prompt shows the discovered path, an Enable
  action, and the exact command, copyable byte-for-byte.
* AC3 — Enable, from an administrator account, sets `DefaultShell` and the reconnect proceeds;
  from a standard account it changes nothing and says why.
* AC4 — With Git Bash not found, the prompt gives the install command and a route to the Settings
  path field.
* AC5 — Git Bash is listed in Settings with a custom-path field and in the health sheet on Windows
  hosts; the override is used by the probe.
* AC6 — POSIX hosts behave exactly as before: no Windows probe is sent, and no command changes.
* AC7 — Every new check was seen to fail, with its failure recorded; full suite green after each
  phase.
* AC8 — Phase 5's rows are recorded, including what does not yet work under Git Bash.

## Rollout and Rollback

Rollout is the next `./build_macos.sh --unsigned --install`. The only host-side change is the one
registry value the user chooses to set, by pressing Enable or running the command.

Rollback of the app is `git revert` of the phase commits, newest first. Rollback on a host is the
inverse command, shown in the help topic:

```powershell
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell
```

That restores `cmd.exe` for every SSH user of that host. The prompt says, before Enable, that the
setting is machine-wide.

## Execution record

* **Approved (maintainer, 2026-09-23):** "accept the madr, plan approved to proceed." MADR 0070 → `accepted`; this plan → `in-progress`.
* **D1 (2026-09-23, deviation, Phase 1): step 1.2's source scan contradicts the file it was to go in.**
  * **Evidence.** Step 1.2 asked for `shell_injection_canon_test.dart` to scan `executeRaw` call
    sites. That file's header records the opposite decision (MADR 0017 G2): it is deliberately not a
    source scan, because scans there were ~90% noise, and it asserts the injection property by driving
    real code with attack strings. Found while writing Phase 1; nothing was committed.
  * **Resolutions offered:**
    1. behavioural: the canon test drives the probe builders with its attack strings, and
       `ssh_command_executor_test.dart` pins `executeRaw` through `FakeSshClient`;
    2. a narrow scan in a new file;
    3. both.
  * **Decision (maintainer, 2026-09-23): option 1.** Step 1.2 is struck through and annotated above.
  * **Files added to scope:** `test/ssh_command_executor_test.dart`,
    `test/shell_injection_canon_test.dart`, both listed in the Scope table.
* **D2 (2026-09-23, deviation, Phase 1): two of the repository's own guards fire on the new script.**
  * **Evidence.** The full suite after Phase 1's code: `+4342 ~3 -2`, the two failures being guards,
    not behaviour:
    * `host_script_coverage_test.dart` (MADR 0029): "a new host script must be executed by a test
      or added to _exempt with a reason. Unclassified: {windowsHostProbeScript}". The script *is*
      executed, under `pwsh` in `windows_host_probe_test.dart`, but is not registered;
    * `assertion_strength_scan_test.dart` (MADR 0030): D1's canon case asserts on the script's text
      and `shell_injection_canon_test.dart` runs no process: "these assert on a generated script's
      text without executing it".
  * **Resolutions offered:**
    1. register the builder as executed, and make the canon case run the probe under `pwsh` with
       attack strings as the Bash path, asserting no side effect;
    2. register it, and list the canon file as composition-only.
  * **Decision (maintainer, 2026-09-23): option 1.** The executing case uses its own harmless
    payloads, each trying to `touch` a sentinel in a temp directory. The canon's shared payloads
    include `rm -rf /`, which is fine as text but must never be run, not even by a mutation that
    breaks the quoting.
  * **Files added to scope:** `test/host_script_coverage_test.dart`.
* **D3 (2026-09-23, deviation, Phase 3): a guard keyed by line numbers went stale.**
  * **Evidence.** After Phase 3's code the full suite failed in
    `provider_ref_after_await_scan_test.dart` (MADR 0050) with four "offenders" at
    `app_providers.dart:3855, 5026, 5984, 6067`. Each is a site the test had already reviewed and
    allowed, keyed `3597, 4768, 5726, 5809`: `autoFetchProvider`, `remoteTagsProvider`,
    `forgeProvider` and `forgeRepoListProvider`, pushed down 258 lines by the Windows prompt model
    and methods. Matched line for line against `HEAD`. No new ref-after-await site was added.
  * **Resolutions offered:**
    1. key the allowlist by the flagged provider's name;
    2. update the four line numbers.
  * **Decision (maintainer, 2026-09-23): option 1.** Line keys break on any edit above them in a
    6,000-line file, which would recur in this plan's later phases. The scan reports the name of the
    provider it flags.
  * **Files added to scope:** `test/provider_ref_after_await_scan_test.dart`.
* **D4 (2026-09-23, maintainer direction): the Bash field shows a Windows example.**
  * **Found in Phase 2 and reported at Phase 4's close:** the Bash override field's placeholder was
    the generic `/path/to/bash (optional)`, a POSIX path for a value that is always a Windows path.
    `settings_sheet.dart` was not in the plan's files.
  * **Decision (maintainer, 2026-09-23):** "make it a windows example obviously."
  * **Done.** `ToolSpec.examplePath`, with `pathExample` defaulting to `/path/to/<bin>`. The `bash`
    entry carries `C:\Program Files\Git\bin\bash.exe`, and the Settings field reads it from the
    catalog, which keeps the catalog the single source.
    `tool_catalog_single_source_test.dart` now expects that placeholder for `bash` and the default
    for the rest. **Red first:** on the old field it failed with "no Settings path field for bash".
  * `flutter analyze`: No issues found. Full suite: `03:05 +4386 ~3: All tests passed!`, 0 `[E]`.
  * **Files added to scope:** `lib/features/settings/settings_sheet.dart`.
* **D5 (2026-09-23, deviation, Phase 5): the help topic needs the help test's locks.**
  * **Evidence.** The scope's `help_book.json` row adds a "Windows hosts" topic, but
    `help_book_json_test.dart` locks each category's topic IDs in order, and the total at 34 ("0053
    locks 34 topics in 7 categories"). A new topic cannot land without editing it, and the file is
    not in the plan. (`HelpDataModelTests.swift` counts topics in a fixture, not the book, so it is
    unaffected.)
  * **Resolutions offered:**
    1. a new topic in Getting Started after Connections Manager, with the test's lock and label
       anchors updated;
    2. a section inside the existing Connecting topic, with no test change.
  * **Decision (maintainer, 2026-09-23): option 1.** The anchors are the prompt's own titles and its
    command label, so renaming the prompt fails the suite until Help follows (0053's rule).
  * **Files added to scope:** `test/help_book_json_test.dart`.
  * **Done.** A **Windows Hosts** topic after Connections Manager covers:
    * why Git Bash is needed;
    * the prompt's Enable, the copyable command, Reconnect and Cancel;
    * the administrator requirement;
    * a warning callout that the setting is machine-wide, with the undo command;
    * the not-installed case with the winget command and the Settings path.

    It was inserted as text, not by re-serialising the book, and parsed back and compared with the
    intended topic. **Red first:** the updated test failed on the old book in "every locked topic id
    exists in its category, in order" and "quoted UI labels exist in their topic and in source".
    After the change: `help_book_json_test.dart` `+16`, all pass.
* **Phase 5 (2026-09-23), device gate on the maintainer's Windows 11 laptop.**
  * 5.1: `./build_macos.sh --unsigned --install` (1.9.3.8), at the maintainer's request. The
    running copy was quit with ⌘Q and confirmed, and the installed build launched.
  * 5.2, row by row:

    | Item | Result | Evidence |
    |---|---|---|
    | A1 banner | **PASS** | The host's identification string, read from its port 22 with no login: `SSH-2.0-OpenSSH_for_Windows_9.5`. |
    | Not active | **PASS** (maintainer) | Earlier the same day, the prompt appeared on connect, with no "not a git repository". |
    | Enable | **PASS** (maintainer) | Pressed from an administrator account; the connection then worked. The host now runs commands through `/usr/bin/bash` (seen in the Output view). This also answers **A10**: the changed shell applied to the next connection with no `sshd` restart, per the maintainer's account. |
    | Git Bash active | **PASS** | The installed build, driven: connected in 1.0 s (ssh 298 ms, environment 648 ms, repo check 88 ms); Status (2 changed, ahead 1) and the file tree load; History lists commits; a commit's detail and diff render. |
    | Copy | **not run** | Byte-for-byte copy is covered by `copyable_command_block_test.dart`; the paste into an elevated PowerShell was not done. |
    | Denied | **not run** | Needs a standard (non-administrator) account on the host. The same path, exit 1 with the reason, runs for real under `pwsh` in `windows_host_probe_test.dart`. |
    | Settings path | **not run** | Its effect is visible only while the prompt is showing, and the host's shell is now Git Bash. |

  * **Found at the gate, not fixed here** (input to the next 0070 plan):
    * **Windows paths are named by the whole path.** The tab, window title, sidebar and Recent
      Repositories show `C:\Users\<user>\gitrepos\<repo>` where POSIX repositories show the
      folder name: the label takes the text after the last `/`. This is MADR 0070's `HostPath`
      work.
    * **Live refresh polls:** `arm unavailable: noTool`, as designed. MADR 0070's PowerShell
      watcher is the fix.
    * **A watcher sweep fails on a quoted `~`:** `watcher sweep skipped ~/gitrepos/<repo>: … cd:
      ~/gitrepos/<repo>: No such file or directory`. That path is not the open repository, and a
      quoted `~` is never expanded. It is not specific to Windows; it is traced separately.
* **Phase 0 (2026-09-23).** Records: MADR 0070 `accepted`, this plan `in-progress`, the index row.
  The negative rehearsal ran per phase, not up front: each new check was run against deliberately
  broken code in a scratch clone (`p1-clone`) before the phase was committed, which is the stronger
  form of 0.2's "compile failures" (a missing symbol proves nothing about a check).
* **Phase 1 (2026-09-23).**
  * `windows_host_probe.dart`: the D-b script (`Get-ItemProperty` for the two registry reads, the
    same values D-b names), `windowsHostProbeScript({bashOverride})`, `encodedPowerShellCommand`,
    `WindowsHostFacts.parse`, `isWindowsBanner`, `looksLikeCmdExe`, `enableGitBashCommand`,
    `kDisableGitBashCommand`, `powerShellLiteral`.
  * `ssh_client_manager.dart` and `ssh_command_executor.dart`: `remoteVersion`, and `executeRaw`,
    which passes `rawCommand` down `_run`/`_runBody` so the lane, generation pinning, byte budget,
    telemetry (label `<raw host command>`) and timeout cleanup are the same code as every other
    command. Compression is off for raw commands.
  * **Tests.**
    * `windows_host_probe_test.dart`: 14 cases. Under `pwsh` (7, on this Mac) the script parses
      clean and runs. A clarification of step 1.4's wording: "prints every key with empty values"
      holds for the Windows-only keys (`DEFAULT_SHELL`, `GIT_ROOT`, `BASH`, `ADMIN`=0). `PS` and
      `GIT` are real values on a Mac, and the test asserts exactly that split.
    * One check, the parse, first read the script from stdin, which `Process.runSync` does not
      provide, so it parsed an empty string and could not fail. Fixed before any mutation run: it
      parses the real script from a file and requires at least 50 tokens.
  * **Seen to fail** (`mutate_p1.py`, scratch clone), 7 of 7 caught, each by the test meant to catch
    it:
    * a syntax error (parse and run);
    * `exit 3` (run);
    * big-endian encoding (decode, run);
    * an unescaped literal (literal, apostrophe);
    * the bare `bash.exe` spelling (shell recognition);
    * `New-Item -Force` (golden, never-replaces);
    * a dropped key (run).
  * **D1 tests** (`mutate_p1b.py`), 3 of 3 caught:
    * `executeRaw` formatting anyway → "executeRaw sends exactly the given text";
    * an unescaped literal, and the override spliced raw → the canon's text case.
  * **D2 tests** (`mutate_p1c.py`, the executing case alone, `--plain-name`), 2 of 2 caught:
    * with escaping broken, a payload left its literal and **created the sentinel file**, which the
      probe then reported as the Bash it found: `Actual: '…/mgw_canon_…/pwned'`;
    * spliced raw, the script failed to run (`Expected: <0>`, `Actual: <1>`).
  * `flutter analyze`: No issues found. Full suite: `03:03 +4360 ~3: All tests passed!`, 0 `[E]`.
* **Phase 2 (2026-09-23).**
  * `tool_catalog.dart`: the D-f `bash` entry, placed after `git`, with `onlyOs: 'windows'`. Windows
    install hints: `git` and `bash` → `winget install --id Git.Git -e` (one install for both); `gh`
    and `glab` → their winget ids. The generic unknown-host Homebrew hint now excludes `bash` as
    well as `inotifywait`: "brew install bash" is not Git Bash.
  * `environment_probe.dart`: `MINGW*`, `MSYS*` and `CYGWIN*` → `windows`, label `Windows`.
    `app_settings.dart`: the doc comment.
  * **What else reads `os`.** Every branch on the OS value was checked:
    * `install_planner.dart` plans nothing for `windows`, and says there is no supported package
      manager. The winget hints are shown instead;
    * sideload rows are limited to `linux`/`macos`;
    * `tool_health.dart` and the sheets only distinguish `unknown`.

    No other change was needed.
  * **Existing tests changed by the entry: none.** The full suite passed with the entry and no test
    edits.
  * **New tests.**
    * `tool_catalog_test.dart`: Windows-only relevance and tier, winget hints, no Homebrew hint for
      `bash`, and the argv[0] scan over `lib/`.
    * `environment_probe_test.dart`: the three `uname` spellings map to `windows`.
    * `tool_catalog_single_source_test.dart`: the Settings sheet shows a path field for every
      overridable binary, `bash` included. That file is the catalog's derivation test, the natural
      home for "a catalog entry is all it takes".
  * **Seen to fail** (`mutate_p2.py`), 5 of 5 caught, each by its intended test:
    * no `bash` entry (Settings field, relevance);
    * no Windows hints;
    * a Homebrew hint for `bash`;
    * MINGW unmapped;
    * a mutant `['bash', '-c', 'true']` in `lib/` (the scan).
  * **Noted for the device gate, not changed:** the Bash row's placeholder is the generic
    `/path/to/bash (optional)`. Its value will be a Windows path (`C:\Program Files\Git\bin\bash.exe`),
    and `settings_sheet.dart` is not in this phase's files.
  * `flutter analyze`: No issues found (after sorting one import block the new test added). Full
    suite: `03:00 +4366 ~3: All tests passed!`, 0 `[E]`.
* **Phase 3 (2026-09-23).**
  * `app_providers.dart`:
    * `WindowsShellPromptKind`, `WindowsShellPrompt` (message, current shell, enable command,
      `enabling`, `enableError`), `WindowsShellSetupRequired`;
    * `ConnectionState.windowsShellPrompt` with `clearWindowsShellPrompt`;
    * `_checkWindowsShell` before `_resolveEnvironment`, with the D-a fallback on
      `CmdExeShellDetected`;
    * a catch branch that stops **without dropping the transport**, so Enable can run over it.
      Step 3.1 said "cleared on every new connect like `hostKeyPrompt`", which holds because every
      connect replaces the state;
    * `enableGitBashShell()`, `retryConnect()` and `dismissWindowsShellPrompt()`. Dismissal
      releases the transport.
  * `environment_probe.dart`: `CmdExeShellDetected`, raised only when a failed probe's stderr
    matches `looksLikeCmdExe`. `_resolveEnvironment` rethrows it only on the connect path
    (`attempt != null`); `reprobeBinaries` still logs.
  * `windows_host_probe.dart`: `enableGitBashScript`, which wraps the displayed command
    byte-for-byte in `try`/`catch` so the exit code distinguishes set (0) from denied (1, reason on
    stderr). It is a new host-script builder, so under D2's rule it is run: under `pwsh` on a Mac
    it exits 1 with the reason, the denied path for real. It is registered in
    `host_script_coverage_test.dart`.
  * **Tests** (`connection_env_reset_test.dart`), 8 cases with a fake Windows host:
    * the three D-c outcomes;
    * a POSIX host never probed;
    * Enable succeeding (reconnects, connected on the POSIX layer, `os` = `windows`);
    * Enable denied (the host's words kept);
    * the `cmd.exe` fallback behind a non-Windows banner;
    * dismissal releasing the transport.

    Two first drafts asserted exact event lists and failed, because a background read after
    `connected` adds a `validate`. They now assert order, as the file's existing test does.
  * **Seen to fail** (`mutate_p3.py`), 10 of 10 caught, each by its intended test:
    * the banner ignored (also breaks three existing connect tests, whose fakes have no raw path);
    * bash-as-shell not accepted;
    * the two kinds swapped;
    * the prompt dropping the transport;
    * no `cmd.exe` fallback;
    * the `cmd.exe` signal swallowed;
    * Enable not reconnecting;
    * an Enable failure dropped;
    * dismissal keeping the transport;
    * the enable script always exiting 0.

    **A first run of this was invalid and is superseded.** The scratch clone's `git pull` had failed
    silently, the tree did not compile, and "caught" meant only a compile error. The runner now
    re-clones fresh and refuses to mutate unless the baseline passes. The Phase 1 and 2 runs had
    passing baselines (`+14`, `+62`, `+21`, `+46`), so they stand.
  * **D3's guard, checked** (`mutate_d3.py`, fresh clone):
    * an allowlist entry removed fails, naming `#remoteTagsProvider`;
    * 50 lines inserted above everything passes, which is the point;
    * a new provider using `ref` after `await` fails, naming `#mutantProbeProvider`.
  * `flutter analyze`: No issues found. Full suite: `03:08 +4375 ~3: All tests passed!`, 0 `[E]`.
* **Phase 4 (2026-09-23).**
  * `copyable_command_block.dart`: the health sheet's copy row extracted, with the command now a
    `SelectableText` (the app's existing `show SelectableText` import). The health sheet's
    `_hintRow` renders it; the look is the same, and its existing tests pass unchanged.
  * `windows_shell_prompt_sheet.dart`: a `ConsumerWidget` that watches
    `connectionProvider.windowsShellPrompt`, so "Enabling…" and an Enable error update the open
    sheet. It shows, per kind:
    * **not active:** title, cause, Bash path, the machine-wide note, the non-administrator note
      when `MGW_ADMIN` is 0, the Enable error, the copyable command, the undo command, and
      Cancel / Reconnect / Enable;
    * **not installed:** the winget command and Cancel / Open Settings / Reconnect;
    * **probe failed:** the reason and Cancel / Reconnect.
  * `app_shell.dart`: a listener keyed on the prompt's *presence*, beside the host-key listener. It
    shows the sheet in its own route and pops exactly that route when the prompt clears (Reconnect,
    or Enable's reconnect). Any other close (Esc, a teardown) releases the session, as Cancel does.
  * **Tests.**
    * `copyable_command_block_test.dart`: byte-exact copy (special characters, a doubled
      apostrophe, a trailing space), and the command is selectable.
    * `windows_shell_prompt_test.dart`, 9 cases:
      * each kind's text and buttons, with a fake controller recording calls;
      * the non-admin note;
      * no second Enable while enabling;
      * a failed Enable's words shown;
      * **through `AppShell` against a fake Windows host:** a stopped connect shows the prompt and
        Cancel releases the session; Esc does the same; Reconnect after the shell is fixed closes
        the sheet and connects.
    * Drafting fixes:
      * one case re-pumped a `ProviderScope` with new overrides, which Riverpod does not allow, so
        it is split in two;
      * the connected case left session timers pending at teardown, so it now disconnects first,
        as the app would.
  * **Seen to fail** (`mutate_p4.py`, fresh clone, baseline `+11` first), 8 of 8 caught:
    * copy trimming the command;
    * the command not selectable;
    * Enable wired to Reconnect;
    * Enable live while enabling;
    * the admin note inverted;
    * the prompt never shown;
    * **the prompt never closed**;
    * Esc keeping the session.

    **"Never closed" was missed on the first run.** Once the prompt cleared, the sheet rendered
    nothing, so its title vanished while its route and barrier stayed open, which is exactly the
    defect. The AppShell cases now assert that the sheet widget itself is gone, and the rerun
    catches it in two cases.
  * `flutter analyze`: No issues found. Full suite: `03:00 +4386 ~3: All tests passed!`, 0 `[E]`.
  * **Carried to Phase 5:** ~~the Settings Bash row's generic `/path/to/bash (optional)`
    placeholder (noted in Phase 2)~~ resolved by D4; and the device gate itself.
