import 'package:flutter/material.dart';
import '../../features/splash/presentation/splash_screen.dart';
import '../../features/video_import/presentation/home_screen.dart';
import '../../features/silence_detector/presentation/editor_screen.dart';
import '../../features/video_processing/presentation/processing_screen.dart';
import '../../features/preview/presentation/preview_screen.dart';
import '../../features/export/presentation/export_screen.dart';
import '../../features/video_adjustment/presentation/screens/adjustment_screen.dart';
import '../../features/shorts_generator/presentation/screens/import_mode_screen.dart';
import '../../features/shorts_generator/presentation/screens/suggestions_screen.dart';
import '../../features/shorts_generator/presentation/screens/export_screen.dart';
import '../../features/video_enhancement/presentation/screens/enhancement_home_screen.dart';
import '../../features/audio_enhancement/presentation/screens/audio_enhancement_screen.dart';
import '../../features/media_cutter/presentation/screens/audio_editor_screen.dart';
import '../../features/media_cutter/presentation/screens/media_cutter_screen.dart';

class AppRouter {
  AppRouter._();

  static const String splash = '/';
  static const String home = '/home';
  static const String editor = '/editor';
  static const String processing = '/processing';
  static const String preview = '/preview';
  static const String adjustments = '/adjustments';
  static const String export = '/export';
  static const String shorts = '/shorts';
  static const String shortsSuggestions = '/shorts/suggestions';
  static const String shortsExport = '/shorts/export';
  static const String enhancement = '/enhancement';
  static const String audioEnhance = '/audio-enhance';
  static const String mediaCutter = '/media-cutter';

  static Route<dynamic> generateRoute(RouteSettings settings) {
    switch (settings.name) {
      case splash:
        return MaterialPageRoute(builder: (_) => const SplashScreen());
      case home:
        return MaterialPageRoute(builder: (_) => const HomeScreen());
      case editor:
        final videoPath = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => EditorScreen(videoPath: videoPath),
        );
      case processing:
        return MaterialPageRoute(builder: (_) => const ProcessingScreen());
      case preview:
        final args = settings.arguments as Map<String, dynamic>;
        return MaterialPageRoute(
          builder: (_) => PreviewScreen(
            originalPath: args['originalPath'] as String,
            processedPath: args['processedPath'] as String,
            removedDuration: args['removedDuration'] as Duration,
            originalDuration: args['originalDuration'] as Duration,
          ),
        );
      case adjustments:
        final videoPath = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => AdjustmentScreen(videoPath: videoPath),
        );
      case export:
        final videoPath = settings.arguments is Map<String, dynamic>
            ? (settings.arguments as Map<String, dynamic>)['videoPath']
                  as String?
            : null;
        return MaterialPageRoute(
          builder: (_) => ExportScreen(videoPath: videoPath),
        );
      case shorts:
        final path = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => ImportModeScreen(videoPath: path),
        );
      case shortsSuggestions:
        return MaterialPageRoute(builder: (_) => const SuggestionsScreen());
      case shortsExport:
        return MaterialPageRoute(builder: (_) => const ShortsExportScreen());
      case enhancement:
        final videoPath = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => EnhancementHomeScreen(videoPath: videoPath),
        );
      case audioEnhance:
        final audioPath = settings.arguments as String;
        return MaterialPageRoute(
          builder: (_) => AudioEnhancementScreen(audioPath: audioPath),
        );
      case mediaCutter:
        final args = settings.arguments as Map<String, dynamic>;
        final isAudio = args['isAudio'] as bool? ?? false;
        if (isAudio) {
          return MaterialPageRoute(
            builder: (_) => AudioEditorScreen(
              audioPath: args['mediaPath'] as String,
              duration: args['duration'] as Duration?,
            ),
          );
        }
        return MaterialPageRoute(
          builder: (_) => MediaCutterScreen(
            mediaPath: args['mediaPath'] as String,
            isAudio: false,
            hasAudio: args['hasAudio'] as bool? ?? true,
            duration: args['duration'] as Duration?,
          ),
        );
      default:
        return MaterialPageRoute(
          builder: (_) => Scaffold(
            body: Center(child: Text('No route defined for ${settings.name}')),
          ),
        );
    }
  }
}
