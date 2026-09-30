# Fitmeasure

A gym workout and body-measurement tracker for Android, built with Flutter.
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

Planned:

- **Phase 2**: weekly or rotating plans with target sets, reps, weight and time.
  Logging actual sets against targets, with a rest timer and session timing.
- **Phase 3**: body measurements and charts (trends shaded by cycle, a training
  calendar heatmap, volume, personal records).
- **Phase 4**: backup export and import, and polish.

## Getting the app on your phone

Every push builds an APK on GitHub Actions:

1. Open the repository on GitHub, go to **Actions**, then **Android**, and pick
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

## Development

```sh
flutter pub get
flutter run                            # with a phone connected or an emulator
flutter test
dart run build_runner build            # after changing database tables
```

### Layout

```
lib/
  app/        app root, theme and motion tokens, Riverpod providers
  data/       drift database (tables, generated code), seed data, repositories
  domain/     enums (cycle types, muscle groups…) and date helpers
  features/   one folder per area: profiles, today, cycles, library, …
  widgets/    shared widgets and animation helpers
```

The font is Plus Jakarta Sans, under the SIL Open Font License
(`assets/fonts/OFL.txt`).
