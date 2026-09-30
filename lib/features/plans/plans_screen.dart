import 'package:flutter/material.dart';

import '../../widgets/common.dart';

// Placeholder until plans and workout logging land in phase 2.
class PlansScreen extends StatelessWidget {
  const PlansScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Plans')),
      body: const EmptyState(
        icon: Icons.calendar_month_rounded,
        title: 'Plans are on the way',
        message:
            'Weekly and rotating plans with target sets, reps, weight and '
            'time arrive in the next build.',
      ),
    );
  }
}
