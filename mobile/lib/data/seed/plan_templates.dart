import '../../domain/enums.dart';

typedef TemplateDay = (String name, int? weekday, List<String> exercises);

/// Ready-made plans built from the built-in library (matched by name).
class PlanTemplate {
  const PlanTemplate({
    required this.name,
    required this.description,
    required this.schedule,
    required this.days,
  });

  final String name;
  final String description;
  final PlanSchedule schedule;
  final List<TemplateDay> days;
}

const planTemplates = [
  PlanTemplate(
    name: 'Push / Pull / Legs',
    description: 'Three rotating days: pressing, pulling, then legs.',
    schedule: PlanSchedule.rotation,
    days: [
      (
        'Push',
        null,
        [
          'Bench Press',
          'Overhead Press',
          'Incline Dumbbell Press',
          'Lateral Raise',
          'Tricep Pushdown',
        ],
      ),
      (
        'Pull',
        null,
        ['Deadlift', 'Pull-up', 'Barbell Row', 'Face Pull', 'Barbell Curl'],
      ),
      (
        'Legs',
        null,
        [
          'Back Squat',
          'Romanian Deadlift',
          'Leg Press',
          'Lying Leg Curl',
          'Standing Calf Raise',
        ],
      ),
    ],
  ),
  PlanTemplate(
    name: 'Upper / Lower',
    description: 'Four days a week, alternating upper and lower body.',
    schedule: PlanSchedule.weekly,
    days: [
      (
        'Upper A',
        DateTime.monday,
        [
          'Bench Press',
          'Barbell Row',
          'Overhead Press',
          'Lat Pulldown',
          'Dumbbell Curl',
          'Tricep Pushdown',
        ],
      ),
      (
        'Lower A',
        DateTime.tuesday,
        [
          'Back Squat',
          'Romanian Deadlift',
          'Leg Extension',
          'Lying Leg Curl',
          'Standing Calf Raise',
          'Plank',
        ],
      ),
      (
        'Upper B',
        DateTime.thursday,
        [
          'Incline Dumbbell Press',
          'Seated Cable Row',
          'Seated Dumbbell Press',
          'Pull-up',
          'Hammer Curl',
          'Overhead Tricep Extension',
        ],
      ),
      (
        'Lower B',
        DateTime.friday,
        [
          'Deadlift',
          'Leg Press',
          'Walking Lunge',
          'Seated Leg Curl',
          'Seated Calf Raise',
          'Hanging Leg Raise',
        ],
      ),
    ],
  ),
  PlanTemplate(
    name: 'Full body ×3',
    description: 'Monday, Wednesday and Friday, whole body each time.',
    schedule: PlanSchedule.weekly,
    days: [
      (
        'Full body A',
        DateTime.monday,
        ['Back Squat', 'Bench Press', 'Barbell Row', 'Overhead Press', 'Plank'],
      ),
      (
        'Full body B',
        DateTime.wednesday,
        [
          'Deadlift',
          'Incline Dumbbell Press',
          'Lat Pulldown',
          'Walking Lunge',
          'Face Pull',
        ],
      ),
      (
        'Full body C',
        DateTime.friday,
        [
          'Front Squat',
          'Dumbbell Bench Press',
          'Seated Cable Row',
          'Hip Thrust',
          'Hanging Leg Raise',
        ],
      ),
    ],
  ),
];
