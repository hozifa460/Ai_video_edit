import 'dart:io';
import 'package:flutter/material.dart';
import '../../../../core/theme/app_colors.dart';

class SplitComparisonWidget extends StatefulWidget {
  final String originalPath;
  final String enhancedPath;

  const SplitComparisonWidget({
    super.key,
    required this.originalPath,
    required this.enhancedPath,
  });

  @override
  State<SplitComparisonWidget> createState() => _SplitComparisonWidgetState();
}

class _SplitComparisonWidgetState extends State<SplitComparisonWidget> {
  double _sliderPosition = 0.5;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onHorizontalDragUpdate: (details) {
            setState(() {
              _sliderPosition = (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0);
            });
          },
          child: Stack(
            children: [
              Positioned.fill(
                child: Image.file(
                  File(widget.enhancedPath),
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) => const Center(
                    child: Text('Failed to load enhanced image'),
                  ),
                ),
              ),
              Positioned.fill(
                child: ClipRect(
                  clipper: _SliderClipper(_sliderPosition),
                  child: Image.file(
                    File(widget.originalPath),
                    fit: BoxFit.contain,
                    errorBuilder: (context, error, stack) => const Center(
                      child: Text('Failed to load original image'),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: constraints.maxWidth * _sliderPosition - 20,
                top: 0,
                bottom: 0,
                child: SizedBox(
                  width: 40,
                  child: Column(
                    children: [
                      Expanded(
                        child: Container(
                          width: 3,
                          color: Colors.white,
                        ),
                      ),
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.compare_arrows,
                          color: AppColors.primary,
                          size: 24,
                        ),
                      ),
                      Expanded(
                        child: Container(
                          width: 3,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 16,
                top: 16,
                child: _buildLabel('BEFORE', 0.0),
              ),
              Positioned(
                right: 16,
                top: 16,
                child: _buildLabel('AFTER', _sliderPosition),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildLabel(String text, double position) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SliderClipper extends CustomClipper<Rect> {
  final double position;

  _SliderClipper(this.position);

  @override
  Rect getClip(Size size) {
    return Rect.fromLTRB(0, 0, size.width * position, size.height);
  }

  @override
  bool shouldReclip(covariant _SliderClipper oldClipper) {
    return oldClipper.position != position;
  }
}