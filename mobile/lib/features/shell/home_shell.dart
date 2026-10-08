import 'dart:async';

import 'package:animations/animations.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../library/library_screen.dart';
import '../live/join_room.dart';
import '../live/live_screen.dart';
import '../live/rooms_api.dart';
import '../plans/plans_screen.dart';
import '../progress/progress_screen.dart';
import '../today/today_screen.dart';

/// Links the app was opened with, the first one included. Tests replace
/// it: there's no platform to ask.
final roomLinksProvider = Provider<Stream<Uri>>(
  (ref) => AppLinks().uriLinkStream,
);

class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;
  StreamSubscription<Uri>? _links;

  static const _liveTab = 4;

  @override
  void initState() {
    super.initState();
    // Room links (live.somto.si/r/k7f3qz) open the room, whether they
    // started the app or arrived while it was running.
    _links = ref.read(roomLinksProvider).listen(_onLink, onError: (_) {});
  }

  @override
  void dispose() {
    _links?.cancel();
    super.dispose();
  }

  void _onLink(Uri uri) {
    final id = roomIdFromLink(uri);
    if (id == null || !mounted) return;
    setState(() => _index = _liveTab);
    openRoomById(context, ref, id);
  }

  static const _tabs = <Widget>[
    TodayScreen(key: PageStorageKey('today')),
    PlansScreen(key: PageStorageKey('plans')),
    LibraryScreen(key: PageStorageKey('library')),
    ProgressScreen(key: PageStorageKey('progress')),
    LiveScreen(key: PageStorageKey('live')),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageTransitionSwitcher(
        duration: Motion.medium,
        transitionBuilder: (child, primary, secondary) => FadeThroughTransition(
          animation: primary,
          secondaryAnimation: secondary,
          fillColor: AppColors.background,
          child: child,
        ),
        child: KeyedSubtree(key: ValueKey(_index), child: _tabs[_index]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        animationDuration: Motion.medium,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.wb_sunny_outlined),
            selectedIcon: Icon(Icons.wb_sunny_rounded),
            label: 'Today',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month_rounded),
            label: 'Plans',
          ),
          NavigationDestination(
            icon: Icon(Icons.fitness_center_outlined),
            selectedIcon: Icon(Icons.fitness_center_rounded),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: 'Progress',
          ),
          NavigationDestination(
            icon: Icon(Icons.videocam_outlined),
            selectedIcon: Icon(Icons.videocam_rounded),
            label: 'Live',
          ),
        ],
      ),
    );
  }
}
