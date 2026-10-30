![Blink](assets/banner.svg)

# Blink

A blazing-fast Spotlight replacement that does three things: open apps
from the Applications folder, find files in your home folder and do math.
Press ⌘Space, type, hit Return.

- Apps are matched by prefix, word start (“notes” → Sticky Notes), initials
  (“vsc” → Visual Studio Code), substring, then fuzzily. Apps you open often
  rank higher.
- Files and folders are matched by name: prefix, word start, then substring,
  ignoring case and accents. Blink keeps every name in your home folder in
  memory and follows changes as they happen, so it doesn’t wait on
  Spotlight’s index. It leaves out ~/Library, hidden files, node_modules and
  the insides of packages like .app bundles. Files you open often rank
  higher, and names that are mostly a hash or a UUID rank lower. Each file
  shows its folder under its name.
- Math supports `+ - * / % ^` (also `**`, `×`, `÷`), parentheses, `pi`, `e`,
  and `sqrt cbrt abs sin cos tan asin acos atan ln log log2 exp floor ceil
  round`. Return copies the result.
- ↑/↓ select, Esc closes. ⌘Space again brings back your last search, with
  the same result selected; just type to start a new one. Click an app or
  file with two fingers to copy the file itself (to paste in Finder or Mail)
  or its path.

## Benchmarks

Medians from `make bench` on an Apple silicon Mac with macOS 27.0.1 and 98
apps installed:

| Task | Time |
| --- | --- |
| Indexing all apps with their icons (at launch and when apps change) | 28 ms |
| Search, 1 letter | 0.27 ms |
| Search, 2 or more letters | 0.03–0.05 ms |
| Math, `sqrt(2) * (3 + 4)^2 / pi` | 0.006 ms |

Files, with 2.5 million in the home folder, on a 14-core Apple silicon Mac
with macOS 27.2:

| Task | Time |
| --- | --- |
| Indexing all files (in the background, at launch) | 2.5 s |
| Search, 1 letter | 3.2 ms |
| Search, 2 or more letters | 0.8–1.6 ms |
| Spotlight’s index (`mdfind`), same name searches | 250–1,000 ms |

The file index takes 85 MB of memory for those 2.5 million names, and only
rereads the folders that change.

From keystroke to results on screen, measured frame by frame in 60 fps
screen recordings, Spotlight took 167–1,083 ms and Blink under 17 ms, within
a single frame.

All of these were measured on the repo owner’s Mac. Results on yours may
vary.

The whole app is 1 MB, 848 KB of which is its icon.

## Install

1. Turn off Spotlight’s shortcut: System Settings → Keyboard → Keyboard
   Shortcuts… → Spotlight → uncheck “Show Spotlight search”.
2. Download the .dmg from the
   [latest release](https://github.com/dchacke/blink/releases/latest), open
   it and drag Blink to Applications.
3. Open Blink. It isn’t notarized by Apple, so macOS blocks it the first
   time: click Done, then go to System Settings → Privacy & Security and
   click Open Anyway.
4. When macOS asks, allow Blink to access your Desktop, Documents and
   Downloads folders so it can search the files in them.

That’s it. Blink runs in the background, with no window, Dock icon or menu
bar icon, and it doesn’t show up in the ⌘Tab switcher. It quietly takes over
⌘Space from Spotlight.

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
