# JustRecorder for Windows

![JustRecorder app icon](JustRecorder.png)

Extract the ZIP and run `JustRecorder.exe`. **Ctrl+Alt+R** starts and stops recording. Right-click the notification-area icon for recording actions or double-click for Settings.

Capture follows the default playback device using WASAPI loopback. Changing outputs ends the current clip. Exclusive-mode or protected playback may be unavailable. The app omits start sounds and suppresses stop sounds while pre-roll is enabled to keep its cues out of clips.

Settings apply with **Save**, **Done**, or when closing the window. **Discard unsaved edits** closes it without saving. Settings and logs live under `%LOCALAPPDATA%\JustRecorder`.

## Build

From the repository's `Windows` directory, use PowerShell with the .NET 10 SDK.

```powershell
./build.ps1                     # x64
./build.ps1 -Runtime win-arm64
./build.ps1 -Runtime win-x86
```

ZIPs in `build/windows` at the repository root include the .NET runtime and the [NAudio notice](NAudio-LICENSE.txt). On x64 Windows, packaging runs synthetic encoder checks for x64 and x86. Actual capture and device switching require a live Windows audio endpoint.

## Encoders and recovery

AAC and MP3 use Media Foundation. Windows N editions may need the Media Feature Pack. For Apple Lossless, install `ffmpeg.exe` beside the app or on PATH.

Capture writes a float WAV before encoding. On conversion failure the WAV is saved as the final clip. At startup, JustRecorder attempts to recover interrupted recordings in the current save folder.
