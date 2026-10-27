import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/file_utils.dart';
import '../../domain/entities/video_file.dart';

class VideoInfoCard extends StatelessWidget {
  final VideoFile video;

  const VideoInfoCard({super.key, required this.video});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.movie, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    video.fileName,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _infoRow(
              Icons.timer,
              'Duration',
              FileUtils.formatDuration(video.duration),
            ),
            if (video.width > 0 && video.height > 0) ...[
              const SizedBox(height: 8),
              _infoRow(
                Icons.aspect_ratio,
                'Resolution',
                '${video.width}x${video.height}',
              ),
            ],
            const SizedBox(height: 8),
            _infoRow(
              Icons.storage,
              'File Size',
              FileUtils.formatFileSize(video.fileSize),
            ),
            if (video.fps > 0) ...[
              const SizedBox(height: 8),
              _infoRow(Icons.speed, 'FPS', video.fps.toStringAsFixed(1)),
            ],
            const SizedBox(height: 8),
            _infoRow(
              Icons.audiotrack,
              'Audio',
              video.hasAudio ? 'Present' : 'None',
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.textTertiary),
        const SizedBox(width: 8),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}
