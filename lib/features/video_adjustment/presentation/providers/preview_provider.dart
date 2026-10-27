import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'adjustment_provider.dart';

class PreviewNotifier extends Notifier<PreviewState> {
  @override
  PreviewState build() => const PreviewState();

  Future<void> updatePreview(String videoPath) async {
    if (videoPath.isEmpty) return;

    final hadPreview = state.previewPath != null;
    if (!hadPreview) {
      state = state.copyWith(isLoading: true, error: null);
    }

    try {
      final repository = ref.read(adjustmentRepositoryProvider);
      final settings = ref.read(adjustmentProvider);
      final framePath = await repository.extractPreviewFrame(
        inputPath: videoPath,
        settings: settings,
      );

      if (framePath.isEmpty) {
        if (!hadPreview) state = state.copyWith(isLoading: false, error: 'Failed to generate preview');
        return;
      }

      state = state.copyWith(
        previewPath: framePath,
        isLoading: false,
        error: null,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  void toggleOriginal(bool show) {
    state = state.copyWith(showOriginal: show);
  }

  void clearPreview() {
    state = const PreviewState();
  }
}

class PreviewState {
  final String? previewPath;
  final bool isLoading;
  final String? error;
  final bool showOriginal;

  const PreviewState({
    this.previewPath,
    this.isLoading = false,
    this.error,
    this.showOriginal = false,
  });

  PreviewState copyWith({
    String? previewPath,
    bool? isLoading,
    String? error,
    bool? showOriginal,
    bool clearPreview = false,
  }) {
    return PreviewState(
      previewPath: clearPreview ? null : (previewPath ?? this.previewPath),
      isLoading: isLoading ?? this.isLoading,
      error: error ?? this.error,
      showOriginal: showOriginal ?? this.showOriginal,
    );
  }
}

final previewProvider = NotifierProvider<PreviewNotifier, PreviewState>(
  PreviewNotifier.new,
);
