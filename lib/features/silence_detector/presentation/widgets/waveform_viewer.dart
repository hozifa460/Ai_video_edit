import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../audio_processing/domain/entities/waveform_data.dart';
import '../../../silence_detector/domain/entities/silence_segment.dart';

/// Draws the extracted audio over the **video** timeline.
///
/// The audio is a window on that timeline, not the whole of it: it can be
/// shorter than the video, and its origin can sit before or after the video's
/// (B01-R4). The widget therefore receives the audio span and its signed offset
/// and maps every sample through them, instead of stretching the samples across
/// the full width and inferring time from the video duration.
///
/// The space outside the audio window is left empty, so a peak keeps its real
/// position relative to the removal regions drawn underneath it, and a tap maps
/// to the same video time used by every other element on the screen.
class WaveformViewer extends StatelessWidget {
  final WaveformData? waveform;

  /// Normalized removal intervals on the **video** timeline.
  final List<SilenceSegment> silenceSegments;

  final double currentPosition;

  /// Length of the video timeline in seconds; the ruler for this widget.
  final double totalDuration;

  /// Length of the audio window in seconds. Falls back to the waveform's own
  /// duration when zero.
  final double audioDurationSeconds;

  /// Signed offset from the video origin to the audio origin, in seconds.
  final double audioStartSeconds;

  final double waveformZoom;
  final void Function(double seconds)? onSeek;

  const WaveformViewer({
    super.key,
    this.waveform,
    this.silenceSegments = const [],
    this.currentPosition = 0,
    this.totalDuration = 0,
    this.audioDurationSeconds = 0,
    this.audioStartSeconds = 0,
    this.waveformZoom = 1.0,
    this.onSeek,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final pixelWidth = constraints.maxWidth * waveformZoom;
        final pixelHeight = (100 * waveformZoom).clamp(100.0, 300.0);

        return ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: GestureDetector(
              onTapDown: (details) {
                if (onSeek != null && totalDuration > 0) {
                  final ratio = details.localPosition.dx / pixelWidth;
                  // Video time, matching the ruler every other layer uses.
                  onSeek!(ratio * totalDuration);
                }
              },
              child: Container(
                width: pixelWidth,
                height: pixelHeight,
                decoration: BoxDecoration(color: AppColors.surface),
                child: CustomPaint(
                  size: Size(pixelWidth, pixelHeight),
                  painter: _WaveformPainter(
                    waveform: waveform,
                    silenceSegments: silenceSegments,
                    currentPosition: currentPosition,
                    totalDuration: totalDuration,
                    audioDurationSeconds: audioDurationSeconds,
                    audioStartSeconds: audioStartSeconds,
                    waveformZoom: waveformZoom,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final WaveformData? waveform;
  final List<SilenceSegment> silenceSegments;
  final double currentPosition;
  final double totalDuration;
  final double audioDurationSeconds;
  final double audioStartSeconds;
  final double waveformZoom;

  /// Upper bound on the pixel column count, so an absurd zoom cannot make the
  /// envelope allocation unbounded.
  static const int _maxColumns = 1 << 20;

  _WaveformPainter({
    this.waveform,
    this.silenceSegments = const [],
    this.currentPosition = 0,
    this.totalDuration = 0,
    this.audioDurationSeconds = 0,
    this.audioStartSeconds = 0,
    this.waveformZoom = 1.0,
  });

  /// Length of the audio window actually drawn, in seconds.
  double get _audioSpanSeconds {
    if (audioDurationSeconds > 0 && audioDurationSeconds.isFinite) {
      return audioDurationSeconds;
    }
    final fallback = waveform?.durationSeconds ?? 0;
    return fallback.isFinite && fallback > 0 ? fallback : 0;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (totalDuration <= 0) return;

    _drawSilenceRegions(canvas, size);
    _drawWaveform(canvas, size);
    _drawPlayhead(canvas, size);
    _drawTimeMarkers(canvas, size);
  }

  void _drawSilenceRegions(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.silenceHighlight
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = AppColors.silenceBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    for (final segment in silenceSegments) {
      if (!segment.isValid) continue;
      final x1 = (segment.startSeconds / totalDuration) * size.width;
      final x2 = (segment.endSeconds / totalDuration) * size.width;
      final rect = Rect.fromLTRB(x1, 0, x2, size.height);
      canvas.drawRect(rect, paint);
      canvas.drawRect(rect, borderPaint);
    }
  }

  void _drawWaveform(Canvas canvas, Size size) {
    if (waveform == null || waveform!.samples.isEmpty) return;

    final audioSpan = _audioSpanSeconds;
    if (audioSpan <= 0) return;

    // The audio is a window on the ruler that may sit partly or wholly outside
    // it (a negative or oversized offset). Positions come from the real audio
    // span and the real signed offset, and anything landing outside the ruler is
    // simply not drawn - never stretched onto it or clamped to an edge.
    final audioStart = audioStartSeconds.isFinite ? audioStartSeconds : 0.0;

    final source = waveform!.samples;
    final count = source.length;
    // Left-edge convention, matching `WaveformData.getSampleAtTime`: sample i
    // starts at audio time `i / count * audioSpan`.
    final stepAudio = audioSpan / count;

    // Decimation, not sampling. Every source sample is placed in the pixel
    // column it actually falls on, and when several samples share a column the
    // **largest absolute value wins**. Stepping through the source with a stride
    // instead (the previous behaviour) silently dropped every sample it skipped:
    // with 2000 samples over 400px a peak at source index 1000 disappeared while
    // the one at 999 survived, making a non-silent file look flat (B01-F1).
    //
    // `size.width` already includes the zoom - the widget multiplies the
    // available width by `waveformZoom` before handing it to this painter - so
    // it is used as-is and never scaled a second time.
    final columnCount = size.width.ceil().clamp(1, _maxColumns);
    final envelope = List<double>.filled(columnCount, 0);
    final envelopeTime = List<double>.filled(columnCount, double.nan);
    final occupied = List<bool>.filled(columnCount, false);

    for (var i = 0; i < count; i++) {
      final videoTime = audioStart + i * stepAudio;
      if (videoTime < 0 || videoTime > totalDuration) continue;

      final column = (videoTime / totalDuration * columnCount).floor();
      if (column < 0 || column >= columnCount) continue;

      final magnitude = source[i].abs();
      if (!occupied[column] || magnitude > envelope[column]) {
        envelope[column] = magnitude;
        // The strongest sample's own time drives the silence colouring, so the
        // colour follows real activity rather than a column midpoint.
        envelopeTime[column] = videoTime;
        occupied[column] = true;
      }
    }

    final centerY = size.height / 2;
    final paint = Paint()
      ..color = AppColors.waveformColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    final silencePaint = Paint()
      ..color = AppColors.waveformSilence
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;

    for (var column = 0; column < columnCount; column++) {
      if (!occupied[column] || envelope[column] <= 0) continue;

      final x = column.toDouble();
      final amplitude = envelope[column] * (size.height / 2 - 4) * waveformZoom;
      final time = envelopeTime[column];

      final isInSilence = silenceSegments.any(
        (s) => s.isValid && time >= s.startSeconds && time <= s.endSeconds,
      );

      canvas.drawLine(
        Offset(x, centerY - amplitude),
        Offset(x, centerY + amplitude),
        isInSilence ? silencePaint : paint,
      );
    }
  }

  void _drawPlayhead(Canvas canvas, Size size) {
    final x = (currentPosition / totalDuration) * size.width;
    final paint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1.5;

    canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);

    final trianglePaint = Paint()..color = AppColors.primary;
    final path = Path()
      ..moveTo(x - 6, 0)
      ..lineTo(x + 6, 0)
      ..lineTo(x, 8)
      ..close();
    canvas.drawPath(path, trianglePaint);
  }

  void _drawTimeMarkers(Canvas canvas, Size size) {
    const markerCount = 5;
    if (totalDuration <= 0) return;

    final textPaint = TextPainter(textDirection: TextDirection.ltr);

    for (var i = 0; i <= markerCount; i++) {
      final x = (i / markerCount) * size.width;
      final timeSec = (i / markerCount) * totalDuration;
      final mins = (timeSec / 60).floor();
      final secs = (timeSec % 60).floor();

      textPaint.text = TextSpan(
        text:
            '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}',
        style: const TextStyle(color: AppColors.textTertiary, fontSize: 9),
      );
      textPaint.layout();
      textPaint.paint(
        canvas,
        Offset(x - textPaint.width / 2, size.height - 14),
      );
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter oldDelegate) {
    return oldDelegate.waveform != waveform ||
        oldDelegate.silenceSegments != silenceSegments ||
        oldDelegate.currentPosition != currentPosition ||
        oldDelegate.totalDuration != totalDuration ||
        oldDelegate.audioDurationSeconds != audioDurationSeconds ||
        oldDelegate.audioStartSeconds != audioStartSeconds ||
        oldDelegate.waveformZoom != waveformZoom;
  }
}
