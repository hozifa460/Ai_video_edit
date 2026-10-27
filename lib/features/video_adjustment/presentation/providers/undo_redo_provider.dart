import 'package:flutter_riverpod/flutter_riverpod.dart';

class UndoRedoNotifier extends Notifier<UndoRedoState> {
  static const int _maxSteps = 20;
  static const int _coalesceWindowMs = 500;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  UndoRedoState build() => UndoRedoState();

  void pushState(dynamic settings) {
    // Truncate the redo tail: after undoing to an earlier state,
    // a new edit must discard all states ahead of it.
    final history = List<dynamic>.from(
      state.history.take(state.currentIndex + 1),
    );

    // Coalesce rapid consecutive edits (slider drags) into a single step
    // so the ring buffer isn't flooded with sub-percent increments.
    final now = DateTime.now();
    final coalesce = history.isNotEmpty &&
        now.difference(_lastPush).inMilliseconds < _coalesceWindowMs;
    if (coalesce) {
      history[history.length - 1] = settings;
    } else {
      history.add(settings);
    }
    _lastPush = now;

    if (history.length > _maxSteps) {
      history.removeAt(0);
    }
    state = UndoRedoState(
      history: history,
      currentIndex: history.length - 1,
      canUndo: history.length > 1,
      canRedo: false,
    );
  }

  dynamic undo() {
    if (!state.canUndo) return null;
    final newIndex = state.currentIndex - 1;
    state = UndoRedoState(
      history: state.history,
      currentIndex: newIndex,
      canUndo: newIndex > 0,
      canRedo: true,
    );
    return state.history[newIndex];
  }

  dynamic redo() {
    if (!state.canRedo) return null;
    final newIndex = state.currentIndex + 1;
    state = UndoRedoState(
      history: state.history,
      currentIndex: newIndex,
      canUndo: true,
      canRedo: newIndex < state.history.length - 1,
    );
    return state.history[newIndex];
  }

  void clear() {
    state = UndoRedoState();
  }
}

class UndoRedoState {
  final List<dynamic> history;
  final int currentIndex;
  final bool canUndo;
  final bool canRedo;

  const UndoRedoState({
    this.history = const [],
    this.currentIndex = 0,
    this.canUndo = false,
    this.canRedo = false,
  });
}

final undoRedoProvider = NotifierProvider<UndoRedoNotifier, UndoRedoState>(
  UndoRedoNotifier.new,
);
