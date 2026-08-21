# 17-0 iOS

This project wraps the current 17-0 V11 game as a standalone iOS app.

## What changed from the Windows/web build

- The V11 HTML UI is bundled directly inside the app.
- `server.py` is **not** needed on iPhone.
- A native Swift `WKURLSchemeHandler` implements the game's `/api/players`, `/api/preload`, and `/api/health` endpoints.
- Roster/stat CSV data is fetched over HTTPS from nflverse and cached in the iOS app's Caches directory.
- Player headshots remain supported when the roster feed provides a headshot URL.

## Build an unsigned IPA on a Mac

1. Open `SeventeenZero.xcodeproj` in Xcode if you want to test/edit it.
2. Or run `./build_unsigned_ipa.sh` from Terminal.
3. The script creates `17-0-unsigned.ipa`.
4. Sign that IPA with your own iOS certificate before installing it on a physical iPhone.

## Build without owning a Mac

The included `.github/workflows/build-ipa.yml` can build the unsigned IPA on a GitHub macOS runner:

1. Put this project in a GitHub repository.
2. Open the repository's **Actions** tab.
3. Run **Build 17-0 IPA** manually.
4. Download the `17-0-unsigned-ipa` artifact.
5. Sign the IPA with your own certificate before installing it.

The bundled app target is `SeventeenZero`; its display name is `17-0`.
