import 'reframe_settings.dart';
import 'video_segment.dart';

class ClipSuggestion {
  final VideoSegment segment;
  final double score;
  final String label;
  bool selected;
  ReframeMode? reframeMode;

  ClipSuggestion({
    required this.segment,
    required this.score,
    required this.label,
    this.selected = true,
    this.reframeMode,
  });

  double get startSeconds => segment.startSeconds;
  double get endSeconds => segment.endSeconds;
  double get durationSeconds => segment.durationSeconds;
}
