# Blink

A fast Spotlight replacement that does two things: open apps from the
Applications folders and do math. Press ⌘Space, type, hit Return.

- Apps are matched by prefix, word start (“notes” → Sticky Notes), initials
  (“vsc” → Visual Studio Code), substring, then fuzzily. Apps you open often
  rank higher.
- Math supports `+ - * / % ^` (also `**`, `×`, `÷`), parentheses, `pi`, `e`,
  and `sqrt cbrt abs sin cos tan asin acos atan ln log log2 exp floor ceil
  round`. Return copies the result.
- ↑/↓ select, Esc closes.

## Install

1. Turn off Spotlight’s shortcut: System Settings → Keyboard → Keyboard
   Shortcuts… → Spotlight → uncheck “Show Spotlight search”.
2. Build and install (needs the Xcode command line tools):

   ```
   make install
   ```

Blink adds itself as a login item on first launch from /Applications. To quit
it, run `pkill -x Blink`.

## Develop

```
make test
make app   # builds build/Blink.app
```
