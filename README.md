# MacDict

A keyboard-first English dictionary for macOS. English definitions and examples are primary; a compact local ECDICT translation provides a Chinese hint. Every result can be read aloud with separate English and Mandarin voices.

## Status

This repository contains the first functional MVP for macOS 14+ on Apple Silicon. It is intentionally distributed as source while no Apple Developer ID is available.

## Features

- Look up selected text from another app with Control–Option–D.
- Open a focused search panel with Control–Option–Space.
- English definitions, examples, phonetics, attribution, and per-entry licensing from Free Dictionary API.
- Optional local ECDICT Chinese hints and inflection lookup.
- Speak the headword, selected English definition, Chinese hint, or full entry.
- Local favorites, history, and cached English results.
- No accounts, paid API keys, clipboard monitoring, or background text collection.

## Build

Requirements:

- Apple Silicon Mac
- macOS 14 or later
- Xcode 15.3 or later, or matching Command Line Tools
- Python 3 only if installing ECDICT

Build an ad-hoc-signed local app:

```bash
chmod +x Scripts/build-app.sh Scripts/install-ecdict.py
Scripts/build-app.sh
open dist/MacDict.app
```

You can also open `Package.swift` in Xcode and run the `MacDict` executable target while developing. The packaging script is needed for a stable application bundle identifier and predictable Accessibility permission.

## Install Chinese hints

ECDICT is deliberately downloaded by the user rather than committed to this repository:

```bash
python3 Scripts/install-ecdict.py
```

The installer downloads a pinned 65.9 MB CSV, verifies its SHA-256 checksum, and writes an indexed database to:

```text
~/Library/Application Support/MacDict/ecdict.sqlite3
```

MacDict detects the database on the next lookup. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) before redistributing dictionary data.

## Accessibility permission

Typed search works without special permission. Looking up selected text requires:

1. Launch MacDict.
2. Choose **Grant Accessibility Access…** from the menu-bar menu.
3. Enable MacDict in **System Settings → Privacy & Security → Accessibility**.
4. Relaunch MacDict if macOS does not refresh the grant immediately.

MacDict reads `kAXSelectedTextAttribute` from the focused control. If an app does not expose its selection, MacDict opens the typing field instead. It does not simulate Command–C or modify the clipboard.

Ad-hoc development builds can lose Accessibility permission after the binary changes. If selection stops working after rebuilding, remove the old MacDict entry from Accessibility settings and add the newly built app again.

## Privacy

Only a submitted, uncached English query is sent to `api.dictionaryapi.dev`. The selected surrounding document, typing events, history, favorites, and Chinese dictionary stay on the Mac. History can be cleared from Settings.

## Verification

```bash
swift test
Scripts/build-app.sh
```

GitHub Actions runs the same checks on macOS. This Linux workspace cannot compile AppKit, validate system voices, or exercise the Accessibility permission flow; those checks must pass in macOS CI and on a real Mac.

## Known MVP limits

- Selected-text lookup depends on the source application's Accessibility support.
- Uncached English definitions require internet access.
- Pronunciation of heteronyms such as “read” and “lead” may not match the intended sense when synthesized.
- The first version uses fixed global shortcuts; a shortcut recorder is planned.
- Builds are ad-hoc signed, not Developer ID signed or notarized. Friends should build from source rather than bypass Gatekeeper.
