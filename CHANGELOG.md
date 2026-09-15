# Changelog

All notable changes to the Studio Activity Logger are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A release that changes the collector requires redeploying `collector/Code.gs`
as a new version before the plugin is distributed.

## [Unreleased]

## [1.1.0] - 2026-09-15

### Added

- `moved` event: an instance and its contents changing parent across watched services is one row, with the old path in `oldValue` and the new path in `newValue`.
- Cut and paste detection: a paste matching recently cut content is reported as `moved` with `operation = cutPaste`, instead of `removed` plus `added`.
- `restored` event: a removed instance returning to the same path, for example by undo.
- `Config.CUT_PASTE_WINDOW_SECONDS` (default `60`): how long a removal waits for a matching paste.
- `Config.MAX_STRUCTURE_ROWS_PER_BURST` (default `50`): cap on `added` or `removed` rows from one operation. The rest are counted in one extra row with `operation = burst`.
- Every event now carries its own `placeId`, `placeName`, `sessionId` and `userId`.
- Collector summaries for `moved`, `restored`, cut and paste, nested instance counts and burst overflow.
- `origin` column: `user`, `assistant`, `tool`, `unattended` or `collaborator`, decided from local activity, recording names and whether collaborators are online.
- `collaboratorJoined` and `collaboratorLeft` events, by user ID, including collaborators already editing when the plugin starts.
- `Config.KNOWN_RECORDINGS`: recording name prefixes that identify the Studio Assistant (`Assistant`) and Rojo (`Rojo:`).
- Script code kept in step with a file by Studio's Script Sync is credited to `tool`.
- The collector extends the header and filter of an existing `Events` tab when columns are added, so no tab has to be deleted.

### Changed

- Creating or deleting a folder or model with contents produces one row for the root, with `amount` counting the nested instances, instead of one row per instance.
- `removed` rows are written up to `CUT_PASTE_WINDOW_SECONDS` after the removal. `eventAt` still shows the original time.
- The collector reads place, session and user from each event, and falls back to the batch values for events from older builds.
- The `mode` column is always `edit`.
- `observed` now means no local activity while collaborators were online. With nobody else online, an unexplained change is `authored` with `origin = unattended`.
- A Rojo or Assistant recording no longer counts as the local user's own activity.

### Fixed

- Playtests no longer record activity. The plugin stays idle in Play, Run and test server sessions, whose changes are discarded when they stop.
- Playtest sessions no longer take over the pending queue saved by the editing session.
- Events left undelivered when switching places are no longer attributed to the place opened next.
- Dragging or resizing a selection no longer re-reads and re-renders every changed property each frame; a run's final value is read once when it is written.
- Selecting a model or folder with many descendants no longer walks and names the whole subtree.
- Scripts that leave the place release their code watch. Repeated sync, cut and paste, or undo no longer fill the watch cap and leave new scripts silently unwatched, and the cap now warns once when reached.
- Closing a script in the editor no longer fails with "Attempt to use a closed document"; `scriptClose` rows are recorded and pending typing is written on close.
- Events held for authorship upgrades are dropped once too old, instead of accumulating while nobody is active.
- Instances created or removed by a recording now carry that recording in `via` and its origin, even though Studio reports them just after the recording closes.
- The first batch of a session no longer carries Studio's placeholder place name (for example `Place1`); the published name is resolved before anything is sent.

## [1.0.0] - 2026-09-14

### Added

- Roblox Studio plugin that records the local user's edit activity and delivers it to a Google Apps Script collector.
- Watchers for:
  - instances added and removed;
  - change recordings, undo and redo;
  - script typing, and script code changed without typing;
  - properties, attributes and the selection.
- `bulkScriptWrite` alarm when many scripts are rewritten within a short window.
- `authored` / `observed` confidence verdict based on local activity around each event.
- Delivery queue with batching, retry with back-off, duplicate-safe batch IDs, and persistence across Studio sessions.
- Status panel that turns red and opens itself when recording or delivery fails.
- Configuration gate that refuses to run with placeholder credentials or a non-HTTPS collector URL.
- Company branding through `Config.COMPANY_TAG`.
- Google Sheet collector with `Events` and `Heartbeat` tabs, readable summaries, cross-machine fingerprints, formula injection protection, and an hourly silent-machine email alert.
- `build.py` to build the plugin without a Roblox toolchain.

[Unreleased]: https://github.com/andrian-syh/roblox-activity-logger/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/andrian-syh/roblox-activity-logger/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/andrian-syh/roblox-activity-logger/releases/tag/v1.0.0
