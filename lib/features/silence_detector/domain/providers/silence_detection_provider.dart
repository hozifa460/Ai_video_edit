import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/utils/logger.dart';
import '../../data/services/adaptive_threshold_service.dart';
import '../entities/detection_params.dart';
import '../entities/media_timeline.dart';
import '../entities/silence_removal_plan.dart';
import '../entities/silence_segment.dart';

final detectionParamsProvider =
    NotifierProvider<DetectionParamsNotifier, DetectionParams>(() {
      return DetectionParamsNotifier();
    });

/// The canonical removal plan for the file currently in the editor.
///
/// `null` means "no successful detection for this file yet". The editor screen
/// stores it after a successful detection; the statistics widgets, the timeline
/// list, the preview screen and the FFmpeg cut all read this one object, so
/// none of them can compute a different answer (SR-03).
final silenceRemovalPlanProvider =
    NotifierProvider<SilenceRemovalPlanNotifier, SilenceRemovalPlan?>(() {
      return SilenceRemovalPlanNotifier();
    });

/// Normalized removal intervals of the current plan, ascending and disjoint.
/// Presentation-only convenience; never sum these directly for statistics.
final silenceSegmentsProvider = Provider<List<SilenceSegment>>((ref) {
  return ref.watch(silenceRemovalPlanProvider)?.removals ?? const [];
});

/// Probed timing for the file currently in the editor (SR-05).
final mediaTimelineProvider =
    NotifierProvider<MediaTimelineNotifier, MediaTimeline>(() {
      return MediaTimelineNotifier();
    });

class MediaTimelineNotifier extends Notifier<MediaTimeline> {
  @override
  MediaTimeline build() => MediaTimeline.unknown;

  void setTimeline(MediaTimeline timeline) {
    state = timeline;
  }

  void clear() {
    state = MediaTimeline.unknown;
  }
}

class DetectionParamsNotifier extends Notifier<DetectionParams> {
  @override
  DetectionParams build() => DetectionParams.defaults();

  void updateThreshold(double value) {
    state = state.copyWith(silenceThreshold: value);
  }

  void updateMinDuration(double value) {
    state = state.copyWith(minSilenceDuration: value);
  }

  void updatePaddingBefore(double value) {
    state = state.copyWith(paddingBefore: value);
  }

  void updatePaddingAfter(double value) {
    state = state.copyWith(paddingAfter: value);
  }

  void toggleVad() {
    state = state.copyWith(useVad: !state.useVad);
  }

  void toggleBreathingProtection() {
    state = state.copyWith(
      useBreathingProtection: !state.useBreathingProtection,
    );
  }

  void toggleSmartZoom() {
    state = state.copyWith(
      smartZoom: state.smartZoom.copyWith(enabled: !state.smartZoom.enabled),
    );
  }

  void setSmartZoomAmount(double amount) {
    state = state.copyWith(
      smartZoom: state.smartZoom.copyWith(zoomAmount: amount),
    );
  }

  Future<void> autoDetectThreshold(String audioPath) async {
    final service = AdaptiveThresholdService();
    final updated = await service.analyze(
      audioPath: audioPath,
      currentParams: state,
    );
    state = updated;
    AppLogger().i('Auto threshold applied: ${updated.silenceThreshold} dB');
  }

  void reset() {
    state = DetectionParams.defaults();
  }

  /// Replaces the whole params object without bumping any version counter here;
  /// versioning lives in [EditorDetectionController]. Used only to mirror the
  /// controller's params into the provider the widgets read.
  void load(DetectionParams params) {
    state = params;
  }
}

class SilenceRemovalPlanNotifier extends Notifier<SilenceRemovalPlan?> {
  @override
  SilenceRemovalPlan? build() => null;

  void setPlan(SilenceRemovalPlan plan) {
    state = plan;
  }

  /// Keeps the interval at [index] in the output ("exclude from removal").
  ///
  /// The plan is rebuilt from the remaining intervals, so `removedSeconds`,
  /// `kept` and the FFmpeg cut all move together instead of leaving a stale
  /// sum behind (SR-03).
  void keepInterval(int index) {
    final plan = state;
    if (plan == null) return;
    state = plan.withoutRemoval(index);
  }

  void clear() {
    state = null;
  }
}

/// True when there is at least one interval that will actually be deleted.
final hasSilenceSegmentsProvider = Provider<bool>((ref) {
  return ref.watch(silenceRemovalPlanProvider)?.hasRemovals ?? false;
});

/// Union length of the current removal set, in seconds.
///
/// Reads the normalized plan rather than summing the raw list, so overlapping
/// or duplicated intervals can no longer inflate the number shown in the UI
/// (SR-03).
final totalSilenceDurationProvider = Provider<double>((ref) {
  return ref.watch(silenceRemovalPlanProvider)?.removedSeconds ?? 0;
});
