# Automatic releases

Pushes to `main` and manual Release runs on `main` build the universal macOS ZIP, Windows x64/x86/ARM64 ZIPs and the source ZIP. Pull requests run platform checks.

Once every build passes, the publisher stages the five ZIPs and `SHA256SUMS.txt` in the rolling **1.0.0** release. It verifies the uploaded assets, moves `v1.0.0` to the build commit and publishes. A failed upload leaves the release in draft. Rerun Release on current `main` to retry.
