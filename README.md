# InFlex
[![Ask DeepWiki](https://devin.ai/assets/askdeepwiki.png)](https://deepwiki.com/zsdev07/InFlex-2.git)

InFlex is a Flutter-based Android app for watching movies and TV shows, with a special focus on Hindi and dubbed content. It finds streams through Torrentio and plays them either instantly from a Telegram-backed cache or directly through a built-in on-device torrent engine.

## Download

Grab the latest APK from the **[Releases page](https://github.com/zsdev07/InFlex-2/releases/latest)**.

- One **universal APK** works on both **64-bit (arm64)** and **32-bit (arm32)** phones - no need to pick a version.
- Tap the APK, allow *Install unknown apps* if asked, and install.
- Requires **Android 7.0 (API 24) or newer**.

## Features

- **Big content library** - trending, Hindi movies, web series, South Indian dubbed films and more, powered by TMDB.
- **Two ways to stream**
    - **Telegram cache (instant):** previously cached titles play immediately. Cached torrents are pinned at the top with a golden **⚡ CACHED** badge.
    - **Built-in P2P engine:** InTorrent streams a torrent sequentially on your device while it downloads - no server needed for playback.
    - **Embed fallback:** a WebView player for embed sources such as VidSrc.
- **Modern player** - built on `media_kit` (HEVC/H.265, MKV, HDR), glassmorphism controls, seeking, playback speed, volume and brightness gestures, Picture-in-Picture, and subtitle support.
- **Torrent flow with visibility** - a separate buffering screen and player screen, so you can see exactly what the engine is doing.
- **Details, search and watchlist** - overviews, ratings, cast, episode lists, quick search, a personal watchlist and a *Continue watching* row.
- **External player** - open any stream in another player if you prefer.

## Architecture

```
            TMDB  ──────────────►  metadata, posters, details
              │
 InFlex (Flutter) ──► Torrentio ─►  available torrent streams
              │
              ├─► Supabase  ──────  cache lookup (IMDb ID → Telegram file_id)
              │       │ hit
              │       ▼
              │   TG-FileStreamBot ► seekable HTTP stream  ──►  media_kit player
              │
              └─► InTorrent (libtorrent via FFI)
                      sequential download + local HTTP stream ─►  media_kit player
```

**Cache path (Telegram):**
1. The app checks Supabase for a cached `file_id` for the title.
2. On a hit, the file streams instantly through a self-hosted **TG-FileStreamBot**.
3. On a miss, the app can send the magnet link to the **backend**, which has a **debrid bot** download the torrent and upload it to Telegram, then records the mapping in Supabase.

**P2P path (on-device):**
- [InTorrent](https://github.com/zsdev07/InTorrent) is our own Flutter plugin that wraps libtorrent over Dart FFI. It downloads pieces sequentially and serves them from a localhost HTTP server, so `media_kit` can play while the download is still running.
- It is compiled for **arm64-v8a** and **armeabi-v7a** (32-bit phones such as the Galaxy M01).

## Setup and Configuration

This repository only contains the Flutter app. To run your own copy you need to deploy the backend pieces and point the app at them.

### 1. Backend services

- **InFlex Backend** - a web service that connects the app to the debrid bot. The app currently points at `https://inflexbackend.onrender.com`; replace it with your own deployment.
- **Debrid Bot** - downloads torrents and uploads them to Telegram.
- **TG-FileStreamBot** - turns Telegram file IDs into streamable links. Deploy your own from [EverythingSuckz/TG-FileStreamBot](https://github.com/EverythingSuckz/TG-FileStreamBot).

### 2. Supabase

1. Create a project on [Supabase](https://supabase.com).
2. Open the **SQL Editor** and run:

    ```sql
    -- Main cache table
    create table public.telegram_cache (
      id            uuid primary key default gen_random_uuid(),
      imdb_id       text not null,
      quality       text not null default 'HD',
      magnet_link   text not null,
      info_hash     text not null,
      file_id       text,
      file_size     bigint,
      status        text not null default 'queued', -- queued | downloading | uploading | cached | error
      progress      int not null default 0,
      downloaded_mb float not null default 0,
      total_mb      float not null default 0,
      error_msg     text,
      created_at    timestamptz default now(),
      updated_at    timestamptz default now()
    );

    -- Faster lookups
    create index on public.telegram_cache (imdb_id, quality);

    -- Row Level Security + public read access
    alter table public.telegram_cache enable row level security;
    create policy "public read" on public.telegram_cache
      for select using (true);
    ```

### 3. App configuration

- **`lib/main.dart`** - `_supabaseUrl` and `_supabaseAnonKey`.
- **`lib/constants/app_constants.dart`** - `debridBackendBase` (your backend URL) and `fileStreamBase` (your TG-FileStreamBot URL).

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
