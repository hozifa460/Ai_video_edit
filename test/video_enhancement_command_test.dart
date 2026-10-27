import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/features/video_enhancement/data/datasources/professional_enhancement_command_builder.dart';
import 'package:ai_video_editing/features/video_enhancement/domain/entities/enhancement_settings.dart';

void main() {
  group('Video enhancement command builder', () {
    test('uses real quality filters in addition to optional scaling', () {
      final command = ProfessionalEnhancementCommandBuilder()
          .buildDirectCommand(
            inputPath: 'C:/clips/source video.mp4',
            outputPath: 'C:/clips/output.mp4',
            settings: const EnhancementSettings(
              denoiseEnabled: true,
              sharpenEnabled: true,
              colorGradeEnabled: true,
              upscaleEnabled: true,
              audioEnhanceEnabled: true,
              targetWidth: 1920,
              targetHeight: 1080,
            ),
          );

      expect(command, isNot(startsWith('ffmpeg ')));
      expect(command, contains('hqdn3d='));
      expect(command, contains('deblock=filter=strong'));
      expect(command, contains('curves='));
      expect(command, contains('eq=saturation='));
      expect(command, contains('unsharp='));
      expect(command, contains('deband='));
      expect(command, contains('scale=1920:1080'));
      expect(command, contains('pad=1920:1080'));
      expect(command, contains('-map 0:v:0'));
      expect(command, contains('-map 0:a?'));
    });
  });
}
