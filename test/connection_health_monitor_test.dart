// ConnectionHealthMonitor: dartssh2's own keepalive never checks whether its
// pings are answered, so this monitor is what turns a silently-dead (NAT-
// dropped) connection into a prompt force-close → `done` completes → the
// auto-reconnect path takes over.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_magic_git/core/ssh/ssh_client_manager.dart';

void main() {
  test('healthy pings never trigger onDead', () {
    fakeAsync((async) {
      var dead = false;
      final monitor = ConnectionHealthMonitor(
        ping: () async {},
        onDead: () => dead = true,
        interval: const Duration(seconds: 15),
        pingTimeout: const Duration(seconds: 15),
      )..start();

      async.elapse(const Duration(minutes: 5));
      expect(dead, isFalse);
      expect(monitor.failures, 0);
      monitor.stop();
    });
  });

  test('two consecutive unanswered pings declare the peer dead (once)', () {
    fakeAsync((async) {
      var deaths = 0;
      final monitor = ConnectionHealthMonitor(
        // Never answers — models a NAT-dropped connection with no RST.
        ping: () => Completer<void>().future,
        onDead: () => deaths++,
        interval: const Duration(seconds: 15),
        pingTimeout: const Duration(seconds: 15),
      )..start();

      // First probe fires at 15s, times out at 30s → failure 1.
      async.elapse(const Duration(seconds: 31));
      expect(deaths, 0);
      expect(monitor.failures, 1);

      // Second probe fires at 45s, times out at 60s → failure 2 → dead.
      async.elapse(const Duration(seconds: 30));
      expect(deaths, 1);

      // Monitor stopped itself; no further probes, no double-kill.
      async.elapse(const Duration(minutes: 5));
      expect(deaths, 1);
    });
  });

  test('a single slow reply does not kill the connection', () {
    fakeAsync((async) {
      var dead = false;
      var calls = 0;
      final monitor = ConnectionHealthMonitor(
        ping: () {
          calls++;
          // First ping never answers (times out); later pings answer promptly
          // — models one blip on an otherwise healthy link.
          return calls == 1 ? Completer<void>().future : Future.value();
        },
        onDead: () => dead = true,
        interval: const Duration(seconds: 15),
        pingTimeout: const Duration(seconds: 15),
      )..start();

      async.elapse(const Duration(seconds: 31));
      expect(monitor.failures, 1);

      // The next probe succeeds and resets the counter.
      async.elapse(const Duration(seconds: 15));
      expect(monitor.failures, 0);

      async.elapse(const Duration(minutes: 5));
      expect(dead, isFalse);
      monitor.stop();
    });
  });

  test('probes never overlap: a hung ping is one failure, not several', () {
    fakeAsync((async) {
      var pings = 0;
      final monitor = ConnectionHealthMonitor(
        ping: () {
          pings++;
          return Completer<void>().future;
        },
        onDead: () {},
        interval: const Duration(seconds: 10),
        // Timeout far longer than the interval: several ticks fire while the
        // first probe is still awaiting its reply.
        pingTimeout: const Duration(seconds: 45),
      )..start();

      async.elapse(const Duration(seconds: 40));
      expect(pings, 1, reason: 'ticks during an in-flight probe are skipped');
      monitor.stop();
    });
  });

  test('stop() prevents any further onDead', () {
    fakeAsync((async) {
      var dead = false;
      final monitor = ConnectionHealthMonitor(
        ping: () => Completer<void>().future,
        onDead: () => dead = true,
        interval: const Duration(seconds: 15),
        pingTimeout: const Duration(seconds: 15),
      )..start();

      async.elapse(const Duration(seconds: 20)); // one probe in flight
      monitor.stop();
      async.elapse(const Duration(minutes: 5));
      expect(dead, isFalse);
    });
  });
}
