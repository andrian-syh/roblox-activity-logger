# Studio Activity Logger

Internal tool. A Roblox Studio plugin that records what each developer does while editing and sends it to one shared Google Sheet, so any change can be traced back to the machine and person that made it.

Version 1.4.0. See [CHANGELOG.md](CHANGELOG.md).

- [Developers: install](#developers-install)
- [Supervisors: read the sheet](#supervisors-read-the-sheet)
- [What is recorded](#what-is-recorded)
- [Limitations](#limitations)
- [Maintainers: set up and release](#maintainers-set-up-and-release)
- [Troubleshooting](#troubleshooting)
- [Privacy and security](#privacy-and-security)

```
Roblox Studio (each machine)          Google Apps Script          Google Sheet
+--------------------------+  HTTPS   +--------------------+      +----------------+
| watchers -> queue -> send| -------> | check token        | ---> | Events         |
| status panel             | batches  | drop duplicates    |      | Heartbeat      |
+--------------------------+          | write rows         |      | Daily, Gaps    |
                                      | alert rules -------+----> | alert email    |
                                      +--------------------+      +----------------+
```

Each machine records only its own user. Events are queued, sent in batches, retried on failure, and kept across Studio restarts. Every event is numbered within its session, so anything lost or removed from the sheet later is found.

---

## Developers: install

Required on every work machine. Close Studio first.

**Windows** (PowerShell):

```powershell
irm https://raw.githubusercontent.com/andrian-syh/roblox-activity-logger/main/install/install.ps1 | iex
```

**macOS** (Terminal). Run it exactly like this; piping into `bash` breaks the prompts:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/andrian-syh/roblox-activity-logger/main/install/install.sh)"
```

Enter the collector URL and shared token from your PM. The installer checks both against the collector before installing. Run the same command again to update.

Open Studio. The **Studio Activity Logger** panel should show `Recording` in green.

| Panel item | Shows |
|---|---|
| Status | `Recording` (green), `Paused` (amber, delivery held by the supervisor), `Not delivering` or `Stopped` (red) |
| Version | Installed version. Marked ⚠️ when older than the required minimum |
| Last Sync | When activity last reached the sheet |
| Queue | Events waiting to be sent. Marked ⚠️ if any were lost |
| Studio | The studio name, when the build sets one |
| Problem | Appears only when something is wrong: the reason, what to do, and fields for a new URL and token |
| Announcement | The supervisor's message |
| Activity on this machine | Everything recorded from you this session, newest first, up to 1000 |

The panel opens by itself when something is wrong. Do not disable or remove the plugin: a silent machine is reported.

---

## Supervisors: read the sheet

| Tab | Contents |
|---|---|
| `Events` | One row per recorded activity. Append only |
| `Heartbeat` | One row per person: last report, plugin version, contradicting reports |
| `Config` | Settings you control |
| `Rules` | Which alerts are emailed, and when |
| `Daily` | One row per person per day, rebuilt every night |
| `Gaps` | Numbered events found missing |

Restrict edit access on the spreadsheet to supervisors. Anyone who can edit it can alter the evidence.

### `Config`

Machines pick up changes within about two minutes. No rebuild or reinstall.

| `key` | Effect |
|---|---|
| `minVersion` | Older plugins show a warning asking the developer to reinstall. They keep recording. Blank turns the check off |
| `announcement` | Message shown in every panel |
| `enabled` | `FALSE` holds delivery on every machine. Recording continues and catches up when set back to `TRUE` |
| `alertEmail` | Where alerts go. Separate several addresses with commas. Blank sends nothing |
| `retentionDays` | Events older than this move to a monthly archive spreadsheet in the script owner's Drive. Default `180`. Blank or `0` keeps everything |

### `Rules`

Change `enabled` and the numbers. Leave `rule` as it is. Changes apply within a minute.

| `rule` | Emails when |
|---|---|
| `massDelete` | One person deletes at least `threshold` instances within `windowMinutes` |
| `bulkScriptWrite` | Many scripts are rewritten at once, typical of a sync tool or AI agent |
| `protectedPath` | Anything changes under a path in `scope`. Off by default |
| `silentMachine` | A machine has not reported for `windowMinutes`. Checked hourly |
| `conflict` | One person reports from two sessions at once, or one session under two people |
| `sequenceGap` | Events never arrived, or rows were removed from `Events`. Removal is checked nightly |
| `outdated` | A machine runs a plugin older than `minVersion`. Off by default |

`scope` takes comma-separated path prefixes, such as `ServerScriptService, Workspace.Map`; blank means everywhere. `cooldownMinutes` stops the same alert about the same person from repeating, up to 360.

### `Events` columns

Blank means not applicable.

| Column | Meaning |
|---|---|
| `receivedAt` / `eventAt` | When the collector stored it / when it happened |
| `userId` | Roblox user ID signed in to Studio |
| `sessionId` | One Studio session |
| `placeId` / `placeName` | The place being edited |
| `kind` | Event type, see [What is recorded](#what-is-recorded) |
| `summary` | The row as one sentence. **Start here** |
| `target` | Instance path, script path, or Studio's action name |
| `className` | Instance class |
| `confidence` | `authored`: started on this machine. `observed`: probably a collaborator's change |
| `origin` | Who made it: `user`, `assistant`, `tool`, `unattended` (software, nobody at the keyboard) or `collaborator` |
| `via` | Studio's change recording name, such as `Assistant 12` or `Rojo: Patch`. Often blank |
| `property`, `oldValue`, `newValue` | What changed, before and after |
| `amount` | Size: characters, instances or scripts |
| `location`, `preview` | Line range and start of typed text in a script edit |
| `fingerprint` | Shared by rows describing the same change from different machines |
| `seq` | Event number within the session |
| `mode` | Always `edit` |

**Finding who made a change:** filter `target` for the instance, sort by `fingerprint`, and take the row marked `authored` (earliest `eventAt` if several). Its `origin` says whether a person or software did it. `collaboratorJoined` rows show who else was online.

**Signs of a sync tool or AI agent:** `origin` of `assistant`, `tool` or `unattended`; any `bulkScriptWrite` row; `scriptSource` rows (code changed without typing).

### `Daily` and `Gaps`

`Daily` is built around 01:00 for the day before. `activeMinutes` counts time between events no more than 5 minutes apart. To rebuild a day, run `buildDaily('yyyy-MM-dd')` in the Apps Script editor.

In `Gaps`, `foundBy = arrival` means events never reached the collector. `foundBy = audit` means rows reached `Events` and were later removed.

---

## What is recorded

| `kind` | When |
|---|---|
| `installed` | The installer finished, under `userId` `install:<machine name>` |
| `sessionStart` / `sessionEnd` | The plugin loads or unloads |
| `loggingPaused` / `loggingResumed` | The supervisor holds or releases delivery |
| `added` / `removed` | An instance is created or deleted. A model with contents is one row, `amount` counts what is inside |
| `moved` | An instance changes parent, by drag or cut and paste |
| `restored` | A deleted instance comes back, for example by undo |
| `property` / `attribute` | A property or attribute of a **selected** instance changes |
| `selection` | The selection changes |
| `action` | Studio commits a change, such as `Renaming Part to Door` |
| `undo` / `redo` | Undo or redo |
| `scriptOpen` / `scriptClose` | A script opens or closes in the editor |
| `scriptEdit` | Typing in a script, one row per burst |
| `scriptSource` | Script code changes without typing |
| `bulkScriptWrite` | Many scripts rewritten in a short time |
| `collaboratorJoined` / `collaboratorLeft` | Another person opens or leaves the place |

Deleting with Delete or Backspace is recorded at once. Other removals wait about 60 seconds, so a cut followed by a paste becomes one `moved` row.

Watched services: `Workspace`, `Lighting`, `ReplicatedFirst`, `ReplicatedStorage`, `ServerScriptService`, `ServerStorage`, `SoundService`, `StarterGui`, `StarterPack`, `StarterPlayer`, `Teams`, `TextChatService`. Script code is watched in every script; other properties only on the selection.

---

## Limitations

| Not covered | Workaround |
|---|---|
| Changes made while Studio is closed, including Open Cloud | Audit sync tools and API keys separately |
| Property changes on unselected instances | `action`, `added` and `removed` still record the edit |
| Naming which collaborator made an `observed` change | Compare `fingerprint` across machines and check `collaboratorJoined` |
| Telling Azul or Argon from other software | Shows as `origin = unattended` |
| CollectionService tag changes | None |
| Removing the plugin | `silentMachine` alert |
| Forged batches: the token sits in a readable plugin file | Contradictions are counted in `Heartbeat` and alerted |

---

## Maintainers: set up and release

### Deploy the collector

1. Create a Google Sheet, open **Extensions > Apps Script**, and paste [collector/Code.gs](collector/Code.gs).
2. Set `SHARED_TOKEN` to a random string. Optionally set `COMPANY_TAG`.
3. **Deploy > New deployment > Web app**, execute as **Me**, access **Anyone**. Copy the `/exec` URL.
4. Run `setup` in the editor and approve the permissions. It creates the tabs and the hourly and nightly triggers.
5. Fill `alertEmail` in `Config`, then run `testEmail`.

After editing `Code.gs`, redeploy with **Manage deployments > Edit > Version: New version**. Saving alone changes nothing live.

### Build

```bash
python build.py                                # into the local Studio plugins folder
python build.py dist/StudioActivityLogger.rbxmx
```

Close Studio before building into the plugins folder: replacing the file reloads the running plugin. `COLLECTOR_URL` and `SHARED_TOKEN` stay placeholders in source; the installer fills them in per machine. Other build settings live in [src/Config.luau](src/Config.luau).

### Release

1. Raise `Config.VERSION` and update `CHANGELOG.md`.
2. `python build.py dist/StudioActivityLogger.rbxmx`, which also writes the `.sha256`.
3. Test the build on one machine.
4. Publish a GitHub release with `StudioActivityLogger.rbxmx` and `StudioActivityLogger.rbxmx.sha256` attached. Installers always take the latest release.
5. Raise `minVersion` in `Config`, then watch `Heartbeat` for the new version.

### Extending

- **New watcher:** add a module to `src/Watchers/` exposing `Name` and `Start` (optionally `Tick`, `Stop`), list it in `src/Watchers/init.luau`, add its sentence to `summaryFor` in `Code.gs` and its line to `DESCRIBERS` in `src/StatusUi/Feed.luau`.
- **New panel tile or card:** add a module to `src/StatusUi/Cards/` exposing `Slot`, `Build` and optionally `Update`, and list it in `src/StatusUi/Cards/init.luau`.

---

## Troubleshooting

| Message | Fix |
|---|---|
| `request was rejected before it was sent` | Allow HTTP requests for the plugin in Manage Plugins |
| `HTTP 4xx` / `HTTP 5xx` | Wrong URL or collector down. Check the deployment |
| `collector refused the batch: bad token` | Enter the right token in the Problem card, or reinstall |
| `collector does not hold the batch` | Check the Apps Script execution log. The events stay queued |
| `...is still a placeholder...` | Run the installer |
| `Queue full, N events discarded` | Delivery has failed for a long time. Fix delivery first |
| `No watcher could start...` | Send the Output log to the maintainer |
| Installer: `Roblox Studio sedang berjalan` | Close Studio completely and run it again |
| Installer: `Checksum tidak cocok` | Run it again. Tell the maintainer if it repeats |
| Installer: `Collector tidak bisa dihubungi` | Apps Script is briefly unavailable. Wait a few minutes and retry |
| Panel green, no new rows | `Code.gs` was saved but not redeployed as a new version |
| No panel or toolbar button | Restart Studio. The file must sit directly in the `Plugins` folder |

A single failed delivery does not turn the panel red; two in a row do.

---

## Privacy and security

Tell the team what is collected before rollout. The panel itself shows each developer everything recorded about them.

**Collected:** Roblox user ID, place ID and name, instance paths and classes, property values before and after, script paths, edited line ranges, character counts, and the first 200 characters of typed text.

**Not collected:** usernames, full script source, screenshots, anything outside Roblox Studio.

**Security:**

- The shared token is readable by anyone with the plugin file. It keeps out noise, not a determined person.
- Values starting with `=`, `+`, `-` or `@` are neutralised so nothing can inject a formula into the sheet.
- `alertEmail` and the rules are never sent to plugins.
