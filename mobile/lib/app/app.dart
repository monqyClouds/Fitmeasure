import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/profiles/profile_picker_screen.dart';
import '../features/shell/home_shell.dart';
import 'providers.dart';
import 'theme.dart';

class FitmeasureApp extends ConsumerWidget {
  const FitmeasureApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(currentProfileProvider).value;
    final accent = profile == null
        ? AppColors.profileColors.first
        : Color(profile.color);
    final profileId = ref.watch(currentProfileIdProvider);

    return MaterialApp(
      title: 'Fitmeasure',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(accent),
      themeAnimationDuration: Motion.slow,
      themeAnimationCurve: Motion.standard,
      home: PageTransitionSwitcher(
        duration: Motion.slow,
        transitionBuilder: (child, primary, secondary) => SharedAxisTransition(
          animation: primary,
          secondaryAnimation: secondary,
          transitionType: SharedAxisTransitionType.scaled,
          fillColor: AppColors.background,
          child: child,
        ),
        child: profileId == null
            ? const ProfilePickerScreen(key: ValueKey('picker'))
            : HomeShell(key: ValueKey('home-$profileId')),
      ),
    );
  }
}
