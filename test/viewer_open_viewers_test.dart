import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/features/viewer/viewer_providers.dart';

void main() {
  late ProviderContainer container;
  late OpenFileViewers viewers;

  setUp(() {
    container = ProviderContainer();
    viewers = container.read(openFileViewersProvider.notifier);
  });
  tearDown(() => container.dispose());

  List<ViewerHandle> list() => container.read(openFileViewersProvider);

  test('open adds a window; distinct files stack', () {
    viewers.open('/repo', 'a.txt');
    viewers.open('/repo', 'b.txt');
    expect(list().map((v) => v.path), ['a.txt', 'b.txt']);
  });

  test('opening an already-open file focuses it instead of duplicating', () {
    final id = viewers.open('/repo', 'a.txt');
    viewers.open('/repo', 'b.txt');
    final again = viewers.open('/repo', 'a.txt');
    // Same window (same id), no duplicate, and moved to the front (last).
    expect(again, id);
    expect(list().length, 2);
    expect(list().last.path, 'a.txt');
  });

  test('same path in a different repo is a separate window', () {
    viewers.open('/repo1', 'a.txt');
    viewers.open('/repo2', 'a.txt');
    expect(list().length, 2);
  });

  test('focus moves a window to the front', () {
    final a = viewers.open('/repo', 'a.txt');
    viewers.open('/repo', 'b.txt');
    viewers.focus(a);
    expect(list().last.id, a);
  });

  test('close removes a specific window', () {
    final a = viewers.open('/repo', 'a.txt');
    viewers.open('/repo', 'b.txt');
    viewers.close(a);
    expect(list().map((v) => v.path), ['b.txt']);
  });

  test('closeTop removes the front-most window and reports it', () {
    viewers.open('/repo', 'a.txt');
    viewers.open('/repo', 'b.txt');
    expect(viewers.closeTop(), isTrue);
    expect(list().map((v) => v.path), ['a.txt']);
    viewers.closeTop();
    expect(viewers.closeTop(), isFalse); // nothing left
  });

  test('closeAll empties the stack', () {
    viewers.open('/repo', 'a.txt');
    viewers.open('/repo', 'b.txt');
    viewers.closeAll();
    expect(list(), isEmpty);
  });
}
