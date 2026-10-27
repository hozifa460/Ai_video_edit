// Independent desired behavior for B1; actual controller and timeline widget.
import 'dart:async';

import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_detection_blocker.dart';
import 'package:ai_video_editing/features/silence_detector/domain/services/editor_services.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/controllers/editor_detection_controller.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/widgets/silence_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/providers/silence_detection_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const timeline = MediaTimeline(
  videoDurationSeconds: 10,
  audioDurationSeconds: 10,
);
SilenceRemovalPlan plan() => SilenceRemovalPlan.build(
  totalDurationSeconds: 10,
  removals: const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
);

class Probe implements MediaProbeService {
  @override
  Future<Result<MediaTimeline>> probe(String path) async => const Success(timeline);
}

class Detector implements SilenceDetectionService {
  Future<Result<SilenceRemovalPlan>> Function() answer;
  Detector(this.answer);
  @override
  Future<Result<SilenceRemovalPlan>> detect({
    required String audioPath,
    required DetectionParams params,
    required MediaTimeline timeline,
  }) => answer();
}

EditorDetectionController controller({Detector? detector}) =>
    EditorDetectionController(
      videoPath: 'test.mp4',
      probeService: Probe(),
      detectionService: detector ?? Detector(() async => Success(plan())),
    );

Future<void> ready(EditorDetectionController c) async {
  // Guaranteed nonexistent path: Auto's file-existence fallback needs no plugin.
  await c.load(audioPath: 'docs/reviews/repro/__missing_b1_audio__.wav');
  await c.detect();
}

void main() {
  test('B1-R1: keeping a range invalidates its rendered output', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    c.markRendered('old.mp4');
    c.keepInterval(0);
    expect(c.needsRender, isTrue);
  });

  test('B1-R1: new detection invalidates the previous rendered output', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    c.markRendered('old.mp4');
    c.updateThreshold(-30);
    await c.detect();
    expect(c.needsRender, isTrue);
  });

  test('B1-R1: a closed session cannot accept a late rendered output', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    c.close();
    c.markRendered('late.mp4');
    expect(c.renderedOutputPath, isNull);
  });

  test('B1-R2: discarded detection does not remain in detecting status', () async {
    final result = Completer<Result<SilenceRemovalPlan>>();
    final c = controller(detector: Detector(() => result.future));
    addTearDown(c.dispose);
    await c.load(audioPath: 'audio.wav');
    final pending = c.detect();
    c.updateThreshold(-30);
    result.complete(Success(plan()));
    await pending;
    expect(c.isDetecting, isFalse);
    expect(c.canPreview, isFalse);
  });

  test('B1-R3: Auto must not overwrite a newer manual setting', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    final pending = c.autoDetectThreshold();
    c.updateThreshold(-21);
    await pending;
    expect(c.params.silenceThreshold, -21);
  });

  test('B1-R3: Auto finishing after disposal must not notify or commit', () async {
    final c = controller();
    await ready(c);
    final pending = c.autoDetectThreshold();
    c.dispose();
    await expectLater(pending, completes);
  });

  test('B1-R3: unchanged Auto result does not disable a current plan', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    await c.autoDetectThreshold();
    expect(c.planIsValid, isTrue);
    expect(c.canPreview, isTrue);
  });

  testWidgets('B1-R4: stale controller must not fall back to editing global plan', (tester) async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    final original = c.plan!;
    c.updateThreshold(-30);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(silenceRemovalPlanProvider.notifier).setPlan(original);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: SilenceTimeline(
        totalDuration: 10, controller: c,
      ))),
    ));
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(container.read(silenceRemovalPlanProvider), original);
  });

  test('B1-R5: controller preserves the shared blocker message contract', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    c.setTimeline(const MediaTimeline(videoDurationSeconds: 0));
    await c.detect();
    expect(c.detectionError, SilenceDetectionGate.messageFor(
      SilenceDetectionBlocker.unusableMediaDuration,
    ));
  });

  test('control: unchanged current detection remains previewable', () async {
    final c = controller();
    addTearDown(c.dispose);
    await ready(c);
    expect(c.canPreview, isTrue);
    c.setWaveformZoom(3);
    expect(c.canPreview, isTrue);
  });
}
