import 'package:flutter_test/flutter_test.dart';
import 'package:ai_video_editing/core/services/video_download_service.dart';

void main() {
  group('isYoutubeUrl', () {
    test('detects standard watch URL', () {
      expect(VideoDownloadService.isYoutubeUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ'), isTrue);
    });

    test('detects short youtu.be URL', () {
      expect(VideoDownloadService.isYoutubeUrl('https://youtu.be/dQw4w9WgXcQ'), isTrue);
    });

    test('detects embed URL', () {
      expect(VideoDownloadService.isYoutubeUrl('https://www.youtube.com/embed/dQw4w9WgXcQ'), isTrue);
    });

    test('detects shorts URL', () {
      expect(VideoDownloadService.isYoutubeUrl('https://www.youtube.com/shorts/dQw4w9WgXcQ'), isTrue);
    });

    test('detects live URL', () {
      expect(VideoDownloadService.isYoutubeUrl('https://www.youtube.com/live/dQw4w9WgXcQ'), isTrue);
    });

    test('detects watch URL with extra params', () {
      expect(VideoDownloadService.isYoutubeUrl('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=120s&list=PL123'), isTrue);
    });

    test('rejects non-YouTube URL', () {
      expect(VideoDownloadService.isYoutubeUrl('https://vimeo.com/123456'), isFalse);
    });

    test('rejects empty string', () {
      expect(VideoDownloadService.isYoutubeUrl(''), isFalse);
    });

    test('rejects null-like input', () {
      expect(VideoDownloadService.isYoutubeUrl('not a url'), isFalse);
    });
  });

  group('isUrl', () {
    test('detects http URL', () {
      expect(VideoDownloadService.isUrl('http://example.com/video.mp4'), isTrue);
    });

    test('detects https URL', () {
      expect(VideoDownloadService.isUrl('https://example.com/video.mp4'), isTrue);
    });

    test('rejects file path', () {
      expect(VideoDownloadService.isUrl('/home/user/video.mp4'), isFalse);
    });

    test('rejects relative path', () {
      expect(VideoDownloadService.isUrl('video.mp4'), isFalse);
    });
  });

  group('getAvailableQualities', () {
    test('throws on invalid YouTube URL', () {
      expect(
        () => VideoDownloadService.getAvailableQualities('not a url'),
        throwsA(predicate((e) => e is Exception && e.toString().contains('Could not parse YouTube video ID'))),
      );
    });
  });

  group('downloadAndMergeYoutube', () {
    test('throws on invalid YouTube URL', () {
      expect(
        () => VideoDownloadService.downloadAndMergeYoutube(
          'not a url',
          const YoutubeQualityOption(label: 'test', width: 640, height: 480, isMuxed: true),
          'test',
        ),
        throwsA(predicate((e) => e is Exception && e.toString().contains('Invalid YouTube URL'))),
      );
    });
  });

  group('CancelledDownloadException', () {
    test('has correct toString', () {
      final exc = CancelledDownloadException();
      expect(exc.toString(), 'Download cancelled by user');
    });
  });

  group('DownloadProgress', () {
    test('creates with all fields', () {
      final dp = DownloadProgress(progress: 0.5, receivedBytes: 100, totalBytes: 200, speedBytesPerSec: 1024, statusText: 'Downloading...');
      expect(dp.progress, 0.5);
      expect(dp.receivedBytes, 100);
      expect(dp.totalBytes, 200);
      expect(dp.speedBytesPerSec, 1024);
      expect(dp.statusText, 'Downloading...');
    });

    test('creates with zero values', () {
      final dp = const DownloadProgress(progress: 0, receivedBytes: 0, totalBytes: 0, speedBytesPerSec: 0, statusText: '');
      expect(dp.progress, 0);
      expect(dp.receivedBytes, 0);
      expect(dp.totalBytes, 0);
      expect(dp.speedBytesPerSec, 0);
      expect(dp.statusText, '');
    });
  });

}
