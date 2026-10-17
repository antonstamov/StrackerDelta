# Changelog

Every version says here what changed for the person using the app. The section for
a version is what the release page shows under the install steps, so it is written
and reviewed before the tag is made, like any other change.

Format follows [Keep a Changelog](https://keepachangelog.com/), sections are `Added`,
`Changed` and `Fixed`.

## [0.1.1] - 2026-10-17

### Added

- Field hints: every field in the lap list window explains itself while the mouse is
  over it, and the `?` button in the toolbar turns them on. They are off until you
  ask for them, and the choice is remembered.
- The install steps are at the top of the README, and on the release page of every
  version, naming the archive to download and where it has to end up.

### Changed

- "This track" asks for every car the site knows in one request, instead of fourteen
  batched queries. The list of cars is several kilobytes long and the game refuses to
  send a url that long, so the query goes out as a `POST` and the list travels in the
  body; the site reads a form body the way it reads a query string, and the answer is
  the same list.
- The address field refuses a link to a page of the site instead of taking it for an
  address and failing later with a number nobody could read.
- An address that does not answer as a stracker site says so in words, and the timer
  stops asking it every minute. The `Refresh` button asks at once.
- The Details button is sized by the game, so its frame is not cut off along the
  bottom edge any more, and its label is a word rather than a character the game
  cannot draw.
- One profile file next to the app instead of two copies of the same numbers.

### Fixed

- Errors the game hands over in the system code page are named in words, with the
  code they carry, on the list, on a single lap and on the statistics branch.
- The status dot, the rule in Details and the row backgrounds no longer draw as
  artefacts, and the zebra of the table is lighter.

## [0.1.0] - 2026-10-14

First public version: live lap delta against a stracker lap, the lap list window with
the whole stracker table, filter, auto refresh and diagnostics, the small delta window
for the HUD, addresses configured in the app and a profile cache on disk.
