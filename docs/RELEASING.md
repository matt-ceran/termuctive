# Releasing Termuctive

Termuctive releases are distributed outside the Mac App Store as a universal Developer ID-signed and Apple-notarized DMG.
The GitHub workflow refuses to publish a build unless signing, notarization, both CPU architectures, the macOS deployment target, and Gatekeeper assessment all pass.

## Apple prerequisites

The maintainer needs an active paid Apple Developer Program membership.
A free Personal Team can create Apple Development certificates, but Apple does not issue Developer ID Application certificates to a Personal Team.

Create a Developer ID Application certificate and export the certificate plus its private key from Keychain Access as a password-protected PKCS #12 file.
Create an App Store Connect API key that is authorized to use Apple's notary service, and download its `.p8` private key once.

## GitHub release environment

Create a GitHub Actions environment named `release`.
Require the repository owner to approve deployments to that environment so an unexpected tag cannot immediately access signing credentials.

Configure these environment secrets:

- `MACOS_CERTIFICATE_P12_BASE64` contains the base64-encoded PKCS #12 file.
- `MACOS_CERTIFICATE_PASSWORD` contains the PKCS #12 export password.
- `APPLE_NOTARY_KEY_P8_BASE64` contains the base64-encoded App Store Connect `.p8` file.
- `APPLE_NOTARY_KEY_ID` contains the API key identifier.
- `APPLE_NOTARY_ISSUER_ID` contains the App Store Connect issuer identifier.

Encode files without writing their contents to the terminal:

```sh
base64 -i DeveloperIDApplication.p12 | gh secret set --env release MACOS_CERTIFICATE_P12_BASE64
base64 -i AuthKey_KEYID.p8 | gh secret set --env release APPLE_NOTARY_KEY_P8_BASE64
gh secret set --env release MACOS_CERTIFICATE_PASSWORD
gh secret set --env release APPLE_NOTARY_KEY_ID
gh secret set --env release APPLE_NOTARY_ISSUER_ID
```

Never commit the certificate, private key, passwords, or encoded values.

## Publish

Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, regenerate the Xcode project, and complete local verification.
Commit and push the version change before creating the tag.

Create and push a tag that exactly matches `v<MARKETING_VERSION>`:

```sh
git tag -s v0.1.0 -m "Termuctive 0.1.0"
git push origin v0.1.0
```

The `Release` workflow imports the temporary signing identity, builds a universal app, enables hardened runtime, requests a secure timestamp, notarizes and staples the app, creates and notarizes the DMG, verifies Gatekeeper, and publishes the DMG plus its SHA-256 checksum.
The workflow creates the GitHub Release as a draft and makes it public only after all release checks succeed.

## Local packaging

The same packaging path can run locally with a Developer ID Application identity and a `notarytool` keychain profile:

```sh
TERMUCTIVE_CODE_SIGN_IDENTITY="Developer ID Application: Example (TEAMID)" \
TERMUCTIVE_NOTARY_KEYCHAIN_PROFILE="termuctive-notary" \
TERMUCTIVE_RELEASE_TAG="v0.1.0" \
./Scripts/package-release.sh
```

Do not distribute output from `build-local.sh` or `install-local.sh`.
Those scripts use an ad hoc signature only for a source checkout on the same Mac.
