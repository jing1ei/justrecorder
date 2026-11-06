# JustRecorder reference

## Naming

Default template `[{artist} - ]{title} {duration}`

| Token | Value |
|---|---|
| `{title}` | Cleaned title, optionally polished by AI |
| `{raw_title}` | Original window or track title, sanitized |
| `{artist}` / `{track}` | Player metadata, when available |
| `{app}` | Source application |
| `{duration}` / `{seconds}` | `1m3s` / `63` |
| `{format}` | Saved audio format |
| `{date}` / `{time}` / `{datetime}` | Local date and time |

Optional `[groups]` disappear when a known token inside is empty. Repeated filenames get a numeric suffix. AI errors fall back to the local title.

macOS settings screenshots for [Capture](screenshots/macos-capture.jpg), [Naming](screenshots/macos-naming.jpg), [AI naming](screenshots/macos-ai-naming.jpg) and [General](screenshots/macos-general.jpg).

## Formats and recovery

On Mac, MP3 uses `lame` or `ffmpeg` from a standard Homebrew, MacPorts or system binary directory. If no encoder is found, capture uses AAC. If conversion fails, the WAV is kept. See the [Windows guide](../Windows/README.md#encoders-and-recovery) for Windows encoders.

At startup, JustRecorder looks for interrupted recordings in the current save folder. Readable clips are recovered as `Recovered Snippet …`. Keep that folder available until saving completes.

## macOS build

With Xcode Command Line Tools and Swift 5.9+, run from the repository root.

```sh
./build.sh --universal   # build/JustRecorder.app for Apple silicon and Intel
./build.sh --dmg         # universal app in a disk image
./build.sh --install     # native build, install and launch
./test.sh                # native regression checks
python3 source-release.py
```

Set `JUSTRECORDER_SIGN_IDENTITY` to use an installed signing identity. A rebuilt ad-hoc app may need capture permission again.

## macOS diagnostics

If permission prompts repeat, quit all copies, remove the old entry under **Privacy & Security → Screen & System Audio Recording**, add the installed copy and reopen it. If capture times out, quit and reopen the app. Player Automation consent is separate from capture permission.

```sh
log stream --predicate 'subsystem == "com.jing1ei.JustRecorder"' --level info
```
