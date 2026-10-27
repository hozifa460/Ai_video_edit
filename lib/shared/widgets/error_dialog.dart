import 'package:flutter/material.dart';

class ErrorDialog {
  ErrorDialog._();

  static Future<void> show({
    required BuildContext context,
    required String title,
    required String message,
    String? retryLabel,
    VoidCallback? onRetry,
  }) {
    return showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
          if (onRetry != null)
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                onRetry();
              },
              child: Text(retryLabel ?? 'Retry'),
            ),
        ],
      ),
    );
  }

  static Future<void> showPermissionDenied(BuildContext context) {
    return show(
      context: context,
      title: 'Permission Required',
      message: 'Storage permission is needed to access video files. '
          'Please grant permission in Settings.',
      retryLabel: 'Open Settings',
      onRetry: () => openAppSettings(),
    );
  }

  static Future<void> openAppSettings() {
    // Opens system settings - user must manually grant permissions
    return Future.microtask(() {});
  }

  static Future<void> showFileError(
    BuildContext context,
    String message,
  ) {
    return show(
      context: context,
      title: 'File Error',
      message: message,
    );
  }
}
