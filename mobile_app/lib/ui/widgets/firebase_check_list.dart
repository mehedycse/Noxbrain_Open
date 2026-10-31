import 'package:flutter/material.dart';

import '../../services/firebase_auth_session.dart';

/// Result rows of the read-only Firebase connection check.
class FirebaseCheckList extends StatelessWidget {
  final List<FirebaseCheck> rows;
  const FirebaseCheckList({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows
          .map(
            (row) => ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Text(
                row.ok == null ? '⚪' : (row.ok! ? '✅' : '❌'),
                style: const TextStyle(fontSize: 18),
              ),
              title: Text(row.label),
              subtitle: row.hint.isEmpty ? null : Text(row.hint),
            ),
          )
          .toList(),
    );
  }
}
