import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'command_lanes.dart';

enum OperationPhase {
  queued,
  running,
  succeeded,
  failed,
  canceled;

  bool get isTerminal => switch (this) {
    succeeded || failed || canceled => true,
    queued || running => false,
  };
}

enum OperationKind {
  gitMutation,
  synchronization,
  forgeMutation,
  authentication,
  background,
  stream,
}

enum OperationVisibility { normal, background }

@immutable
class OperationId {
  final String value;

  const OperationId(this.value) : assert(value != '');

  static int _sequence = 0;
  static final Random _random = Random();

  factory OperationId.next() {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final sequence = (_sequence++).toRadixString(36);
    final salt = _random.nextInt(0x100000).toRadixString(36);
    return OperationId('$micros-$sequence-$salt');
  }

  @override
  bool operator ==(Object other) =>
      other is OperationId && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => value;
}

@immutable
class OperationDescriptor {
  final OperationId? id;
  final String repositoryPath;
  final String label;
  final OperationKind kind;
  final ExecLane lane;
  final String? affectedObjects;
  final String? hostLabel;
  final bool supportsCancellation;
  final OperationVisibility visibility;

  const OperationDescriptor({
    this.id,
    required this.repositoryPath,
    required this.label,
    required this.kind,
    required this.lane,
    this.affectedObjects,
    this.hostLabel,
    this.supportsCancellation = false,
    this.visibility = OperationVisibility.normal,
  }) : assert(repositoryPath != ''),
       assert(label != '');

  Map<String, Object?> toWire() => {
    'id': id?.value,
    'repositoryPath': repositoryPath,
    'label': label,
    'kind': kind.name,
    'lane': lane.name,
    'affectedObjects': affectedObjects,
    'hostLabel': hostLabel,
    'supportsCancellation': supportsCancellation,
    'visibility': visibility.name,
  };

  static OperationDescriptor? fromWire(Object? raw) {
    if (raw is! Map) return null;
    try {
      final map = Map<Object?, Object?>.from(raw);
      final path = map['repositoryPath'] as String? ?? '';
      final label = map['label'] as String? ?? '';
      if (path.isEmpty || label.isEmpty) return null;
      return OperationDescriptor(
        id: switch (map['id']) {
          final String value when value.isNotEmpty => OperationId(value),
          _ => null,
        },
        repositoryPath: path,
        label: label,
        kind:
            OperationKind.values.asNameMap()[map['kind'] as String?] ??
            OperationKind.gitMutation,
        lane:
            ExecLane.values.asNameMap()[map['lane'] as String?] ??
            ExecLane.exclusive,
        affectedObjects: map['affectedObjects'] as String?,
        hostLabel: map['hostLabel'] as String?,
        supportsCancellation: map['supportsCancellation'] as bool? ?? false,
        visibility:
            OperationVisibility.values.asNameMap()[map['visibility']
                as String?] ??
            OperationVisibility.normal,
      );
    } on TypeError {
      return null;
    }
  }
}

@immutable
class OperationEvent {
  final OperationId id;
  final OperationDescriptor descriptor;
  final OperationPhase phase;
  final DateTime occurredAt;
  final String? result;
  final String? outputAnchorId;
  final bool undoable;
  final bool recoveryAvailable;

  const OperationEvent({
    required this.id,
    required this.descriptor,
    required this.phase,
    required this.occurredAt,
    this.result,
    this.outputAnchorId,
    this.undoable = false,
    this.recoveryAvailable = false,
  });
}

typedef OperationEventCallback = void Function(OperationEvent event);

/// Exactly-once lifecycle emitter shared by real executors. It intentionally
/// owns no scheduling or command data: only safe descriptor metadata crosses
/// this boundary.
class OperationLifecycleEmitter {
  OperationLifecycleEmitter._(
    this.id,
    this.descriptor,
    this._callback,
    this._now,
  ) {
    _emit(OperationPhase.queued);
  }

  final OperationId id;
  final OperationDescriptor descriptor;
  final OperationEventCallback _callback;
  final DateTime Function() _now;
  bool _started = false;
  bool _terminal = false;

  static OperationLifecycleEmitter? begin(
    OperationDescriptor? descriptor,
    OperationEventCallback? callback, {
    DateTime Function() now = DateTime.now,
  }) {
    if (descriptor == null || callback == null) return null;
    return OperationLifecycleEmitter._(
      descriptor.id ?? OperationId.next(),
      descriptor,
      callback,
      now,
    );
  }

  void started() {
    if (_started || _terminal) return;
    _started = true;
    _emit(OperationPhase.running);
  }

  void succeeded([String result = 'Completed']) =>
      _finish(OperationPhase.succeeded, result);

  void failed([String result = 'Failed']) =>
      _finish(OperationPhase.failed, result);

  void canceled([String result = 'Canceled']) =>
      _finish(OperationPhase.canceled, result);

  void _finish(OperationPhase phase, String result) {
    if (_terminal) return;
    _terminal = true;
    _emit(phase, result: result);
  }

  void _emit(OperationPhase phase, {String? result}) {
    _callback(
      OperationEvent(
        id: id,
        descriptor: descriptor,
        phase: phase,
        occurredAt: _now(),
        result: result,
        outputAnchorId: switch (phase) {
          OperationPhase.succeeded ||
          OperationPhase.failed ||
          OperationPhase.canceled => id.value,
          _ => null,
        },
      ),
    );
  }
}

@immutable
class OperationRecord {
  final OperationId id;
  final OperationDescriptor descriptor;
  final OperationPhase phase;
  final DateTime queuedAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final String? result;
  final String? outputAnchorId;
  final bool undoable;
  final bool recoveryAvailable;

  const OperationRecord({
    required this.id,
    required this.descriptor,
    required this.phase,
    required this.queuedAt,
    this.startedAt,
    this.finishedAt,
    this.result,
    this.outputAnchorId,
    this.undoable = false,
    this.recoveryAvailable = false,
  });

  bool get isTerminal => phase.isTerminal;

  Duration elapsed(DateTime now) =>
      (finishedAt ?? now).difference(startedAt ?? queuedAt);

  OperationRecord apply(OperationEvent event) => OperationRecord(
    id: id,
    descriptor: descriptor,
    phase: event.phase,
    queuedAt: queuedAt,
    startedAt: event.phase == OperationPhase.running
        ? event.occurredAt
        : startedAt,
    finishedAt: switch (event.phase) {
      OperationPhase.succeeded ||
      OperationPhase.failed ||
      OperationPhase.canceled => finishedAt ?? event.occurredAt,
      _ => finishedAt,
    },
    result: event.result ?? result,
    outputAnchorId: event.outputAnchorId ?? outputAnchorId,
    undoable: undoable || event.undoable,
    recoveryAvailable: recoveryAvailable || event.recoveryAvailable,
  );
}

/// Pure lifecycle registry used by the Riverpod notifier and unit tests.
class OperationActivityStore {
  OperationActivityStore({
    this.maxTerminalRecords = 50,
    this.terminalRetention = const Duration(minutes: 30),
  });

  final int maxTerminalRecords;
  final Duration terminalRetention;
  List<OperationRecord> _records = const [];

  List<OperationRecord> get records => _records;

  List<OperationRecord> apply(OperationEvent event) {
    final existingIndex = _records.indexWhere(
      (record) => record.id == event.id,
    );
    if (existingIndex < 0) {
      if (event.phase != OperationPhase.queued) return _records;
      _records = [
        OperationRecord(
          id: event.id,
          descriptor: event.descriptor,
          phase: event.phase,
          queuedAt: event.occurredAt,
          result: event.result,
          outputAnchorId: event.outputAnchorId,
          undoable: event.undoable,
          recoveryAvailable: event.recoveryAvailable,
        ),
        ..._records,
      ];
      return _prune(event.occurredAt);
    }

    final current = _records[existingIndex];
    if (current.isTerminal) {
      // Terminal records may gain links after completion, but can never move
      // back into a live phase or switch terminal outcome.
      if (event.phase != current.phase) return _records;
    } else if (!_isForward(current.phase, event.phase)) {
      return _records;
    }
    final next = current.apply(event);
    final updated = [..._records]..[existingIndex] = next;
    _records = updated;
    return _prune(event.occurredAt);
  }

  List<OperationRecord> supersedeActive(DateTime at) {
    _records = [
      for (final record in _records)
        if (record.isTerminal)
          record
        else
          record.apply(
            OperationEvent(
              id: record.id,
              descriptor: record.descriptor,
              phase: OperationPhase.failed,
              occurredAt: at,
              result: 'Superseded by a new connection.',
            ),
          ),
    ];
    return _prune(at);
  }

  static bool _isForward(OperationPhase from, OperationPhase to) =>
      switch ((from, to)) {
        (OperationPhase.queued, OperationPhase.running) => true,
        (OperationPhase.queued, OperationPhase.succeeded) => true,
        (OperationPhase.queued, OperationPhase.failed) => true,
        (OperationPhase.queued, OperationPhase.canceled) => true,
        (OperationPhase.running, OperationPhase.succeeded) => true,
        (OperationPhase.running, OperationPhase.failed) => true,
        (OperationPhase.running, OperationPhase.canceled) => true,
        _ => false,
      };

  List<OperationRecord> _prune(DateTime now) {
    final cutoff = now.subtract(terminalRetention);
    final active = <OperationRecord>[];
    final terminal = <OperationRecord>[];
    for (final record in _records) {
      if (!record.isTerminal) {
        active.add(record);
      } else if (!(record.finishedAt ?? record.queuedAt).isBefore(cutoff)) {
        terminal.add(record);
      }
    }
    _records = [...active, ...terminal.take(maxTerminalRecords)];
    return _records;
  }

  List<OperationRecord> drop(OperationId id) {
    final next = [
      for (final record in _records)
        if (record.id != id) record,
    ];
    if (next.length == _records.length) return _records;
    _records = next;
    return _records;
  }
}

class OperationActivityNotifier extends Notifier<List<OperationRecord>> {
  late final OperationActivityStore _store;

  @override
  List<OperationRecord> build() {
    _store = OperationActivityStore();
    return const [];
  }

  void report(OperationEvent event) {
    var next = _store.apply(event);
    if (event.descriptor.visibility == OperationVisibility.background &&
        event.phase.isTerminal) {
      next = _store.drop(event.id);
    }
    if (!identical(next, state)) state = next;
  }

  void supersedeActive() {
    state = _store.supersedeActive(DateTime.now());
  }
}

final operationActivityProvider =
    NotifierProvider<OperationActivityNotifier, List<OperationRecord>>(
      OperationActivityNotifier.new,
    );
