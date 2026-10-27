import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/features/video_import/data/repositories/video_import_repository_impl.dart';

void main() {
  group('Video import metadata', () {
    test('parses FFprobe duration seconds as real milliseconds', () {
      final duration = VideoImportRepositoryImpl.parseFfprobeDuration(
        '123.456',
      );

      expect(duration.inMilliseconds, 123456);
      expect(duration.inSeconds, 123);
    });
  });
}
