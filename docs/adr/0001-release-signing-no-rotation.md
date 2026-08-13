# Release signing: self-signed key, no rotation

The Android companion ships outside app stores via GitHub Releases. Release APKs are signed with a single self-signed keystore, held in GitHub Actions secrets with an offline encrypted backup as the source of truth. We deliberately choose **no key rotation**: Android rejects any update signed by a different key, so rotating the key would force every installed user to uninstall and reinstall. The consequence — losing the key means every existing install can no longer be updated — is accepted and documented, since a sideloaded app has no recoverable alternative.

## Consequences

- Protect, don't rotate: the key is treated as immutable infrastructure. Rotation is off the table, not a recovery path.
- Key loss is a release-ending event for all current installs (they must uninstall + reinstall). This is why an offline encrypted backup, not just the CI secret, is the source of truth.
