# esh Storage Architecture (v2)

esh separates **lightweight state** (always on the internal disk) from **large AI assets**
(relocatable to an external SSD or any folder). This lets you keep multi-gigabyte model weights,
GGUF files, TTS voices, and caches on `/Volumes/AI` while esh's config and session history stay
small and always available on your Mac.

## Two roots

| Root | Default | Holds | Relocatable? |
|---|---|---|---|
| **State root** | `~/.esh` (or `$ESH_HOME`) | `config.toml`, `storage.json`, `sessions/`, `benchmarks/`, `runtime/` (Python venv), metadata | No — always internal |
| **Assets root** | same as state root | `models/`, `caches/`, `audio/` (incl. `tts-models/`), `tmp/` | **Yes** |

With zero configuration both roots are `~/.esh`, exactly as before — nothing changes for existing
users. Point the assets root elsewhere and only the heavy directories move; your config and
sessions stay internal so esh can always start and tell you what's going on.

## Commands

```bash
esh storage show                 # where things live + free space + sizes
esh storage show --json          # machine-readable (stable schema; used by esh doctor / Ashex)
esh storage set /Volumes/AI/esh  # relocate assets here (moves existing assets by default)
esh storage set /Volumes/AI/esh --no-move   # relocate config only, leave existing assets
esh storage use-internal         # move assets back onto the internal disk
esh storage doctor               # validate the configured storage (exit 1 if unavailable)
esh storage migrate /Volumes/AI/esh   # alias for `set` (always moves)
```

You can also override the assets root for a single run with `ESH_ASSETS_HOME=/path esh ...`
(useful for tests/CI). Precedence: `ESH_ASSETS_HOME` → persisted `storage.json` → internal.

## How disconnection is detected (no silent re-download)

When you select an external assets root, esh:

1. writes `storage.json` on the **internal** state root recording the path + a volume id, and
2. writes a marker file `<assetsRoot>/.esh-storage.json` containing that same id.

On every run esh verifies the assets root exists, the marker is present, its id matches, and the
location is writable. If any check fails the storage is reported **unavailable** with a clear
message naming the expected path:

```
Model storage volume is unavailable at /Volumes/AI/esh: the esh storage marker is missing
(the volume may be disconnected, or a different volume is mounted here). Reconnect the volume
(or run `esh storage use-internal`) and try again. esh will not re-download large assets onto
the internal disk automatically.
```

The marker/id scheme means esh can tell "volume disconnected" apart from "a *different* volume is
now mounted at this path", and it never silently duplicates hundreds of gigabytes back onto the
internal disk. Large-write paths (model install, TTS voice download) are gated on this check, so
they fail fast with the message above instead of erroring cryptically mid-download. Reconnecting
the volume restores everything with no reinstall.

## Notes

- **Spaces / unicode** in paths are supported (`/Volumes/AI Drive/esh` works).
- **APFS / exFAT**: any writable directory works; esh does not require APFS.
- **Migration** moves `models/`, `caches/`, `audio/`, `tmp/` between roots, merging into an
  existing destination and falling back to copy+remove across volumes.
- `storage.json` is deliberately a small JSON file on the internal disk (not the TOML `config`) so
  it is always readable even when the external volume is gone. It carries a `schemaVersion` for
  forward migration.
