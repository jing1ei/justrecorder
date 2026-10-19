# JustRecorder reference

[Quick start](../README.md)

## Naming

Default: `[{artist} - ]{title} {duration}`

| Token | Value |
|---|---|
| `{title}` | Cleaned title; optionally polished by AI |
| `{raw_title}` | Original window or track title, sanitized for filenames |
| `{artist}` / `{track}` | Player metadata, when available |
| `{app}` | Source application |
| `{duration}` / `{seconds}` | `1m3s` / `63` |
| `{format}` | Format actually saved |
| `{date}` / `{time}` / `{datetime}` | Local date and time |

An optional `[group]` disappears if a known token inside it is empty. Existing files
are never overwritten. A number is added when a name is already taken.

## Formats

AAC is the default. Mac MP3 output requires `lame` or `ffmpeg`; without an encoder,
JustRecorder captures AAC. Windows Apple Lossless requires `ffmpeg.exe` beside JustRecorder or
on PATH. Failed conversions retain the original WAV. Windows N editions may need
the Media Feature Pack for AAC and MP3.

## macOS build

```sh
./build.sh --universal   # Intel and Apple silicon
./build.sh --dmg         # Universal app in a disk image
./build.sh --install     # Build for this Mac, install, launch
./test.sh
./test.sh x86_64         # Requires Rosetta on Apple silicon
```

Requires Xcode Command Line Tools with Swift 5.9+. macOS 13 is the minimum runtime.
The default bundle is ad-hoc signed, not notarized. Rebuilding changes its identity
as seen by macOS privacy checks and may require renewed authorization. For stable
release signing, set `JUSTRECORDER_SIGN_IDENTITY` to your installed Developer ID
Application identity before building. Signing and notarization for public
release require the distributor's Apple Developer credentials.

## macOS advanced preferences

Quit JustRecorder before changing these values. Settings and credentials from an
older build are migrated automatically on first launch.

```sh
defaults write com.jing1ei.JustRecorder sampleRate -int 44100
defaults write com.jing1ei.JustRecorder mp3BitrateKbps -int 192
defaults write com.jing1ei.JustRecorder maxTitleLength -int 50
defaults write com.jing1ei.JustRecorder revealAfterSave -bool YES
defaults write com.jing1ei.JustRecorder showTimerInMenuBar -bool NO
defaults write com.jing1ei.JustRecorder aiTimeoutSeconds -float 15
```

Defaults: 48000 Hz, MP3 320 kbps, title limit 70, reveal off, menu timer on,
AI timeout 8 seconds.

## Recovery and diagnostics

Quit waits briefly for pending saves. On the next launch, readable interrupted
recordings are renamed `Recovered Snippet …`. Unreadable files are retained.
Keep the save folder available until a clip finishes saving.

Mac logs:

```sh
log stream --predicate 'subsystem == "com.jing1ei.JustRecorder"' --level info
```

Windows settings and logs: `%LOCALAPPDATA%\JustRecorder` (older builds used
`%LOCALAPPDATA%\Riff`; settings are moved over on first launch).
See the [Windows guide](../Windows/README.md) for build and runtime checks.

Metadata queries run in a bounded `osascript` process. Player Automation consent
and metadata availability are separate from system-audio capture permission. If a
player does not answer, naming falls back to the window title.
