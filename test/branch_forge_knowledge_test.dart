// `branchForgeProvider` cannot tell "no open requests" from "the network was
// down": every failure mode collapses to `const {}` and it never reports an
// error. That is fine for painting a badge and fatal for a facet that reasons
// about absence — a "No request" filter built on it would list every branch in
// the repo the moment a fetch failed.
//
// These pin the distinction `branchForgeKnowledgeProvider` exists to make.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/forge/branch_forge_status.dart';
import 'package:remote_magic_git/core/forge/forge.dart';
import 'package:remote_magic_git/core/github/models.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';

const _repo = '/repo';

ProviderContainer _container({
  required Forge forge,
  List<PullRequest>? prs,
  List<WorkflowRun>? runs,
  bool forgeThrows = false,
  bool prsThrow = false,
}) {
  final container = ProviderContainer(
    overrides: [
      forgeProvider(_repo).overrideWith((ref) async {
        if (forgeThrows) throw Exception('detection failed');
        return forge;
      }),
      pullRequestsProvider(_repo).overrideWith((ref) async {
        if (prsThrow) throw Exception('network down');
        return prs ?? const <PullRequest>[];
      }),
      workflowRunsProvider(
        _repo,
      ).overrideWith((ref) async => runs ?? const <WorkflowRun>[]),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a GitHub repo with genuinely nothing open is KNOWN empty', () async {
    final container = _container(forge: Forge.github);

    final k = await container.read(branchForgeKnowledgeProvider(_repo).future);

    expect(k.byShortName, isEmpty);
    expect(
      k.known,
      isTrue,
      reason: '"no open requests" is a real answer when the forge replied',
    );
  });

  test('a failing request list is NOT known — the same empty map, opposite '
      'meaning', () async {
    final container = _container(forge: Forge.github, prsThrow: true);

    final k = await container.read(branchForgeKnowledgeProvider(_repo).future);

    expect(k.byShortName, isEmpty);
    expect(
      k.known,
      isFalse,
      reason: 'this is exactly the case branchForgeProvider cannot express',
    );
    expect(k.forge, Forge.github);
  });

  test('a failed forge detection is unavailable', () async {
    final container = _container(forge: Forge.github, forgeThrows: true);

    final k = await container.read(branchForgeKnowledgeProvider(_repo).future);

    expect(k.known, isFalse);
    expect(k.forge, Forge.unknown);
  });

  test('a repo with no forge remote is known — it definitively has no open '
      'requests', () async {
    final container = _container(forge: Forge.none);

    final k = await container.read(branchForgeKnowledgeProvider(_repo).future);

    expect(k.known, isTrue);
    expect(k.forge, Forge.none);
    expect(k.byShortName, isEmpty);
  });

  test('an unrecognized host is not known', () async {
    final container = _container(forge: Forge.unknown);

    final k = await container.read(branchForgeKnowledgeProvider(_repo).future);

    expect(k.known, isFalse);
  });

  test(
    'real request data is carried through and keyed by short name',
    () async {
      final container = _container(
        forge: Forge.github,
        prs: const [
          PullRequest(
            number: 7,
            title: 'Add the parser',
            state: 'open',
            merged: false,
            draft: false,
            headRefName: 'feat',
            baseRefName: 'main',
            url: 'https://example.test/7',
          ),
        ],
      );

      final k = await container.read(
        branchForgeKnowledgeProvider(_repo).future,
      );

      expect(k.known, isTrue);
      expect(k.byShortName['feat']?.hasRequest, isTrue);
      expect(k.byShortName['feat']?.requestNumber, 7);
    },
  );

  test('branchForgeProvider still yields the plain map, so badge painting is '
      'unchanged', () async {
    final container = _container(forge: Forge.github, prsThrow: true);

    final map = await container.read(branchForgeProvider(_repo).future);

    expect(map, isEmpty);
  });
}
