# Changelog

All notable changes to the Studio Activity Logger are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

A release that changes the collector requires redeploying `collector/Code.gs`
as a new version before the plugin is distributed.

## [Unreleased]

## [1.3.0] - 2026-09-15

### Added

- Installers for Windows and macOS. They ask for the collector address, prove it against the collector before touching the disk, verify the download against a published checksum, write the plugin where Studio loads it, remove older copies under other names, and register the machine in the sheet before Studio has ever been opened.
- `installed` event, sent by the installer under a `userId` of `install:<machine name>`. The gap between the team roster and the `Heartbeat` tab is now the list of people who have not installed.
- `Config` tab in the sheet, holding the settings a supervisor changes without anyone rebuilding or redeploying: `minVersion`, `announcement` and `enabled`. It is created with documented defaults the first time a machine asks for it.
- Version gate. A plugin older than `minVersion` shows a red panel telling the developer to reinstall, and keeps recording.
- Delivery hold. Setting `enabled` to `FALSE` holds delivery on every machine while recording continues; queued activity goes out when it is `TRUE` again. A held machine still reports that it is alive, so the silence alert does not fire for a pause that was asked for.
- `loggingPaused` and `loggingResumed` events, so a hold has both ends marked in `Events`.
- A collector address can be entered in the status panel whenever it is red. The entry survives until an installer run changes the address underneath it, so a correction sticks and a reinstall is never overruled by something typed months earlier.
- The panel shows the installed version and the supervisor's announcement.
- `build.py` writes a `.sha256` beside the plugin. The installers refuse a file they cannot verify.

### Fixed

- A batch the collector could not be asked about was treated as delivered and dropped from the queue. Only the collector saying it holds a batch counts as delivery now; anything unconfirmed stays queued and is retried under the same identity. A spreadsheet collector rejects a run of requests often enough that this quietly discarded whole sessions.
- Any failed status from a spreadsheet collector now leads to that question being asked, rather than one particular status. The refusal code is not the same on every deployment, and the wrong guess turned a stored batch into an endless retry.
- Values that read as dates, such as a version, are neutralised before they reach a cell. `1.3.0` was stored as 1 March 2000.
- The installers detect Studio under the name it actually runs as, so the check is no longer skipped on a running Studio.
- Instances the session owns rather than the user, currently `Camera` and `Terrain`, are no longer reported as created and deleted.
- `Rotation` is treated as derived. Dragging a part reported it alongside `Orientation`, which is the same change said twice.

### Changed

- `COLLECTOR_URL` and `SHARED_TOKEN` stay as placeholders in the source and are written per machine by the installer, so no released file carries the token.
- Releases are published as GitHub releases and installed from `releases/latest/download`, rather than passed around as files.

## [1.2.0] - 2026-09-15

### Added

- `sessionStart` and `sessionEnd` events. Both carry the plugin version in `target`, so the sheet shows which build each machine ran and how long its session lasted. The collector already described them; nothing produced them.
- The collector answers `GET` with a batch id, reporting whether that batch is stored. A write is answered over a redirect the plugin cannot read, so delivery is now confirmed by asking rather than assumed from the refusal.
- A rejected `SHARED_TOKEN` reaches the plugin as a delivery failure and turns the panel red, instead of passing for success.
- `Heartbeat` gains a `version` column and a `conflicts` column. A conflict is one person reporting from two live sessions, or one session reporting under two people; neither happens while people work normally. The supervisor is emailed at most once an hour per person.
- `Config.TICK_INTERVAL_SECONDS` (default `1`): how often folded activity is released.
- `Config.SNAPSHOT_PROPERTIES`: the properties read when an instance comes under watch, so the first change to one of them can report what it was before.

### Changed

- Folding windows are released on their own cadence instead of the delivery cadence. Every `*_COALESCE_SECONDS` setting now means what it says.
- Cross-machine fingerprints bucket time to 30 seconds rather than 5, so two machines reporting one change still group together when their clocks disagree.
- A plugin built before this release keeps working against a collector deployed before it: an answer the collector cannot give is taken the old way, as delivery.

### Fixed

- The collector marked a batch stored before writing it. A write that failed after that point left the batch remembered as stored, so the retry was dismissed as a duplicate and the batch was lost. It is marked only once the rows are in the sheet.
- Undelivered activity is written to disk before the closing delivery is attempted, not after. A shutdown during that delivery no longer takes the queue with it.
- The batch being delivered is kept across sessions alongside the queue. A batch that reached the collector and lost its reply is retried under the identity it already had, instead of being stored a second time under a new one.
- Events discarded from a full queue no longer leave the batch identity pointing at a set of events that no longer exists, which had the collector dismiss the replacement batch unread.
- The first change to a watched property reports the value it had before, for the properties people edit. It reported `<unknown>` for every property's first change.
- Activity that cannot be kept for the next session is reported instead of being dropped in silence.

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

[Unreleased]: https://github.com/andrian-syh/roblox-activity-logger/compare/v1.3.0...HEAD
[1.3.0]: https://github.com/andrian-syh/roblox-activity-logger/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/andrian-syh/roblox-activity-logger/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/andrian-syh/roblox-activity-logger/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/andrian-syh/roblox-activity-logger/releases/tag/v1.0.0
