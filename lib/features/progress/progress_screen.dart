import 'package:flutter/material.dart';

import '../../widgets/common.dart';

// Placeholder until measurements and charts land in phase 3.
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Progress')),
      body: const EmptyState(
        icon: Icons.insights_rounded,
        title: 'Charts are on the way',
        message:
            'Body measurements, strength trends and your training '
            'calendar arrive in a later build.',
      ),
    );
  }
}
