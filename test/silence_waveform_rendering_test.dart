import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ai_video_editing/features/audio_processing/domain/entities/waveform_data.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:ai_video_editing/features/silence_detector/presentation/widgets/waveform_viewer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression tests for the waveform painter.
///
/// Two review findings are covered here:
/// * **B01-R4** — the waveform must be drawn on the **video** ruler at its real
///   audio position, not stretched across the whole video timeline.
/// * **B01-F1** — decimation must preserve peaks. Stepping through the source
///   with a stride dropped the samples it skipped, so a peak could disappear
///   purely because of its phase in the stride cycle.
///
/// The painter is exercised for real: the widget is pumped at a pinned surface
/// size, its `CustomPainter` is driven against a recorded canvas, and the
/// resulting pixels are read back. FFmpeg and video playback are not involved,
/// so these prove the drawing geometry and the silence colouring only, never
/// that a rendered file matches its audio.
void main() {
  const widthPx = 400;
  const rulerPx = 400.0;
  const surfaceW = 400.0;
  const surfaceH = 100.0;

  /// Rows that only the waveform can reach. The time markers are painted near
  /// the bottom edge (y ≈ 86..100), so scanning this band ignores them.
  const bandTop = 30;
  const bandBottom = 70;

  /// A single peak as the third of four samples, i.e. audio time 4s of an 8s
  /// audio window. On a 10s/400px video ruler that belongs at x=160.
  const spiking = WaveformData(
    samples: [0, 0, 1, 0],
    sampleRate: 16000,
    durationSeconds: 8,
  );

  /// One bucket per second over [seconds], with the peak in the bucket starting
  /// at [peakAtSeconds]. Positions follow the left-edge convention, so bucket
  /// `i` starts at exactly `i` seconds.
  WaveformData peakingAt({
    required double seconds,
    required double peakAtSeconds,
  }) {
    final count = seconds.round();
    final peakIndex = peakAtSeconds.round();
    return WaveformData(
      samples: List<double>.generate(count, (i) => i == peakIndex ? 1.0 : 0.0),
      sampleRate: 16000,
      durationSeconds: seconds,
    );
  }

  Future<ByteData> render(
    WidgetTester tester,
    Widget viewer, {
    double? rulerWidth,
  }) async {
    tester.view.physicalSize = const ui.Size(surfaceW, surfaceH);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(MaterialApp(home: viewer));

    final customPaint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(WaveformViewer),
        matching: find.byType(CustomPaint),
      ),
    );
    final rasterWidth = (rulerWidth ?? rulerPx).round();
    final recorder = ui.PictureRecorder();
    customPaint.painter!.paint(
      Canvas(recorder),
      Size(rulerWidth ?? rulerPx, rulerPx),
    );
    final picture = recorder.endRecording();
    final raw = await tester.runAsync(() async {
      final image = await picture.toImage(rasterWidth, rulerPx.round());
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data;
    });
    picture.dispose();
    return raw!;
  }

  /// Strongest alpha in column [x] inside the waveform band.
  int inkInColumn(ByteData pixels, int x, [int rasterWidth = widthPx]) {
    var strongest = 0;
    for (var y = bandTop; y <= bandBottom; y++) {
      final a = pixels.getUint8((y * rasterWidth + x) * 4 + 3);
      if (a > strongest) strongest = a;
    }
    return strongest;
  }

  /// Single alpha sample, for asserting one row of a bar.
  int alphaAt(ByteData pixels, int x, int y, int rasterWidth) {
    return pixels.getUint8((y * rasterWidth + x) * 4 + 3);
  }

  bool anyInkBetween(
    ByteData pixels,
    int fromX,
    int toX, [
    int rasterWidth = widthPx,
  ]) {
    final last = toX.clamp(0, rasterWidth - 1);
    for (var x = fromX.clamp(0, rasterWidth - 1); x <= last; x++) {
      if (inkInColumn(pixels, x, rasterWidth) > 0) return true;
    }
    return false;
  }

  /// Red/green/blue of column [x], row 20, which a full-amplitude peak covers.
  List<int> rgbAt(ByteData pixels, int x, int y) {
    final offset = (y * widthPx + x) * 4;
    return [
      pixels.getUint8(offset),
      pixels.getUint8(offset + 1),
      pixels.getUint8(offset + 2),
      pixels.getUint8(offset + 3),
    ];
  }

  group('B01-R4 the waveform sits on the video ruler', () {
    testWidgets('an 8s waveform on a 10s ruler keeps its peak at second 4', (
      tester,
    ) async {
      final pixels = await render(
        tester,
        const WaveformViewer(totalDuration: 10, waveform: spiking),
      );

      expect(
        inkInColumn(pixels, 160),
        greaterThan(0),
        reason: 'audio t=4s must be drawn at 4/10 of the video ruler',
      );
      // The stretched version put the peak at 5s => x=200.
      expect(
        inkInColumn(pixels, 200),
        0,
        reason: 'the peak must not be stretched to the middle of the video',
      );
    });

    testWidgets('the ruler past the end of the audio stays empty', (
      tester,
    ) async {
      final pixels = await render(
        tester,
        const WaveformViewer(totalDuration: 10, waveform: spiking),
      );

      // 8s of audio ends at x=320; 8s..10s is picture with no audio.
      expect(
        anyInkBetween(pixels, 322, widthPx - 1),
        isFalse,
        reason: '8s of audio must not be stretched across the full 10s ruler',
      );
    });

    testWidgets('an explicit audio duration overrides the waveform duration', (
      tester,
    ) async {
      // Same samples, but the audio window is declared as 4s: the peak sits at
      // audio t=2s => 2/10 of the ruler => x=80.
      final pixels = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 4,
          waveform: spiking,
        ),
      );

      expect(inkInColumn(pixels, 80), greaterThan(0));
      expect(inkInColumn(pixels, 160), 0);
    });

    testWidgets('a positive audio offset moves the audio window right', (
      tester,
    ) async {
      // Audio starts at 2s: the peak at audio t=4s is video t=6s => x=240, and
      // nothing may be drawn before x=80.
      final pixels = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 8,
          audioStartSeconds: 2,
          waveform: spiking,
        ),
      );

      expect(inkInColumn(pixels, 240), greaterThan(0));
      expect(inkInColumn(pixels, 160), 0);
      expect(anyInkBetween(pixels, 2, 78), isFalse);
    });

    testWidgets('a negative audio offset shifts the window left', (
      tester,
    ) async {
      // Audio starts 1s before the video and runs 9s, so the peak at audio
      // t=4.5s is video t=3.5s => x=140. The unshifted answer would be 160.
      final pixels = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 9,
          audioStartSeconds: -1,
          waveform: spiking,
        ),
      );

      expect(inkInColumn(pixels, 140), greaterThan(0));
      expect(inkInColumn(pixels, 160), 0);
    });

    testWidgets('a pre-roll longer than the video is not stretched onto it', (
      tester,
    ) async {
      // Video 10s, audio 22s starting 12s earlier. The peak sits at audio t=16s,
      // i.e. video t=4s => x=160. A painter that scaled the audio across the
      // ruler would place it by ratio (16/22 of the width ≈ x291).
      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          audioStartSeconds: -12,
          waveform: peakingAt(seconds: 22, peakAtSeconds: 16),
        ),
      );

      expect(inkInColumn(pixels, 160), greaterThan(0));
      expect(anyInkBetween(pixels, 162, widthPx - 1), isFalse);
    });

    testWidgets('audio entirely before the video draws nothing', (
      tester,
    ) async {
      // Video 10s, audio 11s starting 12s earlier: the whole window is off-screen
      // and must not be clamped onto the ruler.
      final pixels = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 11,
          audioStartSeconds: -12,
          waveform: spiking,
        ),
      );

      expect(anyInkBetween(pixels, 2, widthPx - 1), isFalse);
    });

    testWidgets('audio entirely after the video draws nothing', (tester) async {
      final pixels = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 3,
          audioStartSeconds: 12,
          waveform: spiking,
        ),
      );

      expect(anyInkBetween(pixels, 2, widthPx - 1), isFalse);
    });

    testWidgets('silence regions are matched against video time when colouring', (
      tester,
    ) async {
      // A removal region covering video 5s..6s (x 200..240).
      final region = const [SilenceSegment(startSeconds: 5, endSeconds: 6)];

      // Aligned audio: the peak at video t=4s is outside the region, so it keeps
      // the ordinary waveform colour, whose dominant channel is blue.
      final aligned = await render(
        tester,
        const WaveformViewer(totalDuration: 10, waveform: spiking),
      );
      expect(anyInkBetween(aligned, 200, 240), isFalse);
      final alignedPeak = rgbAt(aligned, 160, 20);
      expect(alignedPeak[3], greaterThan(0));
      expect(
        alignedPeak[2],
        greaterThan(alignedPeak[0]),
        reason: 'an unshifted peak must use waveformColor (blue dominant)',
      );
      expect(alignedPeak[0], greaterThan(alignedPeak[1]));

      // Audio offset +2s: the same peak is now video t=6s, inside the region, and
      // must be painted with the silence colour, whose dominant channel is red.
      final shifted = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 8,
          audioStartSeconds: 2,
          silenceSegments: region,
          waveform: spiking,
        ),
      );
      expect(anyInkBetween(shifted, 200, 240), isTrue);
      final shiftedPeak = rgbAt(shifted, 240, 20);
      expect(shiftedPeak[3], greaterThan(0));
      expect(
        shiftedPeak[0],
        greaterThan(shiftedPeak[2]),
        reason: 'a peak inside a removal region must use waveformSilence',
      );
      expect(shiftedPeak[0], greaterThan(shiftedPeak[1]));
    });

    testWidgets('only valid silence segments paint a removal band', (
      tester,
    ) async {
      // No waveform, so anything in the band comes from a removal region alone.
      final invalid = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          silenceSegments: [
            SilenceSegment(startSeconds: 5, endSeconds: 2),
            SilenceSegment(startSeconds: 3, endSeconds: 3),
            SilenceSegment(startSeconds: double.nan, endSeconds: 4),
          ],
        ),
      );
      // x=0..1 holds the playhead at position 0, which is always drawn.
      expect(anyInkBetween(invalid, 2, widthPx - 1), isFalse);

      final valid = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          silenceSegments: [SilenceSegment(startSeconds: 2, endSeconds: 4)],
        ),
      );
      expect(anyInkBetween(valid, 80, 160), isTrue);
      expect(anyInkBetween(valid, 162, widthPx - 1), isFalse);
    });

    testWidgets(
      'a zero-length ruler draws nothing instead of dividing by zero',
      (tester) async {
        final pixels = await render(
          tester,
          const WaveformViewer(totalDuration: 0, waveform: spiking),
        );
        expect(inkInColumn(pixels, 160), 0);
      },
    );

    testWidgets('a missing waveform leaves the ruler empty', (tester) async {
      final pixels = await render(
        tester,
        const WaveformViewer(totalDuration: 10),
      );
      expect(inkInColumn(pixels, 160), 0);
    });

    testWidgets('an empty sample list leaves the ruler empty', (tester) async {
      final pixels = await render(
        tester,
        const WaveformViewer(
          totalDuration: 10,
          waveform: WaveformData(
            samples: [],
            sampleRate: 16000,
            durationSeconds: 8,
          ),
        ),
      );
      expect(inkInColumn(pixels, 160), 0);
    });

    testWidgets('tapping maps to video time on the ruler', (tester) async {
      final seeks = <double>[];
      await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 8,
          audioStartSeconds: 2,
          waveform: spiking,
          onSeek: seeks.add,
        ),
      );

      final left = tester.getTopLeft(find.byType(WaveformViewer)).dx;
      // A quarter of the ruler is 2.5s of video time regardless of the offset.
      await tester.tapAt(Offset(left + widthPx / 4, 50));
      await tester.pump();

      expect(seeks, isNotEmpty);
      expect(seeks.last, closeTo(2.5, 0.05));
    });

    testWidgets(
      'tapping inside a shifted audio window still seeks video time',
      (tester) async {
        final seeks = <double>[];
        await render(
          tester,
          WaveformViewer(
            totalDuration: 10,
            audioDurationSeconds: 8,
            audioStartSeconds: 2,
            waveform: spiking,
            onSeek: seeks.add,
          ),
        );

        final left = tester.getTopLeft(find.byType(WaveformViewer)).dx;
        // x=240 is the peak: video t=6s, audio t=4s.
        await tester.tapAt(Offset(left + 240, 50));
        await tester.pump();

        expect(seeks.last, closeTo(6.0, 0.05));
      },
    );
  });

  group('B01-F1 decimation preserves peaks', () {
    // The previous painter stepped the source with a stride and read only the
    // samples it landed on, so a peak could vanish purely because of where it
    // fell in the stride cycle. Every phase must now survive.
    for (final peakIndex in [999, 1000, 1001, 1999]) {
      testWidgets('a lone peak at source index $peakIndex is drawn', (
        tester,
      ) async {
        final samples = List<double>.filled(2000, 0);
        samples[peakIndex] = 1;

        final pixels = await render(
          tester,
          WaveformViewer(
            totalDuration: 10,
            waveform: WaveformData(
              samples: samples,
              sampleRate: 16000,
              durationSeconds: 10,
            ),
          ),
        );

        // Source index i starts at i/2000*10s, i.e. column i/5 on a 10s/400px
        // ruler. Any ink in the expected column proves the peak survived.
        final expectedColumn = (peakIndex / 2000 * 10 * 40).floor();
        expect(
          inkInColumn(pixels, expectedColumn),
          greaterThan(0),
          reason: 'a nonzero source bin must not disappear with stride phase',
        );
      });
    }

    testWidgets('a peak is preserved at a narrow width too', (tester) async {
      final samples = List<double>.filled(2000, 0);
      samples[1234] = 1;

      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          waveform: WaveformData(
            samples: samples,
            sampleRate: 16000,
            durationSeconds: 10,
          ),
        ),
        rulerWidth: 120,
      );

      // 1234/2000*10s = 6.17s, which is 0.617 of a 120px ruler.
      final expectedColumn = (1234 / 2000 * 10 * 12).floor();
      expect(inkInColumn(pixels, expectedColumn, 120), greaterThan(0));
    });

    testWidgets('a peak is preserved at high zoom', (tester) async {
      final samples = List<double>.filled(2000, 0);
      samples[1500] = 1;

      // 8x zoom makes the widget hand the painter a 3200px-wide ruler.
      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          waveformZoom: 8,
          waveform: WaveformData(
            samples: samples,
            sampleRate: 16000,
            durationSeconds: 10,
          ),
        ),
        rulerWidth: 3200,
      );

      // 1500/2000*10s = 7.5s, which is 0.75 of the 3200px ruler => x = 2400.
      expect(inkInColumn(pixels, 2400, 3200), greaterThan(0));
    });

    testWidgets('when several samples share a column the loudest wins', (
      tester,
    ) async {
      // Three peaks inside one 400px column: the tallest must set the height.
      final samples = List<double>.filled(2000, 0);
      samples[10] = 0.3;
      samples[11] = 1.0;
      samples[12] = 0.2;

      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          waveform: WaveformData(
            samples: samples,
            sampleRate: 16000,
            durationSeconds: 10,
          ),
        ),
      );

      final column = (10 / 2000 * 10 * 40).floor();
      // Amplitude 1.0 reaches y=4, while 0.3 would stop near y=36.
      expect(inkInColumn(pixels, column), greaterThan(0));
      expect(
        alphaAt(pixels, column, 8, widthPx),
        greaterThan(0),
        reason: 'the column must reach the top of the canvas like a 1.0 peak',
      );
    });

    testWidgets('a peak on the intersection boundary is still drawn', (
      tester,
    ) async {
      // Offset -1s: the peak at audio t=1s sits exactly on video time 0, the
      // first visible column.
      final samples = List<double>.filled(100, 0);
      samples[10] = 1;

      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 10,
          audioStartSeconds: -1,
          waveform: WaveformData(
            samples: samples,
            sampleRate: 16000,
            durationSeconds: 10,
          ),
        ),
      );

      expect(inkInColumn(pixels, 0), greaterThan(0));
    });

    testWidgets('activity just past the video end is not drawn', (
      tester,
    ) async {
      final samples = List<double>.filled(1000, 0);
      // Audio t=9.9s with offset +1 lands on video t=10.9s, outside the ruler.
      samples[990] = 1;

      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          audioDurationSeconds: 10,
          audioStartSeconds: 1,
          waveform: WaveformData(
            samples: samples,
            sampleRate: 16000,
            durationSeconds: 10,
          ),
        ),
      );

      expect(anyInkBetween(pixels, 2, widthPx - 1), isFalse);
    });

    testWidgets('a dense signal keeps its height across the whole ruler', (
      tester,
    ) async {
      // Every source sample at full amplitude: no column may come out flat.
      final pixels = await render(
        tester,
        WaveformViewer(
          totalDuration: 10,
          waveform: WaveformData(
            samples: List<double>.filled(2000, 1),
            sampleRate: 16000,
            durationSeconds: 10,
          ),
        ),
      );

      for (var x = 2; x < widthPx; x += 37) {
        expect(
          inkInColumn(pixels, x),
          greaterThan(0),
          reason: 'column $x must not be flat',
        );
      }
    });
  });
}
