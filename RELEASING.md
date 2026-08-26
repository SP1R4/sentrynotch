# Releasing Sentry Notch

A signed, notarized release that installs cleanly on any Mac (no Gatekeeper
override) and can be published to a Homebrew tap.

## One-time setup (yours to provision)

Signing and notarization require an **Apple Developer Program** membership —
these credentials live only on your machine:

1. A **Developer ID Application** certificate in your login keychain:
   ```sh
   security find-identity -v -p codesigning   # should list "Developer ID Application: …"
   ```
2. A **notarytool** keychain profile (Apple ID + app-specific password + team id):
   ```sh
   xcrun notarytool store-credentials sentrynotch-notary \
     --apple-id you@example.com --team-id TEAMID --password <app-specific>
   ```
   (App-specific password: appleid.apple.com → Sign-In and Security.)

Without a Developer ID you can still cut an **unsigned beta** with
`ALLOW_UNSIGNED=1 VERSION=x.y.z ./release.sh`, but Gatekeeper will block it on
every Mac but yours — not fit for the cask.

## Cutting a release

```sh
VERSION=1.2.3 ./release.sh              # test → build → sign → notarize → staple → dist/SentryNotch-1.2.3.dmg
VERSION=1.2.3 ./tools/update-cask.sh    # rewrite Casks/sentry-notch.rb version + sha256 from the DMG
```

Then:

3. Create a GitHub release tagged `v1.2.3` and attach `dist/SentryNotch-1.2.3.dmg`.
   The cask's `url` is derived from the version, so the download path is
   `…/releases/download/v1.2.3/SentryNotch-1.2.3.dmg` — match it exactly.
4. Commit the updated `Casks/sentry-notch.rb`.
5. Verify on a **clean Mac** before announcing:
   ```sh
   spctl --assess --type open --context context:primary-signature -v dist/SentryNotch-1.2.3.dmg
   ```

## Publishing the cask (Homebrew tap)

A tap is just a repo named `homebrew-tap`. Once, create `SP1R4/homebrew-tap`
with a top-level `Casks/` directory. On each release, copy this repo's
`Casks/sentry-notch.rb` there (or point the tap at it). Users then install with:

```sh
brew install --cask SP1R4/tap/sentry-notch
```

`brew audit --cask sentry-notch` before pushing catches URL/sha/stanza mistakes.

## Notes

- CI notarization is deliberately **not** wired up: it needs the signing cert in
  the runner keychain and burns macOS Actions minutes at ~10× Ubuntu. Releasing
  from your own Mac is cheaper and keeps the private key off CI.
- `release.sh` runs the test suite and the upgrade test first, before it ever
  touches the certificate, so a broken build fails fast on any machine.
