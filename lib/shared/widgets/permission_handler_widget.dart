import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../core/theme/app_colors.dart';

class PermissionHandlerWidget extends StatelessWidget {
  final Widget child;
  final List<Permission> permissions;
  final Widget? deniedWidget;

  const PermissionHandlerWidget({
    super.key,
    required this.child,
    required this.permissions,
    this.deniedWidget,
  });

  Future<bool> _checkPermissions() async {
    for (final permission in permissions) {
      if (!await permission.isGranted) {
        final result = await permission.request();
        if (!result.isGranted) return false;
      }
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _checkPermissions(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.data == true) {
          return child;
        }
        return deniedWidget ??
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.no_accounts,
                    size: 64,
                    color: AppColors.textTertiary,
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Permissions required to access files',
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () async {
                      await openAppSettings();
                    },
                    child: const Text('Open Settings'),
                  ),
                ],
              ),
            );
      },
    );
  }
}
