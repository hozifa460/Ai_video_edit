// Independent acceptance of waveform peak preservation at ordinary widths.
// Calls the actual painter; no media engine is involved.
import 'dart:ui' as ui;

import 'package:ai_video_editing/features/audio_processing/domain/entities/waveform_data.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/widgets/waveform_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final peakIndex in [999, 1000]) {
    testWidgets('waveform retains a peak at source index $peakIndex', (
      tester,
    ) async {
      final samples = List<double>.filled(2000, 0);
      samples[peakIndex] = 1;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 400,
            child: WaveformViewer(
              totalDuration: 10,
              waveform: WaveformData(
                samples: samples,
                sampleRate: 16000,
                durationSeconds: 10,
              ),
            ),
          ),
        ),
      );
      final widget = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(WaveformViewer),
          matching: find.byType(CustomPaint),
        ),
      );
      final recorder = ui.PictureRecorder();
      widget.painter!.paint(Canvas(recorder), const Size(400, 100));
      final picture = recorder.endRecording();
      final pixels = await tester.runAsync(() async {
        final image = await picture.toImage(400, 100);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        image.dispose();
        return bytes!;
      });
      picture.dispose();
      // A peak at ~5s belongs near x=200. Row 42 also accepts an averaged
      // representation of the peak; this does not require a full-height bar.
      var alpha = 0;
      for (var x = 198; x <= 201; x++) {
        final value = pixels!.getUint8((42 * 400 + x) * 4 + 3);
        if (value > alpha) alpha = value;
      }
      expect(
        alpha,
        greaterThan(0),
        reason: 'A nonzero source bin must not disappear due to stride phase.',
      );
    });
  }
}
