# Fitmeasure

A gym workout and body-measurement tracker for Android and iPhone, built with
Flutter.
Several people can share one phone, each with their own profile. All data stays
on the device. Units are metric: kg, cm and km.

## Features

Done (phase 1):

- **Profiles**: a "Who's training?" picker, each person with their own name and
  accent colour. The app reopens the last profile used.
- **Cycles**: bulk, cut, strength, endurance or an ongoing routine. Each type
  suggests default sets, reps and rest times. Starting a new cycle ends the one
  still running.
- **Exercise library**: about 90 built-in exercises grouped by muscle and
  equipment, plus your own custom ones. Each exercise is logged as reps and
  weight, time, or distance and time.
- **Media per exercise**: photos and videos from the phone are copied into the
  app's own storage, so the link never breaks. Web links (YouTube etc.) open
  externally.

Done (phase 2):

- **Plans**: weekly plans (each day on a weekday) or rotations (Push, Pull,
  Legs… in turn, whenever you train). Start from a template (Push / Pull /
  Legs, Upper / Lower, Full body ×3) or build your own. Each exercise gets
  target sets, reps, weight, time or distance and rest, suggested by the
  current cycle.
- **Today**: this week at a glance, today's planned workout (or a rest day and
  what's next), a resume card for a workout in progress, and recent workouts
  with a volume chart.
- **Workout logging**: tick off each set against its target, with values from
  last time shown and prefilled, a rest timer that vibrates when rest is over,
  elapsed time and volume. Add or remove exercises and sets as you go. A
  summary at the end highlights new personal bests.
- **Progress**: week streak, training calendar heatmap, weekly volume and
  totals (phase 3 adds body and strength here).

Done (phase 3):

- **Body measurements**: body weight, body fat and tape measurements, plus
  your own (any name and unit), reorderable. Log them all at once or one at a
  time; body weight has a one-tap card on Today.
- **Charts**: every measurement and exercise gets a trend chart with the
  background shaded by cycle, a 1M/3M/6M/1Y/All range and touch tooltips.
- **Strength per exercise**: estimated 1-rep max (Epley), heaviest set,
  volume, reps, time or distance over time, with the workouts behind it.
- **Personal records**: best 1RM, heaviest set, best volume and more per
  exercise, and recent records on Progress.

Done (phase 4):

- **Backup and restore**: one `.zip` with everything (optionally without
  photos and videos). Share it to Drive, email or a chat, or save it to the
  phone. Restoring replaces all data, works across phones, refuses backups
  from newer app versions, and keeps a restore point so it can be undone.
- **Polish**: the screen stays on during workouts (can be turned off), an app
  icon and dark launch screen, and a Settings screen (profile menu → Settings
  & backup).

## Getting the app on your phone

Every push builds an Android APK and an iPhone app on GitHub Actions.

### Android

1. Open the repository on GitHub, go to **Actions**, then **Build**, and pick
   the latest run.
2. Download the **fitmeasure-apk** artifact and unzip it.
3. Copy `app-release.apk` to your phone and open it. Allow installing from
   unknown sources when Android asks.

### Keep your data between updates

Android only installs an update over the existing app when both are signed
with the same key. Without one, each CI build is signed with a throwaway key,
and you would have to uninstall (losing your data) before installing a newer
build. To avoid that, create a key once:

```sh
keytool -genkey -v -keystore fitmeasure.jks -keyalg RSA -keysize 2048 \
  -validity 10000 -alias fitmeasure
base64 -w0 fitmeasure.jks   # copy the output
```

Then add these repository secrets on GitHub (**Settings → Secrets and variables
→ Actions**):

| Secret | Value |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the base64 output above |
| `ANDROID_KEYSTORE_PASSWORD` | the password you chose |
| `ANDROID_KEY_ALIAS` | `fitmeasure` |

Keep `fitmeasure.jks` somewhere safe and never commit it.

### iPhone (free Apple ID)

iOS apps can only be built on a Mac, so GitHub Actions builds an unsigned
`.ipa` on a Mac runner. You sign and install it from Windows with
[Sideloadly](https://sideloadly.io) and a free Apple ID. The catch: apps
signed with a free Apple ID stop opening after 7 days and have to be
installed again (your data is kept when you install over the app).

One-time setup:

1. On Windows, install **iTunes** and **iCloud** from Apple's website (not
   the Microsoft Store versions), then install Sideloadly.
2. Connect the iPhone by USB and tap **Trust** on the phone.
3. On iOS 16 or later, turn on **Settings → Privacy & Security → Developer
   Mode** (the phone restarts).

Each install (and every 7 days):

1. In GitHub, **Actions → Build → latest run**, download
   **fitmeasure-ios-unsigned** and unzip it to get `fitmeasure-unsigned.ipa`.
2. Open Sideloadly, pick the iPhone, drag in the `.ipa`, enter your Apple ID
   and press **Start**. A spare Apple ID is a sensible choice here.
3. The first time: on the iPhone, **Settings → General → VPN & Device
   Management**, tap your Apple ID and **Trust** it.

Notes:

- If Sideloadly says the bundle ID is unavailable, set a different one under
  its advanced options (e.g. `com.<yourname>.fitmeasure`) and keep using that
  same one, or the next install becomes a separate app without your data.
- A free Apple ID can have at most 3 sideloaded apps at a time.
- Sideloadly can refresh the app automatically before the 7 days run out
  while the phone and PC are on the same Wi-Fi.
- Back up from **Settings & backup** in the app now and then: if the app is
  ever deleted, restoring the backup brings everything back.

## Development

The repository holds two projects:

```
mobile/   Flutter app (Android, iPhone, and later the web client)
server/   Go backend for live sessions, with a WebRTC SFU built on Pion
docs/     design docs (live sessions: docs/live-sessions.md)
```

### App

```sh
cd mobile
flutter pub get
flutter run                            # with a phone connected or an emulator
flutter test
dart run build_runner build            # after changing database tables
```

The launcher icons are drawn by `mobile/tool/make_icons.py` (needs Pillow):

```sh
cd mobile
python3 tool/make_icons.py
```

App code layout:

```
mobile/lib/
  app/        app root, theme and motion tokens, Riverpod providers
  data/       drift database (tables, generated code), seed data, repositories,
              backup
  domain/     enums (cycle types, muscle groups…) and date helpers
  features/   one folder per area: profiles, today, cycles, library, …
  widgets/    shared widgets and animation helpers
```

The font is Plus Jakarta Sans, under the SIL Open Font License
(`mobile/assets/fonts/OFL.txt`).

### Server

See [`server/README.md`](server/README.md).
