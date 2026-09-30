import '../../domain/enums.dart';

typedef SeedExercise = (String name, MuscleGroup, Equipment, TrackingType);

const _r = TrackingType.reps;

/// The built-in exercise library, inserted when the database is created.
const List<SeedExercise> seedExercises = [
  // Chest
  ('Bench Press', MuscleGroup.chest, Equipment.barbell, _r),
  ('Incline Bench Press', MuscleGroup.chest, Equipment.barbell, _r),
  ('Decline Bench Press', MuscleGroup.chest, Equipment.barbell, _r),
  ('Dumbbell Bench Press', MuscleGroup.chest, Equipment.dumbbell, _r),
  ('Incline Dumbbell Press', MuscleGroup.chest, Equipment.dumbbell, _r),
  ('Dumbbell Fly', MuscleGroup.chest, Equipment.dumbbell, _r),
  ('Cable Crossover', MuscleGroup.chest, Equipment.cable, _r),
  ('Chest Press Machine', MuscleGroup.chest, Equipment.machine, _r),
  ('Pec Deck', MuscleGroup.chest, Equipment.machine, _r),
  ('Push-up', MuscleGroup.chest, Equipment.bodyweight, _r),
  ('Chest Dip', MuscleGroup.chest, Equipment.bodyweight, _r),

  // Back
  ('Deadlift', MuscleGroup.back, Equipment.barbell, _r),
  ('Barbell Row', MuscleGroup.back, Equipment.barbell, _r),
  ('T-Bar Row', MuscleGroup.back, Equipment.barbell, _r),
  ('Dumbbell Row', MuscleGroup.back, Equipment.dumbbell, _r),
  ('Pull-up', MuscleGroup.back, Equipment.bodyweight, _r),
  ('Chin-up', MuscleGroup.back, Equipment.bodyweight, _r),
  ('Lat Pulldown', MuscleGroup.back, Equipment.cable, _r),
  ('Seated Cable Row', MuscleGroup.back, Equipment.cable, _r),
  ('Straight-arm Pulldown', MuscleGroup.back, Equipment.cable, _r),
  ('Machine Row', MuscleGroup.back, Equipment.machine, _r),
  ('Back Extension', MuscleGroup.back, Equipment.bodyweight, _r),

  // Shoulders
  ('Overhead Press', MuscleGroup.shoulders, Equipment.barbell, _r),
  ('Seated Dumbbell Press', MuscleGroup.shoulders, Equipment.dumbbell, _r),
  ('Arnold Press', MuscleGroup.shoulders, Equipment.dumbbell, _r),
  ('Lateral Raise', MuscleGroup.shoulders, Equipment.dumbbell, _r),
  ('Cable Lateral Raise', MuscleGroup.shoulders, Equipment.cable, _r),
  ('Front Raise', MuscleGroup.shoulders, Equipment.dumbbell, _r),
  ('Rear Delt Fly', MuscleGroup.shoulders, Equipment.dumbbell, _r),
  ('Face Pull', MuscleGroup.shoulders, Equipment.cable, _r),
  ('Upright Row', MuscleGroup.shoulders, Equipment.barbell, _r),
  ('Shoulder Press Machine', MuscleGroup.shoulders, Equipment.machine, _r),
  ('Barbell Shrug', MuscleGroup.shoulders, Equipment.barbell, _r),

  // Biceps
  ('Barbell Curl', MuscleGroup.biceps, Equipment.barbell, _r),
  ('EZ-Bar Curl', MuscleGroup.biceps, Equipment.barbell, _r),
  ('Dumbbell Curl', MuscleGroup.biceps, Equipment.dumbbell, _r),
  ('Hammer Curl', MuscleGroup.biceps, Equipment.dumbbell, _r),
  ('Incline Dumbbell Curl', MuscleGroup.biceps, Equipment.dumbbell, _r),
  ('Preacher Curl', MuscleGroup.biceps, Equipment.machine, _r),
  ('Concentration Curl', MuscleGroup.biceps, Equipment.dumbbell, _r),
  ('Cable Curl', MuscleGroup.biceps, Equipment.cable, _r),

  // Triceps
  ('Close-grip Bench Press', MuscleGroup.triceps, Equipment.barbell, _r),
  ('Skull Crusher', MuscleGroup.triceps, Equipment.barbell, _r),
  ('Tricep Pushdown', MuscleGroup.triceps, Equipment.cable, _r),
  ('Rope Pushdown', MuscleGroup.triceps, Equipment.cable, _r),
  ('Overhead Tricep Extension', MuscleGroup.triceps, Equipment.dumbbell, _r),
  ('Tricep Dip', MuscleGroup.triceps, Equipment.bodyweight, _r),
  ('Tricep Kickback', MuscleGroup.triceps, Equipment.dumbbell, _r),

  // Forearms
  ('Wrist Curl', MuscleGroup.forearms, Equipment.dumbbell, _r),
  ('Reverse Curl', MuscleGroup.forearms, Equipment.barbell, _r),
  (
    "Farmer's Walk",
    MuscleGroup.forearms,
    Equipment.dumbbell,
    TrackingType.distance,
  ),
  ('Dead Hang', MuscleGroup.forearms, Equipment.bodyweight, TrackingType.time),

  // Legs
  ('Back Squat', MuscleGroup.legs, Equipment.barbell, _r),
  ('Front Squat', MuscleGroup.legs, Equipment.barbell, _r),
  ('Goblet Squat', MuscleGroup.legs, Equipment.dumbbell, _r),
  ('Leg Press', MuscleGroup.legs, Equipment.machine, _r),
  ('Hack Squat', MuscleGroup.legs, Equipment.machine, _r),
  ('Bulgarian Split Squat', MuscleGroup.legs, Equipment.dumbbell, _r),
  ('Walking Lunge', MuscleGroup.legs, Equipment.dumbbell, _r),
  ('Romanian Deadlift', MuscleGroup.legs, Equipment.barbell, _r),
  ('Leg Extension', MuscleGroup.legs, Equipment.machine, _r),
  ('Lying Leg Curl', MuscleGroup.legs, Equipment.machine, _r),
  ('Seated Leg Curl', MuscleGroup.legs, Equipment.machine, _r),
  ('Standing Calf Raise', MuscleGroup.legs, Equipment.machine, _r),
  ('Seated Calf Raise', MuscleGroup.legs, Equipment.machine, _r),
  ('Step-up', MuscleGroup.legs, Equipment.dumbbell, _r),

  // Glutes
  ('Hip Thrust', MuscleGroup.glutes, Equipment.barbell, _r),
  ('Glute Bridge', MuscleGroup.glutes, Equipment.bodyweight, _r),
  ('Cable Kickback', MuscleGroup.glutes, Equipment.cable, _r),
  ('Hip Abduction Machine', MuscleGroup.glutes, Equipment.machine, _r),
  ('Sumo Deadlift', MuscleGroup.glutes, Equipment.barbell, _r),

  // Core
  ('Plank', MuscleGroup.core, Equipment.bodyweight, TrackingType.time),
  ('Side Plank', MuscleGroup.core, Equipment.bodyweight, TrackingType.time),
  ('Crunch', MuscleGroup.core, Equipment.bodyweight, _r),
  ('Hanging Leg Raise', MuscleGroup.core, Equipment.bodyweight, _r),
  ('Cable Crunch', MuscleGroup.core, Equipment.cable, _r),
  ('Russian Twist', MuscleGroup.core, Equipment.bodyweight, _r),
  ('Ab Wheel Rollout', MuscleGroup.core, Equipment.other, _r),
  (
    'Mountain Climber',
    MuscleGroup.core,
    Equipment.bodyweight,
    TrackingType.time,
  ),

  // Cardio
  (
    'Treadmill Run',
    MuscleGroup.cardio,
    Equipment.machine,
    TrackingType.distance,
  ),
  ('Outdoor Run', MuscleGroup.cardio, Equipment.other, TrackingType.distance),
  (
    'Stationary Bike',
    MuscleGroup.cardio,
    Equipment.machine,
    TrackingType.distance,
  ),
  (
    'Rowing Machine',
    MuscleGroup.cardio,
    Equipment.machine,
    TrackingType.distance,
  ),
  ('Elliptical', MuscleGroup.cardio, Equipment.machine, TrackingType.time),
  ('Stair Climber', MuscleGroup.cardio, Equipment.machine, TrackingType.time),
  ('Jump Rope', MuscleGroup.cardio, Equipment.other, TrackingType.time),

  // Full body
  ('Kettlebell Swing', MuscleGroup.fullBody, Equipment.kettlebell, _r),
  ('Clean and Press', MuscleGroup.fullBody, Equipment.barbell, _r),
  ('Thruster', MuscleGroup.fullBody, Equipment.barbell, _r),
  ('Burpee', MuscleGroup.fullBody, Equipment.bodyweight, _r),
  ('Turkish Get-up', MuscleGroup.fullBody, Equipment.kettlebell, _r),
];

/// Measurements every new profile starts with; more can be added later.
const List<(String name, String unit)> seedMeasurementTypes = [
  ('Body weight', 'kg'),
  ('Body fat', '%'),
  ('Chest', 'cm'),
  ('Waist', 'cm'),
  ('Hips', 'cm'),
  ('Left arm', 'cm'),
  ('Right arm', 'cm'),
  ('Left thigh', 'cm'),
  ('Right thigh', 'cm'),
  ('Calves', 'cm'),
  ('Neck', 'cm'),
  ('Shoulders', 'cm'),
];
