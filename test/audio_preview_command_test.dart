import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/features/audio_enhancement/data/services/audio_preview_command_builder.dart';

void main() {
  group('Audio preview command builder', () {
    test('builds original preview as playable m4a without filters', () {
      final command = AudioPreviewCommandBuilder.buildOriginalPreviewCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/original_preview.m4a',
        seconds: 12,
      );

      expect(command, contains('-i "C:/clips/source.mp3"'));
      expect(command, contains('-t 12.000'));
      expect(command, contains('-map 0:a:0'));
      expect(command, contains('-vn'));
      expect(command, contains('-ac 2'));
      expect(command, contains('-ar 48000'));
      expect(command, contains('-c:a aac'));
      expect(command, contains('-movflags +faststart'));
      expect(command, isNot(contains('-af')));
    });

    test('builds enhanced preview with filters and playable m4a output', () {
      final command = AudioPreviewCommandBuilder.buildEnhancedPreviewCommand(
        inputPath: 'C:/clips/source.mp3',
        outputPath: 'C:/clips/enhanced_preview.m4a',
        audioFilter: 'highpass=f=80',
        seconds: 12,
      );

      expect(command, contains('-af "highpass=f=80"'));
      expect(command, contains('-map 0:a:0'));
      expect(command, contains('-ac 2'));
      expect(command, contains('-ar 48000'));
      expect(command, contains('-c:a aac'));
      expect(command, contains('-b:a 256k'));
      expect(command, contains('-movflags +faststart'));
    });
  });
}
