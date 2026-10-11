# Releasing

Pushing a `vX.Y.Z` tag runs `.github/workflows/release.yml`.

1. The workflow checks that the tag matches `MARKETING_VERSION` and that the tagged commit is on `main`. It then runs both test suites.
2. It builds an arm64 Release app, signs it with the **Stillset Release** certificate and the hardened runtime, and publishes `Stillset-vX.Y.Z.zip`, its SHA-256 file, and the matching `Stillset-vX.Y.Z.dSYM.zip` to a GitHub release.
3. It opens a pull request in `qeude/homebrew-tap` that writes `Casks/stillset.rb` from `packaging/homebrew/stillset.rb`. Merge that pull request to publish the update.

A manual run from `main` builds and signs the app without publishing it.

## One-time setup

Every release must be signed with the same certificate. A new certificate changes the app's code-signing identity, so macOS treats updated builds as a different app.

1. Create the certificate and upload it to the `release` environment:

   ```sh
   ./script/setup_release_certificate.sh
   ```

   The script saves the `.p12`, its password, and the public certificate in `~/Stillset Release Certificate`. It adds the identity to your login keychain, then sets the `STILLSET_RELEASE_P12_BASE64` and `STILLSET_RELEASE_P12_PASSWORD` secrets and the `STILLSET_RELEASE_CERT_SHA1` variable. Rerun it on another Mac with the same folder to reuse the certificate.

2. Move that folder to your password manager or an offline backup, then delete the local copy. If you lose it, you can't sign updates with the same identity.
3. Create a [fine-grained token](https://github.com/settings/personal-access-tokens/new) limited to `qeude/homebrew-tap`, with **Contents** and **Pull requests** set to read and write. Store it as a secret, pasting it when prompted:

   ```sh
   gh secret set HOMEBREW_TAP_TOKEN --env release --repo qeude/Stillset
   ```

## Publish a version

1. Set `MARKETING_VERSION` and increment `CURRENT_PROJECT_VERSION` in `Stillset.xcodeproj`, then merge to `main`.
2. Tag the merge commit and push the tag:

   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```

To build and sign locally, run `./script/package_release.sh`. The archive is written to `dist/`.
