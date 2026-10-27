// New scenarios for the same B1 contracts; prior acceptance is unchanged.
// Reuse only public fake services/fixtures from the first review file.
import 'dart:async';

import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/adaptive_threshold_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/providers/silence_detection_provider.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/controllers/editor_detection_controller.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/widgets/silence_timeline.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'codex_batch_b1_acceptance_test.dart' as fixture;

class PendingAuto extends AdaptiveThresholdService {
  final result = Completer<DetectionParams>();
  late DetectionParams snapshot;
  @override
  Future<DetectionParams> analyze({
    required String audioPath,
    required DetectionParams currentParams,
  }) {
    snapshot = currentParams;
    return result.future;
  }
}

EditorDetectionController create(PendingAuto auto, fixture.Detector detector) =>
    EditorDetectionController(
      videoPath: 'b.mp4',
      probeService: fixture.Probe(),
      detectionService: detector,
      autoThresholdService: auto,
    );

void main() {
  test('B1-R1: output started before SmartZoom edit cannot certify new recipe', () async {
    final c = fixture.controller();
    addTearDown(c.dispose);
    await fixture.ready(c);
    final oldOutput = Completer<String>();
    final pending = oldOutput.future.then(c.markRendered);
    c.toggleSmartZoom();
    oldOutput.complete('old_recipe.mp4');
    await pending;
    expect(c.needsRender, isTrue);
  });

  test('B1-R1: output started before keep cannot certify the new plan', () async {
    final c = fixture.controller();
    addTearDown(c.dispose);
    await fixture.ready(c);
    final oldOutput = Completer<String>();
    final pending = oldOutput.future.then(c.markRendered);
    c.keepInterval(0);
    oldOutput.complete('old_plan.mp4');
    await pending;
    expect(c.needsRender, isTrue);
  });

  test('B1-R3: late Auto must not undo a newer SmartZoom edit', () async {
    final auto = PendingAuto();
    final c = create(auto, fixture.Detector(() async => Success(fixture.plan())));
    addTearDown(c.dispose);
    await fixture.ready(c);
    final pending = c.autoDetectThreshold();
    c.toggleSmartZoom();
    auto.result.complete(auto.snapshot.copyWith(silenceThreshold: -31));
    await pending;
    expect(c.params.smartZoom.enabled, isTrue);
  });

  test('B1-R3: finishing Auto must not expose old plan during newer detection', () async {
    final auto = PendingAuto();
    final detector = fixture.Detector(() async => Success(fixture.plan()));
    final c = create(auto, detector);
    addTearDown(c.dispose);
    await fixture.ready(c);
    final autoPending = c.autoDetectThreshold();
    final result = Completer<Result<SilenceRemovalPlan>>();
    detector.answer = () => result.future;
    final detectionPending = c.detect();
    auto.result.complete(auto.snapshot);
    await autoPending;
    final previewWhilePending = c.canPreview;
    result.complete(Success(fixture.plan()));
    await detectionPending;
    expect(previewWhilePending, isFalse);
  });

  test('B1-R3: Auto started during detection must not restore detecting after completion', () async {
    final auto = PendingAuto();
    final result = Completer<Result<SilenceRemovalPlan>>();
    final c = create(auto, fixture.Detector(() => result.future));
    addTearDown(c.dispose);
    await c.load(audioPath: 'audio.wav', timeline: fixture.timeline);
    final detectionPending = c.detect();
    final autoPending = c.autoDetectThreshold();
    result.complete(Success(fixture.plan()));
    await detectionPending;
    auto.result.complete(auto.snapshot);
    await autoPending;
    expect(c.canPreview, isTrue);
    expect(c.isDetecting, isFalse);
  });

  testWidgets('B1-R4: timeline for B must not display the global A plan', (tester) async {
    final c = fixture.controller(detector: fixture.Detector(() async => Success(
      SilenceRemovalPlan.build(totalDurationSeconds: 10, removals: const []),
    )));
    addTearDown(c.dispose);
    await fixture.ready(c);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(silenceRemovalPlanProvider.notifier).setPlan(fixture.plan());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: SilenceTimeline(
        totalDuration: 10, controller: c,
      ))),
    ));
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  test('control B1-R2: old completion must not stop a newer detection', () async {
    final first = Completer<Result<SilenceRemovalPlan>>();
    final second = Completer<Result<SilenceRemovalPlan>>();
    var count = 0;
    final c = fixture.controller(detector: fixture.Detector(
      () => count++ == 0 ? first.future : second.future,
    ));
    addTearDown(c.dispose);
    await c.load(audioPath: 'audio.wav', timeline: fixture.timeline);
    final a = c.detect();
    final b = c.detect();
    first.complete(Success(fixture.plan()));
    await a;
    final stillDetecting = c.isDetecting;
    second.complete(Success(fixture.plan()));
    await b;
    expect(stillDetecting, isTrue);
    expect(c.canPreview, isTrue);
  });
}
