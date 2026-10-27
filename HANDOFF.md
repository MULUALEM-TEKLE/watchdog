# Handoff

Updated: 2026-10-27 09:30, commit be1acfb+uncommitted, session release-cleanup

## Goal

Ship Watchdog (macOS menu-bar Wi-Fi usage monitor) as an open-source,
directly distributed app. The current nettop-based engine cannot run in the App
Sandbox, so Mac App Store distribution needs the re-architecture in
`docs/superpowers/plans/` (NEFilterDataProvider app extension, paid team,
Network Extension entitlement). That work is not started.

## In flight

- main / release-cleanup: repo hygiene, dead block UI removed, hardened
  runtime, deployment target 14.0, LICENSE, README. Next: commit, push.

## Blocked / waiting

- Notarized releases need a Developer ID certificate on the owner's own paid
  team. The machine has only an "Apple Development" and a third-party "Apple
  Distribution" identity.
- Repo is private. Making it public and the license choice (MIT assumed) are
  the owner's call.

## Decisions (last 2 weeks)

- 2026-10-27: Block checkbox and "Block network access" toggle removed from the
  UI. They wrote a list nothing read. Re-add when the filter extension exists
  (see BLOCKING.md step 5).
- 2026-10-27: Deployment target lowered from 26.5 to 14.0 (compiler availability
  checks pass). LSUIElement set in Info.plist instead of the runtime call.
- 2026-10-27: UI-test target deleted. Its template tests launched the app and
  would register the DerivedData build as a login item.

## Next

- Owner: decide open source vs. App Store (see session report).
- Owner: enroll own paid team for Developer ID, then add a notarize + release
  script and a GitHub Actions test workflow.
- Consider asking before auto-registering the login item on first run
  (App Store guideline 2.4.5 blocker; UX choice for direct distribution).
- Pick a reverse-DNS bundle ID before the first public release.

## Do not touch

- none
