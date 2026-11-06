# JustRecorder

![JustRecorder app icon](Resources/Brand/JustRecorder.png)

Record system audio with a shortcut. Press again to save a named clip. Capture needs no microphone or virtual audio driver.

| | macOS | Windows |
|---|---|---|
| Requirements | macOS 13+, Apple silicon or Intel | Windows 10 build 19041+ or Windows 11, x64, ARM64 or x86 |
| Shortcut | **⌥⌘R** | **Ctrl+Alt+R** |
| Controls | Menu bar waveform | Notification area, including hidden icons |
| Default save folder | Music → JustRecorder Captures | Music → JustRecorder Captures |

## Quick start

1. Get the ZIP for your system from [GitHub Releases](https://github.com/jing1ei/justrecorder/releases/latest).
2. On Mac, move `JustRecorder.app` to Applications and open it. On Windows, extract the entire ZIP and run `JustRecorder.exe`.
3. Play audio and start recording. If macOS prompts for screen or system audio access, grant it in System Settings, then quit and reopen JustRecorder.
4. Stop recording with the same shortcut. Use **Reveal last recording** or **Open save folder** from the app menu.

Release builds are ad-hoc signed on Mac and unsigned on Windows. macOS Gatekeeper or your organization’s policy may require approval.

## Settings

- **Capture** controls the shortcut, save folder, format, auto-stop and optional 5–30 second pre-roll. The default is AAC at 256 kbps, 48 kHz stereo, with a 10-minute limit. Pre-roll keeps capture active while idle.
- **Naming** previews filenames and tests source detection. See the [template tokens](docs/REFERENCE.md#naming).
- **AI naming** optionally sends text metadata and clip duration to the endpoint you configure. Audio stays on your computer. Keys are stored in Keychain or Windows Credential Manager.

AAC, MP3, Apple Lossless and 16/24-bit WAV are supported. Mac MP3 requires `lame` or `ffmpeg`. Windows Apple Lossless requires `ffmpeg.exe`. See the [format and recovery details](docs/REFERENCE.md#formats-and-recovery).

## Build and release

- [macOS build and diagnostics](docs/REFERENCE.md#macos-build)
- [Windows build and diagnostics](Windows/README.md)
- [GitHub Actions release process](.github/RELEASES.md)

Original project code is all rights reserved. Third-party notices accompany the relevant packages.
