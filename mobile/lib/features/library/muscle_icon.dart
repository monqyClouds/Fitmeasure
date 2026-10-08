import 'package:flutter/material.dart';

import '../../domain/enums.dart';

IconData muscleIconData(MuscleGroup m) => switch (m) {
  MuscleGroup.chest => Icons.shield_outlined,
  MuscleGroup.back => Icons.airline_seat_flat_outlined,
  MuscleGroup.shoulders => Icons.accessibility_new_rounded,
  MuscleGroup.biceps => Icons.fitness_center_rounded,
  MuscleGroup.triceps => Icons.change_history_rounded,
  MuscleGroup.forearms => Icons.back_hand_outlined,
  MuscleGroup.legs => Icons.directions_walk_rounded,
  MuscleGroup.glutes => Icons.airline_seat_recline_normal_rounded,
  MuscleGroup.core => Icons.grid_view_rounded,
  MuscleGroup.cardio => Icons.favorite_border_rounded,
  MuscleGroup.fullBody => Icons.sports_gymnastics_rounded,
};

/// A tinted rounded square showing the muscle group's icon and colour.
class MuscleIcon extends StatelessWidget {
  const MuscleIcon({super.key, required this.muscle, this.size = 44});
  final MuscleGroup muscle;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: muscle.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.32),
      ),
      child: Icon(
        muscleIconData(muscle),
        color: muscle.color,
        size: size * 0.5,
      ),
    );
  }
}
