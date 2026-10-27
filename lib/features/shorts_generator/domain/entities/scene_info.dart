class SceneInfo {
  final int index;
  final double startSeconds;
  final double endSeconds;
  final String thumbnailPath;

  const SceneInfo({
    required this.index,
    required this.startSeconds,
    required this.endSeconds,
    required this.thumbnailPath,
  });

  double get durationSeconds => endSeconds - startSeconds;
}
