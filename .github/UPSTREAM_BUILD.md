# Following upstream macOS builds

The scheduled release workflow resolves the latest stable qBittorrent tag and
reads `.github/workflows/ci_macos.yaml` **from that same tag**. It turns upstream's
`ci` job into a temporary composite action for that run. No generated workflow
is committed and no separate workflow-writing token is needed.

The complete upstream matrix (including include/exclude), runner, environment,
dependency actions, build commands, tests, deployment, DMG packaging, and artifact
upload are inherited. This includes upstream's OpenSSL 3 selection for 5.3.0.
Dependency and compiler settings are not maintained in this fork.

The wrapper checks out the exact upstream source tag and verifies its version.
The adapter replaces only the ad hoc signing block between `# code signing` and
`# create .dmg` with `.github/scripts/notarize.sh`. That script imports the existing
Apple certificate, performs Developer ID signing, submits the app to Apple, and
staples the ticket before upstream's original DMG creation and artifact upload.
The existing signing-time framework repairs are retained. Credentials are exposed
only to the packaging step and the temporary keychain is deleted afterward.

Release discovery, duplicate-release checks, naming, and publishing stay in the
wrapper. All matrix builds must succeed before publication. The existing seven
Apple signing/notarization secrets are used; no new secrets are required.

Public release titles use `qBittorrent vVERSION (Notarized)`. DMGs follow upstream's
short names with an explicit notarization label: `qbittorrent-VERSION_notarized.dmg`
for libtorrent 1.2, `_lt20_notarized.dmg` for 2.0, and `_lt21_notarized.dmg` for 2.1.
Headless builds use the `qbittorrent-nox` prefix. Extra Qt or libtorrent patch
variants receive a version suffix so assets cannot overwrite one another.
Only the published filenames change; upstream's build and packaging stay intact.

Normal upstream version, dependency, action, build-flag, test, and packaging-command
changes are picked up on the next release automatically. If upstream fundamentally
restructures the job, changes checkout requirements, or removes the signing/DMG
boundaries, the adapter fails explicitly rather than dropping unknown behavior or
publishing an unnotarized build. Such structural changes can still need maintenance.

`ruby .github/tests/prepare_upstream_test.rb` checks real upstream 5.2.0 and 5.3.0
workflow snapshots and simulated future changes. The snapshots are regression
fixtures only; releases always fetch the live workflow at their selected tag.
The validation workflow runs these checks on pull requests without Apple secrets.
A full signed release must still be validated on GitHub's macOS runners.
