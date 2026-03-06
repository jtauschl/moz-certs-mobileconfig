# moz-certs-mobileconfig

Keeps macOS and iOS devices up to date with Mozilla's trusted root certificates —
useful for systems that no longer receive Apple's own certificate updates.

The generator downloads Mozilla's CA bundle from [curl.se/ca/](https://curl.se/ca/),
builds a signed `.mobileconfig` profile, and skips regeneration if the bundle
hasn't changed (SHA-256 check against the existing profile).

## Usage

```bash
./generate.sh           # regenerate only if cacert.pem has changed
./generate.sh --force   # always regenerate
```

The script auto-detects an Apple Developer certificate from the Keychain,
signs `dist/moz-certs.mobileconfig`, and prints a summary.

## Installation on macOS

Open `moz-certs.mobileconfig`. macOS will prompt to install the profile
under System Preferences / System Settings → Profiles.

## Installation on iOS

Open the URL to `moz-certs.mobileconfig` in Safari. iOS will prompt to install
the profile under Settings → General → VPN & Device Management.

## Requirements

- macOS with Xcode developer tools
- Apple Developer certificate in Keychain (Developer ID Application or Apple Development)
- Python 3 + openssl (ship with macOS/Xcode)
- Internet access to curl.se

## Configuration

The signing certificate is detected automatically from the Keychain.
To pin a specific certificate, set `SIGNING_IDENTITY` at the top of `generate.sh`.

## License

Scripts: [MIT](LICENSE)

Certificate data: sourced from [Mozilla NSS](https://wiki.mozilla.org/CA) via
[curl.se/ca/](https://curl.se/ca/), licensed under
[MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/).
