import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/datasources/ffmpeg_adjustment_datasource.dart';
import '../../data/repositories/adjustment_repository_impl.dart';
import '../../domain/entities/adjustment_preset.dart';
import '../../domain/entities/adjustment_settings.dart';
import '../../domain/entities/color_adjustment.dart';
import '../../domain/entities/tone_adjustment.dart';
import '../../domain/entities/video_adjustment.dart';
import '../../domain/entities/audio_adjustment.dart';
import '../../domain/repositories/adjustment_repository.dart';
import 'undo_redo_provider.dart';

final adjustmentDatasourceProvider = Provider<FfmpegAdjustmentDatasource>((ref) {
  return FfmpegAdjustmentDatasource();
});

final adjustmentRepositoryProvider = Provider<AdjustmentRepository>((ref) {
  final datasource = ref.watch(adjustmentDatasourceProvider);
  return AdjustmentRepositoryImpl(datasource);
});

class AdjustmentNotifier extends Notifier<AdjustmentSettings> {
  @override
  AdjustmentSettings build() => const AdjustmentSettings();

  void updateBrightness(double value) {
    _pushUndo();
    state = state.copyWith(brightness: value);
  }

  void updateContrast(double value) {
    _pushUndo();
    state = state.copyWith(contrast: value);
  }

  void updateSaturation(double value) {
    _pushUndo();
    state = state.copyWith(saturation: value);
  }

  void updateExposure(double value) {
    _pushUndo();
    state = state.copyWith(exposure: value);
  }

  void updateGamma(double value) {
    _pushUndo();
    state = state.copyWith(gamma: value);
  }

  void updateHue(double value) {
    _pushUndo();
    state = state.copyWith(hue: value);
  }

  void updateSharpness(double value) {
    _pushUndo();
    state = state.copyWith(sharpness: value);
  }

  void updateBlur(double value) {
    _pushUndo();
    state = state.copyWith(blur: value);
  }

  void updateHighlights(double value) {
    _pushUndo();
    state = state.copyWith(tone: state.tone.copyWith(highlights: value));
  }

  void updateShadows(double value) {
    _pushUndo();
    state = state.copyWith(tone: state.tone.copyWith(shadows: value));
  }

  void updateWhites(double value) {
    _pushUndo();
    state = state.copyWith(tone: state.tone.copyWith(whites: value));
  }

  void updateBlacks(double value) {
    _pushUndo();
    state = state.copyWith(tone: state.tone.copyWith(blacks: value));
  }

  void updateMidtones(double value) {
    _pushUndo();
    state = state.copyWith(tone: state.tone.copyWith(midtones: value));
  }

  void updateTemperature(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(temperature: value));
  }

  void updateTint(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(tint: value));
  }

  void updateRedBalance(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(redBalance: value));
  }

  void updateGreenBalance(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(greenBalance: value));
  }

  void updateBlueBalance(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(blueBalance: value));
  }

  void updateVibrance(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(vibrance: value));
  }

  void updateFade(double value) {
    _pushUndo();
    state = state.copyWith(color: state.color.copyWith(fade: value));
  }

  void updateVignette(double value) {
    _pushUndo();
    state = state.copyWith(vignette: value);
  }

  void updateNoise(double value) {
    _pushUndo();
    state = state.copyWith(noise: value);
  }

  void updateDenoise(double value) {
    _pushUndo();
    state = state.copyWith(denoise: value);
  }

  void updateLensDistortion(double value) {
    _pushUndo();
    state = state.copyWith(lensDistortion: value);
  }

  void updateRotate(double value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(rotate: value));
  }

  void updateFlipHorizontal(int value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(flipHorizontal: value));
  }

  void updateFlipVertical(int value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(flipVertical: value));
  }

  void updateCrop(double x, double y, double w, double h) {
    _pushUndo();
    state = state.copyWith(
      video: state.video.copyWith(cropX: x, cropY: y, cropWidth: w, cropHeight: h),
    );
  }

  void updateScale(double w, double h) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(scaleWidth: w, scaleHeight: h));
  }

  void updateSpeed(double value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(speed: value));
  }

  void updateFadeIn(double value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(fadeIn: value));
  }

  void updateFadeOut(double value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(fadeOut: value));
  }

  void updateReverse(bool value) {
    _pushUndo();
    state = state.copyWith(video: state.video.copyWith(reverse: value));
  }

  void updateVolume(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(volume: value));
  }

  void updateNoiseReduction(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(noiseReduction: value));
  }

  void updateNormalize(bool value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(normalize: value));
  }

  void updateAudioFadeIn(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(fadeIn: value));
  }

  void updateAudioFadeOut(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(fadeOut: value));
  }

  void updateBassBoost(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(bassBoost: value));
  }

  void updateTreble(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(treble: value));
  }

  void updateCompressor(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(compressor: value));
  }

  void updateMute(bool value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(mute: value));
  }

  void updatePitchShift(double value) {
    _pushUndo();
    state = state.copyWith(audio: state.audio.copyWith(pitchShift: value));
  }

  void applyLut(String lutPath) {
    _pushUndo();
    state = state.copyWith(lutPath: lutPath);
  }

  void clearLut() {
    _pushUndo();
    state = state.copyWith(clearLut: true);
  }

  void applyPreset(AdjustmentPreset preset) {
    _pushUndo();
    state = preset.settings;
  }

  void resetAll() {
    _pushUndo();
    state = const AdjustmentSettings();
  }

  void resetBasic() {
    _pushUndo();
    state = state.copyWith(
      brightness: null,
      contrast: null,
      saturation: null,
      exposure: null,
      gamma: null,
      hue: null,
      sharpness: null,
      blur: null,
    );
  }

  void resetTone() {
    _pushUndo();
    state = state.copyWith(
      tone: const ToneAdjustment(),
    );
  }

  void resetColor() {
    _pushUndo();
    state = state.copyWith(
      color: const ColorAdjustment(),
    );
  }

  void resetVideo() {
    _pushUndo();
    state = state.copyWith(
      video: const VideoAdjustment(),
    );
  }

  void resetAudio() {
    _pushUndo();
    state = state.copyWith(
      audio: const AudioAdjustment(),
    );
  }

  void resetEffects() {
    _pushUndo();
    state = state.copyWith(
      vignette: null,
      noise: null,
      denoise: null,
      lensDistortion: null,
    );
  }

  void applyUndoState(AdjustmentSettings settings) {
    state = settings;
  }

  void _pushUndo() {
    ref.read(undoRedoProvider.notifier).pushState(state);
  }
}

final adjustmentProvider = NotifierProvider<AdjustmentNotifier, AdjustmentSettings>(
  AdjustmentNotifier.new,
);
