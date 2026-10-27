import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/features/media_cutter/data/services/professional_audio_editor_service.dart';

void main() {
  group('Professional audio editor service', () {
    test('accepts the requested audio formats', () {
      expect(
        ProfessionalAudioEditorService.isSupportedAudioPath('a.mp3'),
        true,
      );
      expect(
        ProfessionalAudioEditorService.isSupportedAudioPath('a.wav'),
        true,
      );
      expect(
        ProfessionalAudioEditorService.isSupportedAudioPath('a.aac'),
        true,
      );
      expect(
        ProfessionalAudioEditorService.isSupportedAudioPath('a.m4a'),
        true,
      );
      expect(
        ProfessionalAudioEditorService.isSupportedAudioPath('a.mp4'),
        false,
      );
    });

    test('builds lossless trim command with stream copy', () {
      final command = ProfessionalAudioEditorService.buildTrimCommand(
        inputPath: 'C:/audio/source.mp3',
        outputPath: 'C:/audio/trimmed.mp3',
        startSeconds: 1.5,
        endSeconds: 7,
      );

      expect(command, contains('-ss 1.500'));
      expect(command, contains('-t 5.500'));
      expect(command, contains('-map 0:a:0'));
      expect(command, contains('-c copy'));
    });

    test('builds middle delete command with atrim concat', () {
      final command = ProfessionalAudioEditorService.buildDeleteRangeCommand(
        inputPath: 'C:/audio/source.m4a',
        outputPath: 'C:/audio/deleted.m4a',
        deleteStartSeconds: 3,
        deleteEndSeconds: 5,
        totalDurationSeconds: 12,
      );

      expect(command, contains('atrim=start=0.000:end=3.000'));
      expect(command, contains('atrim=start=5.000:end=12.000'));
      expect(command, contains('concat=n=2:v=0:a=1[outa]'));
      expect(command, contains('-c:a aac'));
    });

    test('parses silence logs and proposes smart cut centers', () {
      const logs = '''
      [silencedetect @ 0] silence_start: 2.000
      [silencedetect @ 0] silence_end: 3.000 | silence_duration: 1.000
      [silencedetect @ 0] silence_start: 8.000
      [silencedetect @ 0] silence_end: 9.000 | silence_duration: 1.000
      ''';

      final regions = ProfessionalAudioEditorService.parseSilenceRegions(logs);
      final cuts = ProfessionalAudioEditorService.smartCutPointsFromSilence(
        regions,
      );

      expect(regions, hasLength(2));
      expect(cuts, [2.5, 8.5]);
    });
  });
}
