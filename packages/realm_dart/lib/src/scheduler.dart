// Copyright 2022 MongoDB, Inc.
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:isolate';
import 'dart:collection';

import 'package:realm_dart/src/logging.dart';

import 'handles/scheduler_handle.dart';
import 'realm_class.dart';

final _receivePortFinalizer = Finalizer<RawReceivePort>((p) => p.close());
final Scheduler scheduler = Scheduler._();

class Scheduler {
  late final SchedulerHandle handle;
  final RawReceivePort _receivePort = RawReceivePort();
  // Queue of pending Realm work queue pointers (as int addresses) to process.
  final Queue<int> _pendingWork = Queue<int>();
  bool _isDraining = false;
  // Time budget per drain pass to avoid long blocking on UI isolate.
  // Keep small to let frames render; tweak if needed.
  Duration drainBudget = const Duration(milliseconds: 6);

  Scheduler._() {
    _receivePortFinalizer.attach(this, _receivePort, detach: this);
    // There be dragons here!!!
    //
    // As of Dart 3.4 (Flutter 3.22) we started seeing uncaught exceptions on
    // the receivePort handler (issue #1676), stating that:
    // "argument value for 'return_value' is null" in
    // RealmLibrary.realm_scheduler_perform_work, but obviously a void method
    // don't return anything, so this is really a Dart issue.
    //
    // However, by ensuring the callback happens in the current zone (as it
    // rightfully should), and using bindUnaryCallbackGuarded, we can avoid
    // these.
    _receivePort.handler = Zone.current.bindUnaryCallbackGuarded(_handle);
    final sendPort = _receivePort.sendPort;
    handle = SchedulerHandle(Isolate.current.hashCode, sendPort);
  }

  void _handle(dynamic message) {
    if (message is List) {
      // currently the only `message as List` is from the logger.
      final category = LogCategory.fromString(message[0] as String);
      final level = LogLevel.values[message[1] as int];
      final text = message[2] as String;
      Realm.logger.raise((category: category, level: level, message: text));
    } else if (message is int) {
      // Queue and process with a small time budget to prevent jank.
      _pendingWork.addLast(message);
      if (!_isDraining) {
        _isDraining = true;
        _scheduleDrain();
      }
    } else {
      Realm.logger.log(LogLevel.error, 'Unexpected Scheduler message type: ${message.runtimeType} - $message');
    }
  }

  void _scheduleDrain() {
    // Use a zero-delay future to yield to the event loop (not a microtask),
    // allowing a frame to render before heavy work resumes.
    Future<void>(() => _drain());
  }

  void _drain() {
    final sw = Stopwatch()..start();
    while (_pendingWork.isNotEmpty && sw.elapsed < drainBudget) {
      final workQueueAddr = _pendingWork.removeFirst();
      try {
        final one = Stopwatch()..start();
        handle.invoke(workQueueAddr);
        one.stop();
        if (one.elapsedMilliseconds >= 16) {
          Realm.logger.log(
            LogLevel.warn,
            'Realm scheduler work took ${one.elapsedMilliseconds}ms (remaining queued: ${_pendingWork.length})',
          );
        }
      } catch (e, st) {
        Realm.logger.log(LogLevel.error, 'Scheduler.invoke failed: $e\n$st');
      }
    }

    if (_pendingWork.isNotEmpty) {
      // More work left; schedule another slice to keep UI responsive.
      _scheduleDrain();
    } else {
      _isDraining = false;
    }
  }

  void stop() {
    if (handle.released) {
      return;
    }
    _pendingWork.clear();
    _isDraining = false;
    _receivePort.close();
    _receivePortFinalizer.detach(this);
    handle.release();
  }
}
