# Handoff

Updated: 2026-10-27 10:00, commit (see git log), session release-cleanup

## Goal

Ship Watchdog (macOS menu-bar Wi-Fi usage monitor) as an open-source,
directly distributed app. The current nettop-based engine cannot run in the App
Sandbox, so Mac App Store distribution needs the re-architecture in
`docs/superpowers/plans/` (NEFilterDataProvider app extension, paid team,
Network Extension entitlement). That work is not started.

## In flight

- main / launch: repo is public (2026-10-27). Launch kit in `_/campaign/`
  (plan, press kit) and `_/social/2026-10-27-launch/` (hero images, post.md).
  Website live at https://watchdog.mulualem.com (repo `../watchdog.site`,
  Temps project 10, manual static deploy: push does not redeploy). Next:
  notarized release.

## Blocked / waiting

- Notarized releases need a Developer ID certificate on the owner's own paid
  team. The machine has only an "Apple Development" and a third-party "Apple
  Distribution" identity.
- GitHub social preview image must be uploaded by hand (Settings → Social
  preview): `_/social/2026-10-27-launch/og-1200x630.png`.

## Decisions (last 2 weeks)

- 2026-10-27: Block checkbox and "Block network access" toggle removed from the
  UI. They wrote a list nothing read. Re-add when the filter extension exists
  (see BLOCKING.md step 5).
- 2026-10-27: Deployment target lowered from 26.5 to 14.0 (compiler availability
  checks pass). LSUIElement set in Info.plist instead of the runtime call.
- 2026-10-27: UI-test target deleted. Its template tests launched the app and
  would register the DerivedData build as a login item.

## Next

- Owner: notarized release (Developer ID), then Show HN / Reddit / Product
  Hunt per `_/campaign/launch-campaign.md`.
- Owner: enroll own paid team for Developer ID, then add a notarize + release
  script and a GitHub Actions test workflow.
- Consider asking before auto-registering the login item on first run
  (App Store guideline 2.4.5 blocker; UX choice for direct distribution).
- Rename bundle ID to `com.mulualem.watchdog` before the first tagged release.

## Do not touch

- none
