import 'dart:async';
import 'dart:collection';

import 'package:logging/logging.dart';
import 'realm_class.dart';

/// Manager for handling background commits to prevent UI freezes
class BackgroundCommitManager {
  static final _instance = BackgroundCommitManager._internal();
  factory BackgroundCommitManager() => _instance;
  BackgroundCommitManager._internal();

  final _logger = Logger('BackgroundCommitManager');
  final _pendingCommits = Queue<_PendingCommit>();
  Timer? _commitTimer;
  bool _isProcessing = false;
  
  static const _batchTimeout = Duration(milliseconds: 16); // ~1 frame at 60fps
  static const _maxBatchSize = 10;

  /// Schedule a commit operation to be executed in background
  Future<void> scheduleCommit(Transaction transaction, {bool urgent = false}) async {
    final completer = Completer<void>();
    final pendingCommit = _PendingCommit(transaction, completer, urgent);
    
    _pendingCommits.add(pendingCommit);
    
    if (urgent || _pendingCommits.length >= _maxBatchSize) {
      // Process immediately for urgent commits or when batch is full
      _scheduleProcessing(immediate: true);
    } else {
      // Schedule processing after timeout for batching
      _scheduleProcessing(immediate: false);
    }
    
    return completer.future;
  }

  void _scheduleProcessing({required bool immediate}) {
    if (_isProcessing) return;
    
    if (immediate) {
      _commitTimer?.cancel();
      _processCommits();
    } else {
      _commitTimer?.cancel();
      _commitTimer = Timer(_batchTimeout, _processCommits);
    }
  }

  void _processCommits() async {
    if (_isProcessing || _pendingCommits.isEmpty) return;
    
    _isProcessing = true;
    _commitTimer?.cancel();
    
    try {
      final sw = Stopwatch()..start();
      final batch = <_PendingCommit>[];
      
      // Collect commits to process in this batch
      while (_pendingCommits.isNotEmpty && batch.length < _maxBatchSize) {
        batch.add(_pendingCommits.removeFirst());
      }
      
      _logger.fine('Processing ${batch.length} commits in background');
      
      // Process commits in isolate to avoid blocking UI
      await _processCommitsInIsolate(batch);
      
      final elapsed = sw.elapsedMilliseconds;
      if (elapsed > 50) {
        _logger.warning('Background commit batch took ${elapsed}ms for ${batch.length} commits');
      }
      
    } catch (e, stackTrace) {
      _logger.severe('Error processing background commits', e, stackTrace);
    } finally {
      _isProcessing = false;
      
      // Schedule next batch if more commits are pending
      if (_pendingCommits.isNotEmpty) {
        _scheduleProcessing(immediate: false);
      }
    }
  }

  Future<void> _processCommitsInIsolate(List<_PendingCommit> batch) async {
    // For now, process commits synchronously but in controlled batches
    // In future versions, this could be moved to a true isolate
    for (final pendingCommit in batch) {
      try {
        final sw = Stopwatch()..start();
        pendingCommit.transaction.commit();
        final elapsed = sw.elapsedMilliseconds;
        
        if (elapsed > 100) {
          _logger.warning('Individual commit took ${elapsed}ms');
        }
        
        pendingCommit.completer.complete();
      } catch (e, stackTrace) {
        _logger.severe('Failed to commit transaction', e, stackTrace);
        pendingCommit.completer.completeError(e, stackTrace);
      }
    }
  }

  /// Flush all pending commits immediately
  Future<void> flush() async {
    while (_pendingCommits.isNotEmpty) {
      _scheduleProcessing(immediate: true);
      await Future.delayed(Duration(milliseconds: 1)); // Allow processing to complete
    }
  }

  /// Get number of pending commits
  int get pendingCount => _pendingCommits.length;
}

class _PendingCommit {
  final Transaction transaction;
  final Completer<void> completer;
  final bool urgent;
  final DateTime timestamp;

  _PendingCommit(this.transaction, this.completer, this.urgent) 
      : timestamp = DateTime.now();
}
