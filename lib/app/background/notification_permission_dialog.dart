// The in-app notification-permission rationale (ADR-0007).
//
// A LAN companion asking for a persistent notification is not self-explanatory,
// so the OS prompt is always preceded by this short explanation. It is UI only:
// the decision of *whether* the rationale is due lives in the reducer; both the
// shell (automatic, at the first successful connect) and the Settings "Notification
// access" row (manual re-ask) show this same dialog.

import 'package:flutter/material.dart';

/// Shows the rationale and returns `true` when the user accepts. A dismissal
/// (barrier / back / "Not now") returns `false`, so the OS prompt is never
/// fired without an explicit accept.
Future<bool> showNotificationPermissionRationale(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Allow notifications'),
      content: const Text(
        'Harbor Companion keeps your connection to the PC alive with a '
        'persistent notification, so you can control playback with the screen '
        'off. Android needs notification access for that. Without it the '
        'connection still works — the controls just stay inside the app.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Allow'),
        ),
      ],
    ),
  );
  return accepted ?? false;
}
