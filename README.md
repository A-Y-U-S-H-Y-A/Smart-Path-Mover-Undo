# Smart Path Mover & Undo

A polyglot `.bat` / PowerShell script that extracts Windows paths from arbitrary text, lets you cherry-pick which ones to move, and writes an undo manifest so you can reverse the whole thing if something goes wrong.

---

## Why this exists

Sometimes you have a wall of text — an error log, a build output, a stack trace — and you just need to grab the actual files it's talking about and move them somewhere. Doing it by hand means squinting at paths, copy-pasting one at a time, and hoping you didn't miss anything.

This script handles that. Paste the text in, it finds the paths, you tick the ones you want, pick a destination, done. Every move is logged to an `undo_manifest.json` so you can roll it back with a single command if needed.

---

## Requirements

- Windows
- PowerShell 5.1+ (ships with Windows 10/11, no install needed)

---

## Usage

### GUI mode (default)

Just double-click `main.bat` or run it from a terminal with no arguments.

```
main.bat
```

You'll get an arrow-key menu with two options: move files or undo a previous move.

**Move flow:**
1. A text box opens — paste anything that contains Windows paths.
2. The script scans the text and shows you a checklist of every path it found that actually exists on disk.
3. Tick the ones you want, enter a destination folder, and hit **Move Selected Items**.
4. An `undo_manifest.json` is saved to the destination folder.

**Undo flow:**
1. Select "Undo a previous move" from the menu.
2. Paste the path to `undo_manifest.json` (or just its parent folder).
3. Confirm the preview and the files go back where they came from. If the restore is clean, the manifest is deleted automatically.

---

### CLI mode

For scripting or automation.

**Move:**
```
main.bat -Mode Move -InputFile "C:\paths.txt" -TargetDir "C:\Destination"
```

**Undo:**
```
main.bat -Mode Undo -ManifestPath "C:\Destination\undo_manifest.json"
```

**`-Force` flag** skips any confirmation prompts and auto-renames collisions instead of asking. Useful in batch jobs.

**Full options:**

| Flag | Description |
|---|---|
| `-Mode` | `GUI` (default), `Move`, or `Undo` |
| `-InputFile` | Text file containing paths (Move mode) |
| `-TargetDir` | Destination folder (Move mode) |
| `-ManifestPath` | Path to `undo_manifest.json` or its folder (Undo mode) |
| `-Force` | Skip prompts, auto-rename on collision |
| `-h` / `-help` | Show help |

---

## How path extraction works

The regex stops at characters like `[`, `]`, `'`, and `"`, so paths embedded in log-style lines like:

```
Failed to move [D:\project\app.py] - Access denied
```

extract cleanly as `D:\project\app.py` rather than pulling in the surrounding text. Duplicate paths are collapsed, and anything that doesn't exist on disk at the time of scanning is silently dropped from the list.

---

## Name collisions

If a file with the same name already exists at the destination:

- **GUI mode** — prompts you to auto-rename, skip, or auto-rename and log it.
- **CLI without `-Force`** — skips and logs.
- **CLI with `-Force`** — auto-renames and logs.

Renamed files get a `_1`, `_2`, etc. suffix before the extension.

---

## Undo manifest

After a successful move, `undo_manifest.json` is written to the destination folder. It records the original and current path of every item that was moved. The undo operation reads this file and moves everything back. If the original folder structure no longer exists, it can recreate it (or skip, depending on your choice).

If all items restore successfully, the manifest deletes itself. If anything is skipped or fails, it stays so you can inspect what happened.

---

## Security notes

- The `.bat` wrapper copies itself to a randomized temp path before launching PowerShell, which prevents TOCTOU/hijacking attacks on the temp file.
- The undo operation shows a preview and requires explicit confirmation before doing anything (bypassed with `-Force`).
