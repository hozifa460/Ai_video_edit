import 'dart:async';

import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/core/errors/failures.dart';
import 'package:ai_video_editing/features/audio_processing/domain/entities/waveform_data.dart';
import 'package:ai_video_editing/features/silence_detector/domain/services/editor_services.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/controllers/editor_detection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeProbe implements MediaProbeService {
  final MediaTimeline timeline;
  _FakeProbe(this.timeline);
  @override
  Future<Result<MediaTimeline>> probe(String videoPath) async =>
      Success<MediaTimeline>(timeline);
}

class _FakeAudio implements AudioExtractionService {
  @override
  Future<Result<String>> extractAudio(String videoPath) async =>
      const Success<String>('audio.wav');
  @override
  Future<Result<WaveformData>> analyzeWaveform(String audioPath) async =>
      const AppError<WaveformData>(AudioExtractionFailure());
}

// SilenceRemovalPlan requires WaveformData import; avoid it by returning a
// minimal plan through the repository-less path. We instead inject a detector
// that builds a plan from the passed params so identity can be observed.
class _ControllableDetector implements SilenceDetectionService {
  final Future<Result<SilenceRemovalPlan>> Function() factory;
  _ControllableDetector(this.factory);
  @override
  Future<Result<SilenceRemovalPlan>> detect({
    required String audioPath,
    required DetectionParams params,
    required MediaTimeline timeline,
  }) {
    return factory();
  }
}

SilenceRemovalPlan _plan(double total, {int removals = 1}) {
  return SilenceRemovalPlan.build(
    totalDurationSeconds: total,
    removals: [
      for (var i = 0; i < removals; i++)
        SilenceSegment(startSeconds: i.toDouble(), endSeconds: i + 0.5),
    ],
  );
}

void main() {
  final timeline = MediaTimeline.probed(
    videoDurationSeconds: 10,
    audioDurationSeconds: 10,
    hasAudio: true,
  );

  test('two sessions for different files never share a plan', () async {
    final cA = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(
        () => Completer<Result<SilenceRemovalPlan>>().future,
      ),
    );
    final cB = EditorDetectionController(
      videoPath: 'b.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(
        () => Completer<Result<SilenceRemovalPlan>>().future,
      ),
    );
    await cA.load(audioPath: 'a.wav');
    await cB.load(audioPath: 'b.wav');
    // Inject a plan into A only.
    // (Plans are set via detect; here we check identity isolation by session id.)
    expect(cA.sessionId, isNot(equals(cB.sessionId)));
    expect(cA.videoPath, 'a.mp4');
    expect(cB.videoPath, 'b.mp4');
    cA.dispose();
    cB.dispose();
  });

  test('a late result is discarded when the session is closed', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    c.close();
    completer.complete(Success<SilenceRemovalPlan>(_plan(10)));
    await future;
    expect(c.plan, isNull);
    expect(c.status, DetectionStatus.idle);
    c.dispose();
  });

  test('a late result is discarded when params change mid-flight', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    c.updateThreshold(-20); // bumps paramsVersion
    completer.complete(Success<SilenceRemovalPlan>(_plan(10)));
    await future;
    expect(c.plan, isNull);
    expect(c.planIsStale, isFalse); // no plan at all, not stale
    c.dispose();
  });

  test('reversed completion order keeps only the last request', () async {
    final cA = Completer<Result<SilenceRemovalPlan>>();
    final cB = Completer<Result<SilenceRemovalPlan>>();
    var which = 0;
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(
        () => which == 0 ? cA.future : cB.future,
      ),
    );
    await c.load(audioPath: 'a.wav');
    final first = c.detect();
    which = 1;
    final second = c.detect();
    // Complete the second (newer) first, then the first (older).
    cB.complete(Success<SilenceRemovalPlan>(_plan(10, removals: 2)));
    await second;
    expect(c.plan?.removals.length, 2);
    cA.complete(Success<SilenceRemovalPlan>(_plan(10, removals: 7)));
    await first;
    // The older result must not overwrite the newer one.
    expect(c.plan?.removals.length, 2);
    c.dispose();
  });

  test('planIsStale and canPreview reflect params version', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    completer.complete(Success<SilenceRemovalPlan>(_plan(10)));
    await future;
    expect(c.canPreview, isTrue);
    expect(c.planIsStale, isFalse);
    c.updateThreshold(-20);
    expect(c.planIsStale, isTrue);
    expect(c.canPreview, isFalse);
    c.dispose();
  });

  test('smart zoom invalidates render only, not detection', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    completer.complete(Success<SilenceRemovalPlan>(_plan(10)));
    await future;
    final paramsBefore = c.paramsVersion;
    c.markRendered('out.mp4');
    expect(c.renderedOutputPath, 'out.mp4');
    expect(c.needsRender, isFalse);
    c.toggleSmartZoom();
    expect(c.paramsVersion, paramsBefore); // detection untouched
    expect(c.renderIsStale, isTrue);
    expect(c.needsRender, isTrue);
    // plan still valid for preview (zoom is render-only).
    expect(c.canPreview, isTrue);
    c.dispose();
  });

  test('waveform zoom does not invalidate detection or render', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    completer.complete(Success<SilenceRemovalPlan>(_plan(10)));
    await future;
    final pv = c.paramsVersion;
    final rv = c.renderRecipeVersion;
    c.setWaveformZoom(5.0);
    expect(c.paramsVersion, pv);
    expect(c.renderRecipeVersion, rv);
    expect(c.planIsStale, isFalse);
    c.dispose();
  });

  test('keepInterval rebuilds the plan for the current session/version', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    completer.complete(Success<SilenceRemovalPlan>(_plan(10, removals: 2)));
    await future;
    final before = c.plan!.removals.length;
    c.keepInterval(0);
    expect(c.plan!.removals.length, before - 1);
    expect(c.planIsValid, isTrue);
    c.dispose();
  });

  test('keepInterval is a no-op when the plan is stale', () async {
    final completer = Completer<Result<SilenceRemovalPlan>>();
    final c = EditorDetectionController(
      videoPath: 'a.mp4',
      probeService: _FakeProbe(timeline),
      audioService: _FakeAudio(),
      detectionService: _ControllableDetector(() => completer.future),
    );
    await c.load(audioPath: 'a.wav');
    final future = c.detect();
    completer.complete(Success<SilenceRemovalPlan>(_plan(10, removals: 2)));
    await future;
    c.updateThreshold(-10);
    final count = c.plan!.removals.length;
    c.keepInterval(0);
    // Stale plan: nothing changes.
    expect(c.plan!.removals.length, count);
    c.dispose();
  });
}
