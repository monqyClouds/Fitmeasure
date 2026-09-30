import 'package:flutter/material.dart';

/// Training goal for a period of time. Each type suggests default targets
/// when adding exercises to a plan, and gets its own colour on charts.
enum CycleType {
  bulk(
    label: 'Bulk',
    tagline: 'Build size with moderate reps and a calorie surplus',
    icon: Icons.trending_up_rounded,
    color: Color(0xFFFFB547),
    sets: 4,
    reps: 10,
    repRange: '8–12',
    restSec: 90,
  ),
  cut(
    label: 'Cut',
    tagline: 'Keep strength while losing fat with higher reps',
    icon: Icons.content_cut_rounded,
    color: Color(0xFF3DD6C6),
    sets: 3,
    reps: 12,
    repRange: '10–15',
    restSec: 60,
  ),
  strength(
    label: 'Strength',
    tagline: 'Heavy weights, low reps, long rests',
    icon: Icons.fitness_center_rounded,
    color: Color(0xFFFF6B5E),
    sets: 5,
    reps: 5,
    repRange: '3–5',
    restSec: 180,
  ),
  endurance(
    label: 'Endurance',
    tagline: 'Light loads, high reps and short rests',
    icon: Icons.bolt_rounded,
    color: Color(0xFF5AA9FF),
    sets: 3,
    reps: 15,
    repRange: '15–20',
    restSec: 45,
  ),
  routine(
    label: 'Routine',
    tagline: 'Ongoing training without a fixed goal or end date',
    icon: Icons.all_inclusive_rounded,
    color: Color(0xFFA99BFF),
    sets: 3,
    reps: 10,
    repRange: '8–12',
    restSec: 90,
  );

  const CycleType({
    required this.label,
    required this.tagline,
    required this.icon,
    required this.color,
    required this.sets,
    required this.reps,
    required this.repRange,
    required this.restSec,
  });

  final String label;
  final String tagline;
  final IconData icon;
  final Color color;

  /// Suggested defaults for a new plan item during this cycle.
  final int sets;
  final int reps;
  final String repRange;
  final int restSec;

  /// Suggested length in weeks; null means open-ended.
  int? get defaultWeeks => switch (this) {
    CycleType.bulk => 12,
    CycleType.cut => 8,
    CycleType.strength => 8,
    CycleType.endurance => 6,
    CycleType.routine => null,
  };
}

enum MuscleGroup {
  chest('Chest', Color(0xFFFF7A59)),
  back('Back', Color(0xFF5AA9FF)),
  shoulders('Shoulders', Color(0xFFFFB547)),
  biceps('Biceps', Color(0xFFB8F34A)),
  triceps('Triceps', Color(0xFF3DD6C6)),
  forearms('Forearms', Color(0xFF8FD694)),
  legs('Legs', Color(0xFFA99BFF)),
  glutes('Glutes', Color(0xFFFF6B9A)),
  core('Core', Color(0xFFFFD166)),
  cardio('Cardio', Color(0xFFFF6B5E)),
  fullBody('Full body', Color(0xFF9AA0AB));

  const MuscleGroup(this.label, this.color);
  final String label;
  final Color color;
}

enum Equipment {
  barbell('Barbell'),
  dumbbell('Dumbbell'),
  machine('Machine'),
  cable('Cable'),
  bodyweight('Bodyweight'),
  kettlebell('Kettlebell'),
  band('Band'),
  other('Other');

  const Equipment(this.label);
  final String label;
}

/// What gets logged for each set of an exercise.
enum TrackingType {
  reps('Reps & weight', Icons.repeat_rounded),
  time('Time', Icons.timer_outlined),
  distance('Distance & time', Icons.route_rounded);

  const TrackingType(this.label, this.icon);
  final String label;
  final IconData icon;
}

enum MediaKind { image, video, link }

/// Weekly plans map days to weekdays; rotation plans cycle Day 1, Day 2, …
/// regardless of the calendar.
enum PlanSchedule { weekly, rotation }
