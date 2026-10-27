import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../../../core/theme/app_colors.dart';

class VideoPreviewWidget extends StatelessWidget {
  final VideoPlayerController? controller;
  final String? previewPath;
  final bool isLoading;
  final bool showOriginal;
  final String videoPath;

  const VideoPreviewWidget({
    super.key,
    this.controller,
    this.previewPath,
    this.isLoading = false,
    this.showOriginal = false,
    required this.videoPath,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 260,
      width: double.infinity,
      color: Colors.black,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final containerW = constraints.maxWidth;
          final containerH = constraints.maxHeight;
          double videoW = containerW;
          double videoH = containerH;
          if (controller != null && controller!.value.isInitialized) {
            final aspectRatio = controller!.value.aspectRatio;
            final containerRatio = containerW / containerH;
            if (containerRatio > aspectRatio) {
              videoH = containerH;
              videoW = videoH * aspectRatio;
            } else {
              videoW = containerW;
              videoH = videoW / aspectRatio;
            }
          }
          final left = (containerW - videoW) / 2;
          final top = (containerH - videoH) / 2;

          return Stack(
            children: [
              if (controller != null && controller!.value.isInitialized)
                Positioned(
                  left: left, top: top, width: videoW, height: videoH,
                  child: ClipRect(child: VideoPlayer(controller!)),
                )
              else
                _buildPlaceholder(),
              if (!showOriginal && previewPath != null)
                Positioned(
                  left: left, top: top, width: videoW, height: videoH,
                  child: ClipRect(
                    child: Image.file(
                      File(previewPath!),
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              if (!showOriginal && previewPath == null && controller != null && controller!.value.isInitialized)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: const Text('Adjust & release slider to preview', style: TextStyle(color: Colors.white60, fontSize: 12)),
                  ),
                ),
              if (isLoading && previewPath == null)
                Container(
                  color: Colors.black45,
                  child: const Center(child: CircularProgressIndicator(color: AppColors.primary)),
                ),
              if (showOriginal)
                Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(8)),
                    child: const Text('ORIGINAL', style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 2)),
                  ),
                ),
              Positioned(
                bottom: 8, right: 8,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                  child: Text(
                    showOriginal ? 'Source' : (previewPath != null ? 'Adjusted' : 'No preview'),
                    style: const TextStyle(color: Colors.white60, fontSize: 11),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.movie, size: 48, color: Colors.grey[700]),
          const SizedBox(height: 8),
          Text('Loading video...', style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        ],
      ),
    );
  }
}
