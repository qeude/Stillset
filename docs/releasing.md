# Releasing

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`.

1. The workflow checks that the tag matches `MARKETING_VERSION` and that the tagged commit is on `main`. It then runs both test suites.
2. It builds an arm64 Release app, signs it with the **Stillset Release** certificate and the hardened runtime, and publishes `Stillset-vX.Y.Z.zip`, its SHA-256 file, and the matching `Stillset-vX.Y.Z.dSYM.zip` to a GitHub release.
3. It opens a pull request in `qeude/homebrew-tap` that writes `Casks/stillset.rb` from `packaging/homebrew/stillset.rb`. Merge that pull request to publish the update.

A manual run from `main` builds and signs the app without publishing it.

## One-time setup

Every release must be signed with the same certificate. A new certificate changes the app's code-signing identity, so macOS treats updated builds as a different app.

1. Create the certificate in your login keychain:

   ```sh
   ./script/setup_release_certificate.sh
   ```

2. In Keychain Access, export the **Stillset Release** identity as a `.p12` file with a password. Store the file and password offline. If you lose them, you can't sign updates with the same identity.
3. In the repository settings, create an environment named `release`, then add these secrets:
   - `STILLSET_RELEASE_P12_BASE64`, set from `base64 -i Stillset-Release.p12`
   - `STILLSET_RELEASE_P12_PASSWORD`
   - `HOMEBREW_TAP_TOKEN`, a fine-grained token with contents and pull-request write access to `qeude/homebrew-tap`
4. Add the repository variable `STILLSET_RELEASE_CERT_SHA1`, set to the certificate fingerprint:

   ```sh
   security find-certificate -c 'Stillset Release' -p | openssl x509 -outform DER | shasum -a 1 | cut -d ' ' -f 1
   ```

## Publish a version

1. Set `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in `Stillset.xcodeproj`, then merge to `main`.
2. Tag the merge commit and push the tag:

   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```

To build and sign locally, run `./script/package_release.sh`. The archive is written to `dist/`.
