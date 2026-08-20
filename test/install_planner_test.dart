// Tests for guided-install planning: which tools can be installed with no
// interaction on a given host, and when we must fall back to copy-paste.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/settings/install_planner.dart';

void main() {
  group('macOS', () {
    test('Homebrew present → runnable brew install for each tool', () {
      const caps = HostCapabilities(hasBrew: true);
      for (final bin in ['git', 'glab', 'gh', 'fswatch']) {
        final action = planInstall(bin, 'macos', caps);
        expect(action, isA<InstallCommand>());
        expect((action as InstallCommand).command, 'brew install $bin');
        expect(action.label, 'Homebrew');
      }
    });

    test('no Homebrew → manual with the no-brew reason', () {
      final action = planInstall('glab', 'macos', const HostCapabilities());
      expect(action, isA<InstallManual>());
      expect((action as InstallManual).reason, kNoBrewReason);
    });
  });

  group('Linux without passwordless sudo', () {
    // Package managers all need root; a static-binary tool can still go
    // rootless.
    const caps = HostCapabilities(hasApt: true, hasDnf: true, hasSnap: true);

    test('git and inotifywait fall back to manual (need sudo)', () {
      for (final bin in ['git', 'inotifywait']) {
        final action = planInstall(bin, 'linux', caps);
        expect((action as InstallManual).reason, kNeedsSudoReason, reason: bin);
      }
    });

    test('gh and glab use a rootless, checksum-verified download', () {
      for (final bin in ['gh', 'glab']) {
        final action = planInstall(bin, 'linux', caps);
        final cmd = action as InstallCommand;
        expect(cmd.label, 'download', reason: bin);
        expect(cmd.command, contains('sha256sum -c'), reason: bin);
        expect(cmd.command, contains(r'$HOME/.local/bin'), reason: bin);
        expect(cmd.summary, isNotNull, reason: bin);
      }
    });
  });

  group('Linux with passwordless sudo + apt', () {
    const caps = HostCapabilities(hasApt: true, passwordlessSudo: true);

    test('git → apt-get install', () {
      expect(
        (planInstall('git', 'linux', caps) as InstallCommand).command,
        'sudo -n apt-get install -y git',
      );
    });

    test('inotifywait → inotify-tools', () {
      expect(
        (planInstall('inotifywait', 'linux', caps) as InstallCommand).command,
        'sudo -n apt-get install -y inotify-tools',
      );
    });

    test('gh has no one-line apt install → rootless download', () {
      final cmd = planInstall('gh', 'linux', caps) as InstallCommand;
      expect(cmd.label, 'download');
    });

    test('glab has no apt path → rootless download', () {
      final cmd = planInstall('glab', 'linux', caps) as InstallCommand;
      expect(cmd.label, 'download');
    });
  });

  group('Linux with passwordless sudo + dnf', () {
    const caps = HostCapabilities(hasDnf: true, passwordlessSudo: true);

    test('git / gh / glab install directly', () {
      expect(
        (planInstall('git', 'linux', caps) as InstallCommand).command,
        'sudo -n dnf install -y git',
      );
      expect(
        (planInstall('gh', 'linux', caps) as InstallCommand).command,
        'sudo -n dnf install -y gh',
      );
      expect(
        (planInstall('glab', 'linux', caps) as InstallCommand).command,
        'sudo -n dnf install -y glab',
      );
    });

    test('inotifywait pulls in EPEL alongside inotify-tools', () {
      expect(
        (planInstall('inotifywait', 'linux', caps) as InstallCommand).command,
        'sudo -n dnf install -y epel-release inotify-tools',
      );
    });
  });

  group('Linux with passwordless sudo + snap only', () {
    const caps = HostCapabilities(hasSnap: true, passwordlessSudo: true);

    test('glab → snap install', () {
      expect(
        (planInstall('glab', 'linux', caps) as InstallCommand).command,
        'sudo -n snap install glab',
      );
    });

    test('git → manual (snap has no path here)', () {
      expect(
        (planInstall('git', 'linux', caps) as InstallManual).reason,
        kNoPackageManagerReason,
      );
    });
  });

  test('unknown OS is always manual', () {
    expect(
      planInstall(
        'git',
        'unknown',
        const HostCapabilities(passwordlessSudo: true),
      ),
      isA<InstallManual>(),
    );
  });

  group('rootless install scripts', () {
    test('gh script hits the right release + checksums URLs and verifies', () {
      final s = rootlessInstallScript('gh');
      expect(s, contains('api.github.com/repos/cli/cli/releases/latest'));
      expect(s, contains(r'gh_${ver}_linux_${arch}.tar.gz'));
      expect(s, contains(r'gh_${ver}_checksums.txt'));
      expect(s, contains('sha256sum -c -')); // checksum verified before install
      expect(s, contains(r'"$HOME/.local/bin/gh"'));
      // arch mapping is present.
      expect(s, contains('x86_64|amd64'));
      expect(s, contains('aarch64|arm64'));
    });

    test('glab script hits the GitLab release + checksums URLs', () {
      final s = rootlessInstallScript('glab');
      expect(
        s,
        contains('gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases'),
      );
      expect(s, contains(r'glab_${ver}_linux_${arch}.tar.gz'));
      expect(s, contains(r'releases/${tag}/downloads'));
      expect(s, contains('checksums.txt'));
      expect(s, contains('sha256sum -c -'));
      expect(s, contains(r'"$HOME/.local/bin/glab"'));
    });

    test('a non-static tool has no rootless script', () {
      expect(() => rootlessInstallScript('git'), throwsArgumentError);
      expect(kRootlessTools, {'gh', 'glab'});
    });
  });

  group('sideload', () {
    test('only the static-binary tools can be sideloaded', () {
      expect(canSideload('gh'), isTrue);
      expect(canSideload('glab'), isTrue);
      expect(canSideload('git'), isFalse);
      expect(canSideload('inotifywait'), isFalse);
    });

    test('asset hint names the exact linux arch + extension when known', () {
      expect(
        sideloadAssetHint('glab', 'linux', 'arm64'),
        contains('glab_*_linux_arm64.tar.gz'),
      );
      expect(
        sideloadAssetHint('gh', 'linux', 'amd64'),
        contains('gh_*_linux_amd64.tar.gz'),
      );
      // Unknown arch degrades gracefully.
      expect(sideloadAssetHint('gh', 'linux', ''), contains('for your host'));
    });

    test('asset hint uses each tool\'s macOS naming (gh: macOS/.zip, '
        'glab: darwin/.tar.gz)', () {
      // gh ships macOS builds as macOS_*.zip …
      expect(
        sideloadAssetHint('gh', 'macos', 'arm64'),
        contains('gh_*_macOS_arm64.zip'),
      );
      expect(
        sideloadAssetHint('gh', 'macos', 'amd64'),
        contains('gh_*_macOS_amd64.zip'),
      );
      // … glab ships them as darwin_*.tar.gz.
      expect(
        sideloadAssetHint('glab', 'macos', 'arm64'),
        contains('glab_*_darwin_arm64.tar.gz'),
      );
      expect(
        sideloadAssetHint('glab', 'macos', 'amd64'),
        contains('glab_*_darwin_amd64.tar.gz'),
      );
    });

    test('releases URL is provided for the static tools', () {
      expect(releasesUrl('gh'), contains('github.com/cli/cli/releases'));
      expect(releasesUrl('glab'), contains('gitlab.com/gitlab-org/cli'));
    });

    test('the install script takes inputs via env (no shell injection) and '
        'verifies the binary runs', () {
      // Filename/paths arrive as $SL_FILE/$SL_BIN/$SL_TMP, never interpolated.
      expect(kSideloadScript, contains(r'"${SL_FILE:?}"'));
      expect(kSideloadScript, contains(r'"$HOME/.local/bin/$SL_BIN"'));
      expect(kSideloadScript, contains('*.tar.gz|*.tgz')); // handles tarballs
      expect(kSideloadScript, contains('*.zip')); // and gh/macOS zips
      expect(kSideloadScript, contains('unzip'));
      expect(kSideloadScript, contains('--version')); // OS/arch sanity check
      // No positional interpolation of a filename anywhere.
      expect(kSideloadScript, isNot(contains(r'$1')));
    });
  });
}
