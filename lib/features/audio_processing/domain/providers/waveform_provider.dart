import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/utils/logger.dart';
import '../../../../core/utils/result.dart';
import '../entities/waveform_data.dart';
import '../repositories/audio_processor_repository.dart';
import '../../data/repositories/audio_processor_repository_impl.dart';

final audioProcessorRepositoryProvider = Provider<AudioProcessorRepository>(
  (ref) => AudioProcessorRepositoryImpl(),
);

final waveformProvider =
    NotifierProvider.autoDispose<WaveformNotifier, AsyncValue<WaveformData?>>(
  WaveformNotifier.new,
);

class WaveformNotifier extends Notifier<AsyncValue<WaveformData?>> {
  @override
  AsyncValue<WaveformData?> build() => const AsyncData(null);

  Future<void> analyze(String audioPath) async {
    state = const AsyncLoading();
    final repository = ref.read(audioProcessorRepositoryProvider);
    final result = await repository.analyzeWaveform(audioPath);
    if (result is Success<WaveformData>) {
      state = AsyncData(result.value);
    } else if (result is AppError<WaveformData>) {
      AppLogger().e('Waveform analysis failed', result.error);
      state = AsyncError(result.error, StackTrace.current);
    }
  }
}
