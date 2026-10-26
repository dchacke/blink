![Blink](assets/banner.svg)

# Blink

A blazing-fast Spotlight replacement that does two things: open apps from
the Applications folder and do math. Press ⌘Space, type, hit Return.

- Apps are matched by prefix, word start (“notes” → Sticky Notes), initials
  (“vsc” → Visual Studio Code), substring, then fuzzily. Apps you open often
  rank higher.
- Math supports `+ - * / % ^` (also `**`, `×`, `÷`), parentheses, `pi`, `e`,
  and `sqrt cbrt abs sin cos tan asin acos atan ln log log2 exp floor ceil
  round`. Return copies the result.
- ↑/↓ select, Esc closes.

## Benchmarks

Medians from `make bench` on an Apple silicon Mac with macOS 27.0.1 and 98
apps installed:

| Task | Time |
| --- | --- |
| Indexing all apps with their icons (at launch and when apps change) | 28 ms |
| Search, 1 letter | 0.27 ms |
| Search, 2 or more letters | 0.03–0.05 ms |
| Math, `sqrt(2) * (3 + 4)^2 / pi` | 0.006 ms |

The whole app is 216 KB.

## Install

1. Turn off Spotlight’s shortcut: System Settings → Keyboard → Keyboard
   Shortcuts… → Spotlight → uncheck “Show Spotlight search”.
2. Download the .dmg from the
   [latest release](https://github.com/dchacke/blink/releases/latest), open
   it and drag Blink to Applications.
3. Open Blink. It isn’t notarized by Apple, so macOS blocks it the first
   time: click Done, then go to System Settings → Privacy & Security and
   click Open Anyway.

Or build and install it yourself (needs the Xcode command line tools):

```
make install
```

Blink adds itself as a login item on first launch from /Applications. To quit
it, run `pkill -x Blink`.

Each release’s .dmg comes with a GPG signature. To check it:

```
curl -s https://github.com/dchacke.gpg | gpg --import
gpg --verify Blink-<version>.dmg.asc
```

## Develop

```
make test
make bench
make app   # builds build/Blink.app
make dmg   # builds build/Blink-<version>.dmg for Apple silicon and Intel
```
