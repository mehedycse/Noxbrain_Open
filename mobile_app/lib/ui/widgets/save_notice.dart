import 'package:flutter/material.dart';

import '../theme.dart';

/// Result of a save or command: a floating bar that stays 5 s, with a green
/// tick when it worked and a red mark when it did not.
void showSaveNotice(
  BuildContext context,
  String message, {
  bool success = true,
}) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 5),
      backgroundColor: SolarTheme.surfaceLight,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: success
              ? SolarTheme.batteryGreen
              : SolarTheme.batteryDischarging,
        ),
      ),
      content: Row(
        children: [
          Icon(
            success ? Icons.check_circle_rounded : Icons.error_outline_rounded,
            color: success
                ? SolarTheme.batteryGreen
                : SolarTheme.batteryDischarging,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
                fontSize: 13,
                color: SolarTheme.textPrimary,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
