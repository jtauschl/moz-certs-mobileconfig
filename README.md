# moz-certs-mobileconfig

Keeps macOS and iOS devices up to date with Mozilla's trusted root certificates —
useful for systems that no longer receive Apple's own certificate updates.

The generator downloads Mozilla's CA bundle from [curl.se/ca/](https://curl.se/ca/),
builds a signed `.mobileconfig` profile, and skips regeneration if the bundle
hasn't changed (SHA-256 check against the existing profile).

## Usage

```bash
./generate.sh              # unsigned – no certificate required
./generate.sh --signed     # sign with Apple Developer cert from Keychain
./generate.sh --force      # skip SHA change check, always regenerate
```

Flags can be combined: `./generate.sh --signed --force`

The output is written to `dist/moz-certs.mobileconfig`. When signing,
the certificate is auto-detected from the Keychain; set `SIGNING_IDENTITY`
in `generate.sh` to use a specific one. Unsigned profiles install with a
"Not Verified" warning but are otherwise fully functional.

## Installation on macOS

Open `moz-certs.mobileconfig`. macOS will prompt to install the profile
under System Preferences / System Settings → Profiles.

## Installation on iOS

Open the URL to `moz-certs.mobileconfig` in Safari. iOS will prompt to install
the profile under Settings → General → VPN & Device Management.

## Requirements

- macOS with Xcode developer tools
- Python 3 + openssl (ship with macOS/Xcode)
- Internet access to curl.se
- Apple Developer certificate in Keychain — only required for `--signed`

## Configuration

The signing certificate is detected automatically from the Keychain.
To pin a specific certificate, set `SIGNING_IDENTITY` at the top of `generate.sh`.

## License

Scripts: [MIT](LICENSE)

Certificate data: sourced from [Mozilla NSS](https://wiki.mozilla.org/CA) via
[curl.se/ca/](https://curl.se/ca/), licensed under
[MPL 2.0](https://www.mozilla.org/en-US/MPL/2.0/).
