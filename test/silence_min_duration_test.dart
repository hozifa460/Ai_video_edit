import 'package:ai_video_editing/core/utils/result.dart';
import 'package:ai_video_editing/features/silence_detector/data/datasources/ffmpeg_silence_datasource.dart';
import 'package:ai_video_editing/features/silence_detector/data/repositories/silence_detector_repository_impl.dart';
import 'package:ai_video_editing/features/silence_detector/data/services/vad_service.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/detection_params.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/media_timeline.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_removal_plan.dart';
import 'package:ai_video_editing/features/silence_detector/domain/entities/silence_segment.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regressions for SR-06: the user's minimum silence duration must be effective in
/// **every** `silencedetect` pass, including the trailing one.
///
/// The second pass used to hardcode `minSilenceDuration: 0.3`, so with the user
/// asking for silences of 2s or more a 0.4s pause found only by that pass was
/// still deleted — content loss the user had explicitly excluded.
///
/// Two boundary defects followed and are pinned here too:
/// * **SR06-R1** — the limit comparison must use only a *numeric* margin, so a
///   genuinely shorter length (9.5ms at a 10ms limit) is rejected.
/// * **SR06-R2** — an unterminated trailing `silence_start` must be closed
///   whenever the range is well formed, so a 20ms trailing silence is not
///   dropped at a 10ms minimum.
///
/// The real datasource is driven through a mocked FFmpegKit channel that reads
/// the `noise=`/`d=` pair out of each executed command and answers with a
/// **different** log per `d=` value. Returning identical logs for every call
/// would let a broken pass implementation pass unnoticed, so the mock is keyed
/// on the command under test rather than on one shared string.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter.arthenica.com/ffmpeg_kit');
  const events = MethodChannel('flutter.arthenica.com/ffmpeg_kit_event');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Every executed command, in order, joined for readability.
  final commands = <String>[];

  /// Logs keyed by the `d=` value of the command that produced them.
  var logsByDuration = <String, String>{};
  var defaultLogs = '';

  var nextSession = 0;
  var sessions = <int, String>{};

  /// Parses the `d=` value out of a joined command string.
  String? durationOf(String command) {
    final match = RegExp(
      r'silencedetect=[^:]*:d=([0-9.]+)',
    ).firstMatch(command);
    return match?.group(1);
  }

  /// Parses the `noise=` value out of a joined command string.
  String? noiseOf(String command) {
    final match = RegExp(
      r'silencedetect=noise=(-?[0-9.]+)dB',
    ).firstMatch(command);
    return match?.group(1);
  }

  setUp(() {
    commands.clear();
    sessions.clear();
    logsByDuration = {};
    defaultLogs = '';

    messenger.setMockMethodCallHandler(events, (_) async => null);
    messenger.setMockMethodCallHandler(channel, (call) async {
      switch (call.method) {
        case 'getLogLevel':
          return 32;
        case 'getPlatform':
        case 'getArch':
        case 'getPackageName':
          return 'test';
        case 'isLTSBuild':
          return false;
        case 'setLogLevel':
        case 'enableRedirection':
        case 'ffmpegSessionExecute':
        case 'mediaInformationSessionExecute':
          return null;
        case 'ffmpegSession':
          final arguments =
              (call.arguments as Map)['arguments'] as List<dynamic>? ??
              const <dynamic>[];
          final command = arguments.map((a) => '$a').join(' ');
          commands.add(command);
          final sessionId = ++nextSession;
          final duration = durationOf(command);
          sessions[sessionId] = logsByDuration[duration] ?? defaultLogs;
          return {'sessionId': sessionId, 'createTime': 0, 'startTime': 0};
        case 'abstractSessionGetReturnCode':
          return 0;
        case 'abstractSessionGetAllLogsAsString':
          final id = (call.arguments as Map)['sessionId'] as int?;
          return sessions[id] ?? '';
        case 'getMediaInformation':
          return <String, Object?>{};
        default:
          throw StateError('Unexpected plugin method: ${call.method}');
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(events, null);
  });

  /// Builds `silence_start`/`silence_end` log text for the given ranges.
  String logFor(List<(double, double)> ranges) {
    final buffer = StringBuffer();
    for (final (start, end) in ranges) {
      buffer.writeln('silence_start: $start');
      buffer.writeln('silence_end: $end | silence_duration: ${end - start}');
    }
    return buffer.toString();
  }

  /// Log text with a single unterminated `silence_start` — what ffmpeg emits
  /// when the stream ends mid-silence.
  String trailingLog(double start) => 'silence_start: $start\n';

  DetectionParams paramsWith({
    double threshold = -40,
    double minSilence = 0.25,
    double guardBefore = 0,
    double guardAfter = 0,
  }) {
    return DetectionParams(
      silenceThreshold: threshold,
      minSilenceDuration: minSilence,
      paddingBefore: guardBefore,
      paddingAfter: guardAfter,
      useVad: false,
      useBreathingProtection: false,
    );
  }

  Future<List<SilenceSegment>> detect(
    DetectionParams params, {
    double totalDuration = 20,
  }) {
    return FfmpegSilenceDatasource().detectSilence(
      audioPath: 'mock.wav',
      params: params,
      totalDuration: totalDuration,
    );
  }

  group('the single pass is commanded with the user minimum', () {
    for (final min in [0.01, 0.25, 2.0, 5.0]) {
      test('min=$min reaches the only pass and nothing else', () async {
        await detect(paramsWith(minSilence: min));

        expect(commands.length, 1);
        // The single `d=` must be the user's value.
        expect(commands.map(durationOf).toSet(), {'$min'});
        for (final command in commands) {
          expect(command, contains('d=$min'));
          expect(
            command,
            isNot(contains('d=0.3')),
            reason: 'no pass may substitute its own 0.3s limit',
          );
        }
      });
    }

    test('the pass uses the user threshold and minimum', () async {
      await detect(paramsWith(threshold: -40, minSilence: 2));

      expect(commands.map(noiseOf).toList(), ['-40.0']);
      expect(commands.map(durationOf).toSet(), {'2.0'});
    });
  });

  group('a silence shorter than the minimum never enters removal', () {
    // 0.4s is below these minimums, so it must be rejected.
    for (final min in [2.0, 5.0]) {
      test('a 0.4s pause is rejected at min=$min', () async {
        logsByDuration = {
          '$min': logFor(const [(1, 1.4)]),
        };
        expect(await detect(paramsWith(minSilence: min)), isEmpty);
      });
    }

    // 0.4s is above these minimums, so it must survive: the minimum is a floor
    // on detection, not a fixed duration.
    for (final min in [0.01, 0.25]) {
      test('a 0.4s pause is kept at min=$min', () async {
        logsByDuration = {
          '$min': logFor(const [(1, 1.4)]),
        };
        expect(await detect(paramsWith(minSilence: min)), [
          const SilenceSegment(startSeconds: 1, endSeconds: 1.4),
        ]);
      });
    }

    for (final duration in [0.4, 0.9, 1.99]) {
      test('a ${duration}s pause is rejected at min=2s', () async {
        logsByDuration = {
          '2.0': logFor([(1, 1 + duration)]),
        };
        expect(await detect(paramsWith(minSilence: 2)), isEmpty);
      });
    }

    test('a 2s pause is accepted at min=2s', () async {
      logsByDuration = {
        '2.0': logFor(const [(1, 3)]),
      };
      expect(await detect(paramsWith(minSilence: 2)), [
        const SilenceSegment(startSeconds: 1, endSeconds: 3),
      ]);
    });

    test('a 2.01s pause is accepted at min=2s', () async {
      logsByDuration = {
        '2.0': logFor(const [(1, 3.01)]),
      };
      final result = await detect(paramsWith(minSilence: 2));
      expect(result.length, 1);
      expect(result.single.durationSeconds, closeTo(2.01, 1e-9));
    });

    test('a 5s pause is accepted at min=5s', () async {
      logsByDuration = {
        '5.0': logFor(const [(1, 6)]),
      };
      expect(await detect(paramsWith(minSilence: 5)), [
        const SilenceSegment(startSeconds: 1, endSeconds: 6),
      ]);
    });
  });

  group('SR06-R1 the limit margin is numeric, not a duration', () {
    test('the margin is a derived count of rounding steps', () {
      // 3 parsed bounds + 1 rounding of the difference. A count, not a tuned
      // constant, and not a duration in seconds.
      expect(FfmpegSilenceDatasource.kBoundaryRoundingSteps, 4);
    });

    test('the margin is a few units in the last place of the magnitude', () {
      for (final scale in [0.01, 0.25, 2.0, 5.0]) {
        final margin = FfmpegSilenceDatasource.numericMarginFor(scale);
        expect(margin, greaterThan(0));
        // Nowhere near a duration the detector can act on.
        expect(margin, lessThan(1e-12));
        // And never a fixed millisecond in disguise.
        expect(margin, lessThan(scale / 1e9));
      }
    });

    test('the margin scales with the magnitude instead of being constant', () {
      final small = FfmpegSilenceDatasource.numericMarginFor(0.01);
      final large = FfmpegSilenceDatasource.numericMarginFor(5.0);
      expect(large, greaterThan(small));
    });

    test('the margin stays far below one audio sample at any timestamp', () {
      // 62.5us is one sample at 16kHz. At 24 hours the margin is ~7.7e-11s,
      // roughly one eight-thousandth of that sample.
      const sample = 1 / 16000;
      for (final seconds in [1.0, 3600.0, 86400.0]) {
        expect(
          FfmpegSilenceDatasource.numericMarginFor(seconds),
          lessThan(sample / 8000),
          reason: 'at ${seconds}s the margin must stay sub-sample',
        );
      }
      // Reaching one whole sample would need a magnitude of ~7e10 seconds,
      // i.e. a timestamp about 2200 years out.
      final secondsForOneSample =
          sample /
          (FfmpegSilenceDatasource.kBoundaryRoundingSteps *
              2.220446049250313e-16);
      expect(secondsForOneSample, greaterThan(1e10));
    });

    test(
      'the margin follows the magnitude, so a negative scale uses its size',
      () {
        expect(FfmpegSilenceDatasource.numericMarginFor(0), 0);
        expect(
          FfmpegSilenceDatasource.numericMarginFor(-1),
          FfmpegSilenceDatasource.numericMarginFor(1),
        );
      },
    );

    test('a zero or negative minimum has no margin and accepts anything', () {
      expect(FfmpegSilenceDatasource.satisfiesMinimumSilence(0.001, 0), isTrue);
      expect(
        FfmpegSilenceDatasource.satisfiesMinimumSilence(0.001, -1),
        isTrue,
      );
      expect(
        FfmpegSilenceDatasource.satisfiesMinimumInterval(3600, 3600.001, 0),
        isTrue,
      );
      expect(
        FfmpegSilenceDatasource.satisfiesMinimumInterval(3600, 3600.001, -1),
        isTrue,
      );
    });

    test('a length exactly at the minimum is accepted', () {
      for (final min in [0.01, 0.25, 2.0, 5.0]) {
        expect(
          FfmpegSilenceDatasource.satisfiesMinimumSilence(min, min),
          isTrue,
          reason: 'min=$min must accept a length exactly at the limit',
        );
      }
    });

    test('binary subtraction at the limit is still accepted', () {
      // `0.3 - 0.1` is 0.19999999999999998, one unit in the last place below
      // 0.2. This is the case the numeric margin exists for.
      final computed = 0.3 - 0.1;
      expect(computed, lessThan(0.2));
      expect(
        FfmpegSilenceDatasource.satisfiesMinimumSilence(computed, 0.2),
        isTrue,
      );
    });

    test(
      'the margin accepts exactly the derived noise and refuses beyond it',
      () {
        // Exactly the derived bound is the largest shortfall representation can
        // explain. A thousand times it is still 5e-13 of the minimum, yet it is
        // no longer a rounding artefact and must be refused. The factor has to
        // be large enough for the difference to exist as a distinct double.
        for (final min in [0.2, 0.3, 2.0, 5.0]) {
          final margin = FfmpegSilenceDatasource.numericMarginFor(min);
          expect(
            FfmpegSilenceDatasource.satisfiesMinimumSilence(min - margin, min),
            isTrue,
            reason:
                'min=$min: the derived margin itself is representable noise',
          );
          expect(
            FfmpegSilenceDatasource.satisfiesMinimumSilence(
              min - margin * 1000,
              min,
            ),
            isFalse,
            reason: 'min=$min: a thousand margins out is a real gap',
          );
        }
      },
    );

    test('a genuinely shorter length is rejected however close it is', () {
      // SR06-R1: 9.5ms does not satisfy 10ms. The previous 1ms reduction
      // accepted it, and 1ms was 10% of the smallest configurable minimum.
      expect(
        FfmpegSilenceDatasource.satisfiesMinimumSilence(0.0095, 0.01),
        isFalse,
      );
      for (final min in [0.01, 0.25, 2.0, 5.0]) {
        // One part in a thousand short is a real difference, not float noise.
        expect(
          FfmpegSilenceDatasource.satisfiesMinimumSilence(min * 0.999, min),
          isFalse,
          reason: 'min=$min must reject a genuinely shorter silence',
        );
        expect(
          FfmpegSilenceDatasource.satisfiesMinimumSilence(min * 0.5, min),
          isFalse,
        );
      }
    });

    test('a non-finite length is never accepted', () {
      for (final bad in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          FfmpegSilenceDatasource.satisfiesMinimumSilence(bad, 2),
          isFalse,
        );
      }
    });

    test(
      'the 9.5ms case is rejected through the datasource, not just the helper',
      () async {
        logsByDuration = {
          '0.01': logFor(const [(2, 2.0095)]),
        };
        expect(await detect(paramsWith(minSilence: 0.01)), isEmpty);
      },
    );

    test('a boundary-length interval is kept through the datasource', () async {
      logsByDuration = {
        '0.2': logFor([(1, 1 + (0.3 - 0.1))]),
      };
      final result = await detect(paramsWith(minSilence: 0.2));
      expect(result.length, 1);
      expect(result.single.durationSeconds, closeTo(0.3 - 0.1, 1e-15));
    });
  });

  group('SR06-R3 the verdict follows the interval, not its position', () {
    // Every position below is the same exact decimal silence. Moving it along
    // the timeline must not change the verdict, and a genuinely shorter silence
    // at the same positions must still be rejected.
    const positions = <double>[0.01, 9.98, 3599.99, 3600.01, 86400.01];
    const later = <double>[0.02, 9.99, 3600.0, 3600.02, 86400.02];

    test('an exact 10ms silence is accepted at every position', () async {
      for (var i = 0; i < positions.length; i++) {
        final start = positions[i];
        final end = later[i];
        defaultLogs =
            'silence_start: $start\nsilence_end: $end | '
            'silence_duration: 0.01\n';
        expect(
          await detect(paramsWith(minSilence: 0.01), totalDuration: end + 1),
          [SilenceSegment(startSeconds: start, endSeconds: end)],
          reason: '[$start,$end] is 10ms of silence exactly',
        );
      }
    });

    test('a 9.5ms silence is rejected at every position', () async {
      for (var i = 0; i < positions.length; i++) {
        final start = positions[i];
        final end = later[i] - 0.0005;
        defaultLogs =
            'silence_start: $start\nsilence_end: $end | '
            'silence_duration: 0.0095\n';
        expect(
          await detect(
            paramsWith(minSilence: 0.01),
            totalDuration: later[i] + 1,
          ),
          isEmpty,
          reason: '[$start,$end] is 9.5ms, which the user excluded at 10ms',
        );
      }
    });

    test('only the interval form gives the same verdict at every position', () {
      // Same exact length, three positions. The interval form sees the bounds,
      // so it accepts everywhere. The bound-free form lost them, so its verdict
      // flips with the position: near zero the subtraction is exact and it
      // accepts, an hour in the shortfall exceeds any bound-free margin and it
      // refuses. That position dependence is the defect R3 reports, and it is
      // why no filtering path may use the bound-free form.
      const cases = [(0.01, 0.02), (9.98, 9.99), (3600.01, 3600.02)];
      var refusalsByPosition = 0;
      for (final bounds in cases) {
        final length = bounds.$2 - bounds.$1;
        expect(
          FfmpegSilenceDatasource.satisfiesMinimumInterval(
            bounds.$1,
            bounds.$2,
            0.01,
          ),
          isTrue,
          reason: '[${bounds.$1},${bounds.$2}] is exactly 10ms',
        );
        if (!FfmpegSilenceDatasource.satisfiesMinimumSilence(length, 0.01)) {
          refusalsByPosition++;
          expect(length, lessThan(0.01));
          expect(
            (length - 0.01).abs(),
            greaterThan(FfmpegSilenceDatasource.numericMarginFor(0.01)),
            reason:
                'the shortfall at [${bounds.$1},${bounds.$2}] exceeds '
                'what the minimum alone can explain',
          );
        }
      }
      expect(
        refusalsByPosition,
        2,
        reason:
            'the bound-free form refuses the two late positions and accepts '
            'the early one, for the same 10ms of silence',
      );
    });

    test('the interval margin grows with the bounds, not with the minimum', () {
      final nearZero = FfmpegSilenceDatasource.numericMarginForInterval(
        0.01,
        0.02,
        0.01,
      );
      final anHour = FfmpegSilenceDatasource.numericMarginForInterval(
        3600.01,
        3600.02,
        0.01,
      );
      expect(anHour, greaterThan(nearZero));
      // The growth is the whole point: the shortfall of the subtraction grows
      // with the magnitude the bounds were rounded at.
      expect((0.02 - 0.01) - 0.01, 0);
      expect((3600.02 - 3600.01) - 0.01, lessThan(0));
    });

    for (final min in [0.01, 0.25, 2.0, 5.0]) {
      test('an exact $min s silence is accepted one hour in', () async {
        // 0.01 -> 0.02, 0.25 -> 0.26 ... written as exact decimals so the only
        // thing under test is the position.
        final start = 3600 + min;
        final end = start + min;
        defaultLogs =
            'silence_start: $start\nsilence_end: $end | '
            'silence_duration: $min\n';
        expect(
          await detect(paramsWith(minSilence: min), totalDuration: end + 1),
          [SilenceSegment(startSeconds: start, endSeconds: end)],
          reason: 'min=$min at one hour in must not depend on the position',
        );
      });

      test('a ${min}s silence minus 5% is rejected one hour in', () async {
        final start = 3600 + min;
        final end = start + min * 0.95;
        defaultLogs = 'silence_start: $start\nsilence_end: $end\n';
        expect(
          await detect(
            paramsWith(minSilence: min),
            totalDuration: start + min + 1,
          ),
          isEmpty,
          reason: 'min=$min: 5% short is a real difference at any position',
        );
      });
    }

    test('a trailing 10ms silence an hour in is accepted', () async {
      defaultLogs = 'silence_start: 3600.01\n';
      expect(
        await detect(paramsWith(minSilence: 0.01), totalDuration: 3600.02),
        [const SilenceSegment(startSeconds: 3600.01, endSeconds: 3600.02)],
      );
    });

    test(
      'a trailing silence that survives the first pass survives the merge',
      () async {
        // Only the first pass reports anything, so the pre-union enforcement in
        // `_mergeResults` is the last gate this interval crosses. If the two
        // enforcement points disagreed, this is where the silence would vanish.
        logsByDuration = {
          '0.01': 'silence_start: 3600.01\nsilence_end: 3600.02\n',
        };
        expect(
          await detect(paramsWith(minSilence: 0.01), totalDuration: 3600.02),
          [const SilenceSegment(startSeconds: 3600.01, endSeconds: 3600.02)],
          reason: 'the second enforcement must apply the same contract',
        );
      },
    );

    test(
      'the real pipeline keeps a late boundary silence and drops a short one',
      () async {
        for (final bounds in const [(3600.01, 3600.02), (3600.01, 3600.0195)]) {
          final repository = SilenceDetectorRepositoryImpl(
            datasource: _BoundaryDatasource(bounds.$1, bounds.$2),
            vadService: _NoopVadService(),
          );
          final result = await repository.buildRemovalPlan(
            audioPath: 'audio.wav',
            params: paramsWith(minSilence: 0.01),
            timeline: MediaTimeline.probed(
              videoDurationSeconds: 3600.02,
              audioDurationSeconds: 3600.02,
            ),
          );
          final plan = (result as Success<SilenceRemovalPlan>).value;
          final accepted = (bounds.$2 - bounds.$1) >= 0.01 - 1e-12;
          expect(
            plan.removals,
            accepted
                ? [
                    SilenceSegment(
                      startSeconds: bounds.$1,
                      endSeconds: bounds.$2,
                    ),
                  ]
                : isEmpty,
            reason:
                '[${bounds.$1},${bounds.$2}] through the real repository at min=10ms',
          );
        }
      },
    );
  });

  group('SR06-R2 the trailing silence has no separate minimum', () {
    // A 20ms trailing silence used to be dropped because the parser required
    // 50ms before closing an unterminated silence_start, even though 20ms is
    // longer than the 10ms minimum the feature advertises.
    for (final durationMs in [10, 20, 49, 50, 51, 60, 500, 1500]) {
      test(
        'a ${durationMs}ms trailing silence is accepted at min=10ms',
        () async {
          final total = 1.0 + durationMs / 1000;
          defaultLogs = trailingLog(1);
          expect(
            await detect(paramsWith(minSilence: 0.01), totalDuration: total),
            [SilenceSegment(startSeconds: 1, endSeconds: total)],
            reason: '${durationMs}ms clears the 10ms minimum and must survive',
          );
        },
      );
    }

    for (final durationMs in [10, 20, 49, 50, 51, 60]) {
      test(
        'a ${durationMs}ms trailing silence is rejected at min=100ms',
        () async {
          final total = 1.0 + durationMs / 1000;
          defaultLogs = trailingLog(1);
          expect(
            await detect(paramsWith(minSilence: 0.1), totalDuration: total),
            isEmpty,
            reason: '${durationMs}ms is below the 100ms minimum',
          );
        },
      );
    }

    test('a trailing silence longer than the minimum survives', () async {
      defaultLogs = trailingLog(17);
      expect(await detect(paramsWith(minSilence: 2), totalDuration: 20), [
        const SilenceSegment(startSeconds: 17, endSeconds: 20),
      ]);
    });

    test(
      'a trailing silence shorter than the minimum is still rejected',
      () async {
        defaultLogs = trailingLog(18.5);
        // 18.5 -> 20 is 1.5s, under the 2s minimum.
        expect(
          await detect(paramsWith(minSilence: 2), totalDuration: 20),
          isEmpty,
        );
      },
    );

    test('a zero-length trailing range is never synthesized', () async {
      defaultLogs = trailingLog(5);
      // The window ends exactly where the silence began.
      expect(
        await detect(paramsWith(minSilence: 0.01), totalDuration: 5),
        isEmpty,
      );
    });

    test(
      'a trailing range ending before its start is never synthesized',
      () async {
        defaultLogs = trailingLog(5);
        expect(
          await detect(paramsWith(minSilence: 0.01), totalDuration: 2),
          isEmpty,
        );
      },
    );

    test('a non-finite window end is never used as a bound', () async {
      defaultLogs = trailingLog(5);
      expect(
        await detect(paramsWith(minSilence: 0.01), totalDuration: double.nan),
        isEmpty,
      );
    });

    test('a non-finite silence start is never used as a bound', () async {
      // A NaN bound must not fall back to 0, which would invent a full-length
      // silence covering the whole timeline.
      defaultLogs = trailingLog(double.nan);
      expect(
        await detect(paramsWith(minSilence: 0.01), totalDuration: 20),
        isEmpty,
      );
    });

    test('a negative silence start is never used as a bound', () async {
      defaultLogs = trailingLog(-5);
      expect(
        await detect(paramsWith(minSilence: 0.01), totalDuration: 20),
        isEmpty,
      );
    });

    test(
      'a completed silence_end still wins over the trailing branch',
      () async {
        logsByDuration = {
          '2.0': logFor(const [(1, 3)]),
        };
        expect(await detect(paramsWith(minSilence: 2), totalDuration: 20), [
          const SilenceSegment(startSeconds: 1, endSeconds: 3),
        ]);
      },
    );
  });

  group('the other pipeline contracts are unchanged', () {
    test(
      'a positive gap between two accepted silences is still kept',
      () async {
        logsByDuration = {
          '2.0': logFor(const [(1, 3), (3.01, 5.01)]),
        };
        final result = await detect(paramsWith(minSilence: 2));

        expect(result.length, 2);
        expect(result[0].endSeconds, lessThan(result[1].startSeconds));
        // 10ms apart at 16kHz is 160 samples: never absorbed.
        expect(
          result[1].startSeconds - result[0].endSeconds,
          closeTo(0.01, 1e-9),
        );
      },
    );

    test('overlapping and touching silences are still unioned', () async {
      logsByDuration = {
        '2.0': logFor(const [(1, 4), (2, 5)]),
      };
      expect(await detect(paramsWith(minSilence: 2)), [
        const SilenceSegment(startSeconds: 1, endSeconds: 5),
      ]);

      logsByDuration = {
        '2.0': logFor(const [(1, 3), (3, 5)]),
      };
      expect(await detect(paramsWith(minSilence: 2)), [
        const SilenceSegment(startSeconds: 1, endSeconds: 5),
      ]);
    });

    test('guards shrink an accepted silence below the minimum and it is still '
        'removed', () async {
      // The minimum is a detection limit on raw silences, not a floor on the
      // final removal: a 2s raw silence at min=2s is accepted, 0.75s guards
      // shrink it to 0.5s, and that shorter range must still be cut. Dropping
      // it would be the opposite error.
      final params = paramsWith(
        minSilence: 2,
        guardBefore: 0.75,
        guardAfter: 0.75,
      );
      final repository = SilenceDetectorRepositoryImpl(
        datasource: const _StubDatasource([
          SilenceSegment(startSeconds: 1, endSeconds: 3),
        ]),
        vadService: _NoopVadService(),
      );

      final result = await repository.buildRemovalPlan(
        audioPath: 'audio.wav',
        params: params,
        timeline: MediaTimeline.probed(
          videoDurationSeconds: 20,
          audioDurationSeconds: 20,
        ),
      );
      final plan = (result as Success<SilenceRemovalPlan>).value;

      expect(plan.removals.length, 1);
      expect(plan.removals.single.startSeconds, closeTo(1.75, 1e-9));
      expect(plan.removals.single.endSeconds, closeTo(2.25, 1e-9));
      expect(plan.removedSeconds, closeTo(0.5, 1e-9));
      expect(
        plan.removedSeconds,
        lessThan(2),
        reason:
            'the protected removal is shorter than the minimum, which is '
            'correct: guards may shrink an accepted silence',
      );
      expect(plan.removedSeconds + plan.keptSeconds, closeTo(20, 1e-9));
    });

    test(
      'a raw silence below the minimum produces no removal at all',
      () async {
        final repository = SilenceDetectorRepositoryImpl(
          datasource: const _StubDatasource([
            SilenceSegment(startSeconds: 1, endSeconds: 1.4),
          ]),
          vadService: _NoopVadService(),
        );

        final result = await repository.buildRemovalPlan(
          audioPath: 'audio.wav',
          params: paramsWith(minSilence: 2),
          timeline: MediaTimeline.probed(
            videoDurationSeconds: 20,
            audioDurationSeconds: 20,
          ),
        );
        final plan = (result as Success<SilenceRemovalPlan>).value;

        expect(plan.removals, isEmpty);
        expect(plan.removedSeconds, 0);
        expect(plan.kept, [
          const SilenceSegment(startSeconds: 0, endSeconds: 20),
        ]);
      },
    );
  });
}

/// A datasource stub for the pipeline-level cases, which need no channel. It
/// applies the same documented minimum the real datasource applies, so the stub
/// cannot make a rejected silence look accepted.
class _StubDatasource implements FfmpegSilenceDatasource {
  final List<SilenceSegment> segments;

  const _StubDatasource(this.segments);

  @override
  Future<List<SilenceSegment>> detectSilence({
    required String audioPath,
    required DetectionParams params,
    double? totalDuration,
  }) async {
    return segments
        .where(
          (s) => FfmpegSilenceDatasource.satisfiesMinimumSilence(
            s.durationSeconds,
            params.minSilenceDuration,
          ),
        )
        .toList();
  }
}

/// A stub carrying exactly one interval, filtered through the bound-aware
/// contract the real datasource uses. `totalDuration` comes from the probed
/// timeline, exactly as it does in the real pipeline.
class _BoundaryDatasource implements FfmpegSilenceDatasource {
  final double start;
  final double end;

  const _BoundaryDatasource(this.start, this.end);

  @override
  Future<List<SilenceSegment>> detectSilence({
    required String audioPath,
    required DetectionParams params,
    double? totalDuration,
  }) async {
    final segment = SilenceSegment(startSeconds: start, endSeconds: end);
    if (!segment.isValid) return const [];
    if (!FfmpegSilenceDatasource.satisfiesMinimumInterval(
      start,
      end,
      params.minSilenceDuration,
    )) {
      return const [];
    }
    return [segment];
  }
}

class _NoopVadService implements VadService {
  @override
  Future<List<SilenceSegment>> refineSilence(
    String audioPath,
    List<SilenceSegment> silenceSegments,
    DetectionParams params,
  ) async {
    return silenceSegments;
  }
}
