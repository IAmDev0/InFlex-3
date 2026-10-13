# InFlex
[![Ask DeepWiki](https://devin.ai/assets/askdeepwiki.png)](https://deepwiki.com/zsdev07/InFlex-2.git)

InFlex is a Flutter-based Android app for watching movies and TV shows, with a special focus on Hindi and dubbed content. It finds streams through Torrentio and plays them directly on your device through a built-in torrent engine, so no server is needed for playback.

## Download

Grab the latest APK from the **[Releases page](https://github.com/zsdev07/InFlex-2/releases/latest)**.

- One **universal APK** works on both **64-bit (arm64)** and **32-bit (arm32)** phones - no need to pick a version.
- Tap the APK, allow *Install unknown apps* if asked, and install.
- Requires **Android 7.0 (API 24) or newer**.

## Features

- **Big content library** - trending, Hindi movies, web series, South Indian dubbed films and more, powered by TMDB.
- **Built-in P2P streaming** - InTorrent streams a torrent sequentially on your device while it downloads, so playback starts before the download finishes.
- **Embed fallback** - a WebView player for embed sources such as VidSrc.
- **Modern player** - built on `media_kit` (HEVC/H.265, MKV, HDR), glassmorphism controls, seeking, playback speed, volume and brightness gestures, Picture-in-Picture, and subtitle support.
- **Torrent flow with visibility** - a separate buffering screen and player screen, so you can see exactly what the engine is doing.
- **Details, search and watchlist** - overviews, ratings, cast, episode lists, quick search, a personal watchlist and a *Continue watching* row.
- **External player** - open any stream in another player if you prefer.

## How it works

```
 TMDB  ─────────►  metadata, posters, details
   │
 InFlex (Flutter) ──► Torrentio  ──►  available torrent streams
   │
   └─► InTorrent (libtorrent via FFI)
          sequential download + local HTTP stream  ──►  media_kit player
```

1. The app loads titles and details from **TMDB**.
2. When you pick a title, it asks **Torrentio** for available streams.
3. You choose a stream and **InTorrent** starts downloading it sequentially.
4. InTorrent serves the downloaded pieces from a localhost HTTP server, and **media_kit** plays them while the rest is still downloading.

[InTorrent](https://github.com/zsdev07/InTorrent) is our own Flutter plugin that wraps libtorrent over Dart FFI. It is compiled for **arm64-v8a** and **armeabi-v7a** (32-bit phones such as the Galaxy M01).

## Building from source

You need the Flutter SDK (3.27.0 is what CI uses) and Java 17.

```bash
git clone https://github.com/zsdev07/InFlex-2.git
cd InFlex-2
flutter pub get
dart run build_runner build --delete-conflicting-outputs
dart run flutter_launcher_icons

# Universal APK (arm64 + arm32)
flutter build apk --release --target-platform android-arm,android-arm64
```

The APK is written to `build/app/outputs/flutter-apk/app-release.apk`.

> The first build compiles libtorrent from source for each ABI, so it can take a while and needs a few GB of free disk space.

## Releases (GitHub Actions)

**`build.yml`** builds and publishes the app:

1. Open **Actions → InFlex Flutter Build → Run workflow**.
2. Type the version you want, e.g. `4.5.6` (leave empty to use `pubspec.yaml`).
3. The workflow builds one universal APK, checks that it contains both arm64 and arm32 libraries, and publishes it as a **GitHub Release** tagged `v4.5.6`.

Notes:
- The Android build number (`versionCode`) is the workflow run number, so every build is newer than the last and installs over the previous one.
- Pull request builds only upload the APK as a workflow artifact; they don't create a release.
- Re-running with the same version replaces that release's APK.

**`unzip.yml`** is a utility workflow that extracts a project archive named `InFlex_updated.zip` pushed to the repository and commits its contents.

## Troubleshooting

- **"App not installed"** - make sure you installed the universal APK from the Releases page. If it still fails, uninstall any older InFlex build first (builds signed with a different key can't update each other).
- **Torrent playback is slow to start** - the P2P engine needs a few pieces before it can play; the buffering screen shows progress. Popular torrents with many seeds start fastest.
- 
