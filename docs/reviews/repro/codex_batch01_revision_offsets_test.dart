// Additional independent acceptance checks for the reviewed revision.
// Assert desired behavior; keep outside test/ until OpenCode fixes the defect.
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('B01-R1 follow-up: long pre-roll must retain the measured origin', () {
    final timeline = MediaTimeline.probed(
      videoDurationSeconds: 10,
      audioStartSeconds: -12,
      audioDurationSeconds: 22,
    );
    expect(
      timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 13, endSeconds: 14),
      ]),
      const [SilenceSegment(startSeconds: 1, endSeconds: 2)],
      reason: 'The offset is -12, even though the video lasts only 10 seconds.',
    );
  });

  test('B01-R1 follow-up: audio entirely before video contributes no removal', () {
    final timeline = MediaTimeline.probed(
      videoDurationSeconds: 10,
      audioStartSeconds: -12,
      audioDurationSeconds: 11,
    );
    expect(
      timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 10, endSeconds: 11),
      ]),
      isEmpty,
      reason: 'The true range [-2,-1] is outside video; do not invent [0,1].',
    );
  });

  test('B01-R1 follow-up: delayed audio retains its origin beyond video end', () {
    final timeline = MediaTimeline.probed(
      videoDurationSeconds: 10,
      audioStartSeconds: 12,
      audioDurationSeconds: 3,
    );
    expect(timeline.audioStartSeconds, 12);
    expect(timeline.detectionWindowEndSeconds, 0);
    expect(
      timeline.audioToVideoTimeline(const [
        SilenceSegment(startSeconds: 0, endSeconds: 1),
      ]),
      isEmpty,
    );
  });
}
