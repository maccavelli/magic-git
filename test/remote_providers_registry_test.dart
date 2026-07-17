// The remote-facing branch/tag providers must be in the shared refresh
// registry: ⌘R is the user's explicit "re-check the remote" gesture (the tag
// badges have no other refresh path when auto-fetch is off), and connection
// resets must kill the keepAlive'd remote-tag map so it can never survive
// into a different host that reuses the same repo path.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/providers/app_providers.dart';

void main() {
  test('remotesProvider and remoteTagsProvider are registered for ⌘R / '
      'connection resets', () {
    // The documented foot-gun: a repo-scoped fetch family missing from the
    // registry silently survives refresh and disconnect.
    expect(repoScopedFetchFamilies, contains(remotesProvider));
    expect(repoScopedFetchFamilies, contains(remoteTagsProvider));
  });
}
