# Releasing DefiBar with Sparkle

Use the same DefiBar EdDSA key for every release. Sparkle verifies the signed appcast and ZIP using the public key embedded in the app. The macOS app bundle uses ad-hoc code signing.

Generate the release key once on the signing Mac. Sparkle stores the private key in the login keychain. Keep a secure backup of the key.

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account DefiBar
```

Build the release with a new version and a build number higher than the previous release. The script reads the existing key and produces a universal ZIP and a signed appcast.

```sh
./build-release.sh 0.5.0 5
```

Attach both files from `.build/releases/v0.5.0/` to the stable GitHub release with the matching tag `v0.5.0`. Publish them together as the latest release. Installed apps read `releases/latest/download/appcast.xml`, and the appcast points to the ZIP under the versioned release URL. Both files must be accessible over HTTPS without signing in. Keep the filenames and signed files as generated.

Users upgrading from v0.4.0 or earlier need to install the first Sparkle-enabled app manually. A regular `./build-app.sh` build has no update feed or key by default.
