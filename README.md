# Linter (macOS / Nextpad++ port)

A Nextpad++ plugin for realtime code checking against any **checkstyle-compatible**
linter — `jshint`, `eslint`, `jscs`, `phpcs`, `csslint`, etc. It runs the linter
on the current document as you type, parses the checkstyle XML output, and marks
problems in the editor.

macOS port of the Windows Notepad++ plugin
[notepadpp-linter](https://github.com/deadem/notepadpp-linter) by Vladimir
Soshkin (MIT). The linting logic is ported faithfully; only the platform layer
changes (see the header of `src/Linter.mm`):

| Windows | macOS |
| --- | --- |
| `CreateProcess` + `CreatePipe` | `NSTask` + `NSPipe` (run via `/bin/sh -lc`) |
| MSXML6 COM (`IXMLDOMDocument2`) | `NSXMLDocument` + `nodesForXPath:` |
| `_beginthreadex` + `GetExitCodeThread` | `dispatch_async` worker → main-queue apply |
| `CreateTimerQueueTimer` (300 ms) | `dispatch_after` with a coalescing token |
| Win32 settings = the XML file | programmatic AppKit settings dialog + XML edit |

## Install

Copy `Linter.dylib` into
`~/Library/Application Support/Nextpad++/plugins/Linter/` and restart
Nextpad++. (`cmake --build build --target install` does this for you.)

## Configure

The linters live in `linter.xml` inside the host plugins config dir
(`Plugins > Linter > Edit config (XML)` opens it; a commented template is seeded
on first run). Or use the dialog: **Plugins > Linter > Settings…**.

```xml
<?xml version="1.0" encoding="utf-8" ?>
<NotepadPlus>
  <linter extension=".js"  command="eslint --format checkstyle" stdin="1" />
  <linter extension=".js"  command="jshint --reporter=checkstyle" />
  <linter extension=".php" command="phpcs --report=checkstyle" />
  <linter extension=".css" command="csslint --format=checkstyle-xml" />
</NotepadPlus>
```

* `extension` — matched against the current file's extension (with the dot).
* `command` — a checkstyle-emitting command. It runs through a **login shell**,
  so a bare name on your `PATH` (node/npm globals, Homebrew, etc.) resolves
  without an absolute path. The document is written to a temp file appended to
  the command unless `stdin="1"` is set.
* `stdin="1"` — feed the document on standard input instead of a temp file.
* Optional `<style color="RRGGBB" alpha="0-255" />` changes the marker colour
  (an alpha switches the marker from a box to a translucent round box).

## Notes / platform limitations

* **Error tooltips.** The Windows plugin wrote the per-position message into the
  editor's native status bar. On macOS that status bar is not a child window a
  plugin can poke, and `NPPM_SETSTATUSBAR` is a host no-op, so the message is
  shown instead as a Scintilla **call tip** at the caret when it sits on a
  flagged position. No host changes are made.
* Linters must be installed and on your shell `PATH` (or given an absolute
  path in the command).

## License

MIT — see `LICENSE`.
