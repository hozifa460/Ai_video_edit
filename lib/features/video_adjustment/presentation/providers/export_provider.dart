import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'adjustment_provider.dart';

class ExportNotifier extends Notifier<ExportState> {
  @override
  ExportState build() => const ExportState();

  Future<void> exportVideo({
    required String inputPath,
    required String outputPath,
    required String quality,
  }) async {
    state = state.copyWith(
      isExporting: true,
      progress: 0,
      error: null,
      isCompleted: false,
    );

    try {
      final repository = ref.read(adjustmentRepositoryProvider);
      final settings = ref.read(adjustmentProvider);

      await repository.exportVideo(
        inputPath: inputPath,
        outputPath: outputPath,
        settings: settings,
        quality: quality,
        onProgress: (p) {
          state = state.copyWith(progress: p);
        },
      );

      state = state.copyWith(
        isExporting: false,
        progress: 1.0,
        isCompleted: true,
      );
    } catch (e) {
      state = state.copyWith(
        isExporting: false,
        error: e.toString(),
      );
    }
  }

  void cancelExport() {
    final repository = ref.read(adjustmentRepositoryProvider);
    repository.cancelProcessing();
    state = state.copyWith(isExporting: false);
  }

  void reset() {
    state = const ExportState();
  }
}

class ExportState {
  final bool isExporting;
  final double progress;
  final String? error;
  final bool isCompleted;

  const ExportState({
    this.isExporting = false,
    this.progress = 0,
    this.error,
    this.isCompleted = false,
  });

  ExportState copyWith({
    bool? isExporting,
    double? progress,
    String? error,
    bool? isCompleted,
    bool clearError = false,
  }) {
    return ExportState(
      isExporting: isExporting ?? this.isExporting,
      progress: progress ?? this.progress,
      error: clearError ? null : (error ?? this.error),
      isCompleted: isCompleted ?? this.isCompleted,
    );
  }
}

final exportProvider = NotifierProvider<ExportNotifier, ExportState>(
  ExportNotifier.new,
);
