# [UNICTIVE] Studio Activity Logger

Internal tool. Records what each developer does in Roblox Studio and sends it to one shared Google Sheet, so a change nobody admits to can be traced back to a machine.

| | |
|---|---|
| **Version** | 1.3.0 (`Config.VERSION`). See [CHANGELOG.md](CHANGELOG.md) |
| **Runs on** | Roblox Studio, edit mode, every team machine |
| **Stores data in** | Google Sheet, via a Google Apps Script web app |
| **Audience** | Developers (install), supervisors and PMs (read the sheet), maintainers (build and change) |

The bracketed company tag is set by `Config.COMPANY_TAG`. It appears in the toolbar, the status panel title, Output warnings and the alert email.

---

## Contents

1. [How it works](#how-it-works)
2. [For developers: install](#for-developers-install)
3. [For supervisors: read the sheet](#for-supervisors-read-the-sheet)
4. [What is recorded](#what-is-recorded)
5. [Limitations](#limitations)
6. [For maintainers: set up and release](#for-maintainers-set-up-and-release)
7. [Troubleshooting](#troubleshooting)
8. [Privacy and security](#privacy-and-security)

---

## How it works

```
Roblox Studio (each machine)          Google Apps Script          Google Sheet
+--------------------------+  HTTPS   +--------------------+      +----------------+
| watchers -> queue -> send| -------> | check token        | ---> | Events         |
| status panel             | batches  | drop duplicates    |      | Heartbeat      |
+--------------------------+          | write rows         |      | alert email    |
                                      +--------------------+      +----------------+
```

- Each machine records **only its own user's** activity.
- Events are queued, sent in batches, and retried on failure. Undelivered events survive a Studio restart.
- The sheet merges every machine. Authorship is decided by comparing rows across machines.
- A machine that stops reporting shows in the `Heartbeat` tab and triggers an email.

---

## For developers: install

Installation is mandatory on every work machine. Close Studio first; the installer refuses to run while it is open.

**Windows**, in PowerShell:

```powershell
irm https://raw.githubusercontent.com/andrian-syh/roblox-activity-logger/main/install/install.ps1 | iex
```

**macOS**, in Terminal:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/andrian-syh/roblox-activity-logger/main/install/install.sh)"
```

Do not pipe the macOS script into `bash`. Piping takes over the input, and the prompts cannot be answered.

The installer asks for the collector URL and the shared token, both from your PM. It checks them against the collector before writing anything, so a typo fails immediately instead of producing a machine that never reports. Then open Studio and confirm the panel at the bottom is **green**.

Run the same command again to update. The address already installed is offered back as the default, so only Enter is needed.

| Panel | Meaning | Action |
|---|---|---|
| Green | Recording and delivering | None |
| Red | The panel states the reason. A wrong address can be corrected in the panel itself | See [Troubleshooting](#troubleshooting). Contact your PM if it stays red |

| Panel | Meaning | Action |
|---|---|---|
| Green | Recording and delivering | None |
| Red | Nothing is recorded or delivered. The panel states the reason | See [Troubleshooting](#troubleshooting). Contact your PM if it stays red |

The panel opens itself when it turns red. Do not disable or remove the plugin: a silent machine is reported to the supervisor.

---

## For supervisors: read the sheet

| Tab | Contents |
|---|---|
| `Events` | One row per recorded activity. Append only. Filter enabled on the header row |
| `Heartbeat` | One row per machine: when it last reported, which plugin version it runs, and how many of its batches contradicted what the sheet already knew |
| `Config` | The settings you control. Created with documented defaults the first time a machine asks for them |

### Settings in `Config`

Machines read this tab when they start and every few minutes after that. No rebuild, no redeploy, no developer involvement.

| `key` | Effect |
|---|---|
| `minVersion` | A plugin older than this shows a red panel telling the developer to reinstall. **It keeps recording**: a stale version reporting beats a blind machine. Blank turns the check off |
| `announcement` | One line shown in every plugin panel. Use it for maintenance notices |
| `enabled` | `FALSE` holds delivery on every machine. Recording continues and catches up when it is `TRUE` again |

Holding delivery is not the same as stopping the recording. Machines keep watching, keep queuing, and keep reporting that they are alive, so the silence alert does not fire for a pause you asked for. The pause and the release are both written to `Events`. A hold long enough to overflow a machine's queue discards its oldest events, and that loss is reported in the panel.

### Columns in `Events`

Every column means the same thing on every row. Blank means *not applicable*, never *missing*.

| Column | Meaning |
|---|---|
| `receivedAt` | When the collector stored the row |
| `eventAt` | When the activity happened on the machine |
| `userId` | Roblox user ID of the person signed in to Studio |
| `sessionId` | One Studio session. Changes on every restart |
| `placeId` / `placeName` | The place being edited |
| `mode` | Always `edit`. The plugin records nothing during a playtest, whose changes are discarded when it stops |
| `kind` | Event type. See [What is recorded](#what-is-recorded) |
| `summary` | The row as one readable sentence. **Start here** |
| `target` | Instance path, script path, or Studio's name for the action |
| `className` | Class of the instance |
| `confidence` | `authored` or `observed`. See below |
| `via` | Name of the change recording that was open, when there was one |
| `property` | Property or attribute name |
| `oldValue` / `newValue` | Value before and after |
| `amount` | Size of the change: characters, instances, or scripts |
| `location` | Line range of a script edit |
| `preview` | Start of the typed text |
| `fingerprint` | Short hash shared by rows that describe the same change |
| `origin` | Who or what made the change: `user`, `assistant`, `tool`, `unattended` or `collaborator`. See below |

### Who made a change

1. Filter `target` for the instance or script in question.
2. Sort by `fingerprint`. Rows with the same fingerprint describe one change, seen from different machines.
3. The author is the machine that reports it as **`authored`**. If several do, the earliest `eventAt` wins.
4. Read `origin` on that row to see whether a person or software made it.

| `confidence` | Meaning |
|---|---|
| `authored` | The change started on this machine |
| `observed` | No local activity nearby while collaborators were online. The change probably came from one of them |

| `origin` | Meaning |
|---|---|
| `user` | The person at this machine was active around the change: selecting, typing, undoing, or a Studio edit |
| `assistant` | Made inside a Studio Assistant recording (`via` starts with `Assistant`), including AI agents connected through Studio MCP |
| `tool` | Made inside a Rojo patch, or script code kept in step with a file by Studio's Script Sync |
| `unattended` | Nobody was active on this machine and no collaborator was online, so software on this machine made it: a sync tool without a recording (Azul, Argon), another plugin, or a script |
| `collaborator` | Nobody was active on this machine while collaborators were online |

`via` names the change recording when Studio provides one, for example `Assistant 12` or `Rojo: Patch 10:42:03`. It is often blank.

### Signs of a sync tool or AI agent

| Signal | Meaning |
|---|---|
| `origin` is `assistant`, `tool` or `unattended` | Software made the change, not the person at the machine |
| `bulkScriptWrite` row | Many different scripts rewritten within seconds. A person does not edit this way |
| `scriptSource` row | Code changed while nobody typed in that script |

### Collaborators online

`collaboratorJoined` and `collaboratorLeft` rows show who else was editing, by user ID, and how many were online. Use them to check who could have made an `observed` change.

### Silent machines

Every hour the collector checks `Heartbeat` and emails `ALERT_EMAIL` about machines silent for more than `SILENT_MINUTES` (default 120). Silence means Studio was closed, or the plugin was disabled, removed or blocked.

---

## What is recorded

| `kind` | Recorded when |
|---|---|
| `installed` | The installer finished on a machine. Sent before Studio has ever been opened, under a `userId` of `install:<machine name>` |
| `loggingPaused` / `loggingResumed` | The supervisor held or released delivery in the `Config` tab |
| `sessionStart` / `sessionEnd` | The plugin loads or unloads. `target` holds the plugin version that machine is running |
| `added` / `removed` | An instance is created or deleted. A folder or model with contents is one row; `amount` counts the nested instances. Past 50 rows in one operation, the rest are counted in a single extra row |
| `moved` | An instance, with its contents, changes parent across watched services, by drag or by cut and paste. `oldValue` and `newValue` hold the paths. `oldValue` shows only the service when the old path was never seen |
| `restored` | A removed instance comes back to the same place, for example by undo |
| `property` | A property of a **selected** instance changes |
| `attribute` | An attribute of a **selected** instance changes |
| `selection` | The user selects something |
| `action` | Studio commits a change, for example `Renaming Part to Door` |
| `undo` / `redo` | The user undoes or redoes an action |
| `scriptOpen` / `scriptClose` | A script opens or closes in the editor |
| `scriptEdit` | The user types in a script. One row per burst of typing |
| `scriptSource` | Script code changes without typing. One row per script per burst |
| `bulkScriptWrite` | Many different scripts are rewritten in a short window |
| `collaboratorJoined` / `collaboratorLeft` | Another person opens or leaves the place. `operation = present` marks people already editing when the plugin started |

A removal is written about 60 seconds late (`CUT_PASTE_WINDOW_SECONDS`). A paste within that window with the same name, class and contents turns the pair into one `moved` row instead of `removed` plus `added`.

Scope:

- **Services:** `Workspace`, `Lighting`, `ReplicatedFirst`, `ReplicatedStorage`, `ServerScriptService`, `ServerStorage`, `SoundService`, `StarterGui`, `StarterPack`, `StarterPlayer`, `Teams`, `TextChatService`. Studio's interface services are excluded: they create noise on every mouse movement.
- **Script code:** watched in every script, open or not.
- **Other properties:** watched on the selection and its descendants only, up to a cap.

---

## Limitations

| Not covered | Why | Mitigation |
|---|---|---|
| Activity while Studio is closed, including Open Cloud writes | The plugin runs only inside Studio | Audit sync tools and API keys separately |
| Property changes on unselected instances | Watching the whole tree makes Studio unusable | `action`, `added` and `removed` still record the change |
| Naming a collaborator as the author | No Studio API exposes it; a collaborator's change arrives with no recording or selection | Compare rows across machines by `fingerprint`, and check `collaboratorJoined` rows |
| A collaborator's change made while the local user is also active | Local activity within a few seconds credits nearby changes to this machine | Compare with the collaborator's own rows by `fingerprint` |
| Telling Azul or Argon apart from other software | Neither names its changes in a way a plugin can read | `origin = unattended` when working alone |
| What collaborators have selected | Studio draws their highlights itself; no API exposes them | None |
| Initial contents of a script created and filled in one step | The watcher attaches after the first write | The `added` row still records the creation |
| CollectionService tag changes | Needs a known tag list | Add one to `Config` if the team uses tags |
| Removal of the plugin | A plugin cannot protect itself | `Heartbeat` tab and alert email |
| Naming the machine behind a forged batch | The token ships inside a readable plugin file, so anyone holding it can post as anyone | The `conflicts` column counts batches that contradict the sheet, and the supervisor is emailed |

**Verified:** a Team Create collaborator's change reaches other machines as a plain add or remove, with no recording, undo or selection, so it is never taken for local activity on its own.

---

## For maintainers: set up and release

### 1. Deploy the collector

1. Create a Google Sheet. Open **Extensions > Apps Script**.
2. Replace the script with [collector/Code.gs](collector/Code.gs).
3. Set the constants at the top:

   | Constant | Value |
   |---|---|
   | `COMPANY_TAG` | Company tag for the alert email. Match the plugin |
   | `SHARED_TOKEN` | Random string. Match the plugin |
   | `ALERT_EMAIL` | Supervisor's email address |
   | `SILENT_MINUTES` | Minutes of silence before an alert. Default `120` |
   | `CONFLICT_MINUTES` | How close two sessions from one person must be to count as a contradiction. Default `5` |

4. **Deploy > New deployment > Web app.** Execute as **Me**, access **Anyone**. Copy the `/exec` URL.
5. **Triggers > Add trigger:** function `checkHeartbeats`, time-driven, hourly.

After any change to `Code.gs`, redeploy with **Manage deployments > Edit > Version: New version**. Saving alone does not update the live web app. Added columns extend the existing header and filter, so no tab has to be deleted.

A plugin from 1.2.0 onwards confirms each delivery by asking the collector whether the batch was stored. A collector deployed before 1.2.0 cannot answer, and the plugin then falls back to the earlier behaviour of treating the write as delivered. Redeploy the collector to get a red panel on a rejected token.

### 2. Configure the plugin

`COLLECTOR_URL` and `SHARED_TOKEN` stay as placeholders in the source. The installer writes them on each machine, so no released file carries the token. Everything else in [src/Config.luau](src/Config.luau) is a build-time setting.

| Key | Purpose |
|---|---|
| `COMPANY_TAG` | Company tag shown in brackets. Empty string hides it |
| `COLLECTOR_URL`, `SHARED_TOKEN` | Leave as placeholders. The installer fills them in per machine |
| `BOOTSTRAP_INTERVAL_SECONDS` | How often the `Config` tab is read again |
| `PAUSED_HEARTBEAT_SECONDS` | How often a machine whose delivery is held reports that it is alive |
| `VERSION` | Raise on every release. Sent with every batch |
| `WATCHED_SERVICES` | Services whose contents are recorded |
| `TICK_INTERVAL_SECONDS` | How often folded activity is released. Keep it below the shortest coalesce window |
| `FLUSH_INTERVAL_SECONDS`, `QUEUE_CAPACITY`, `BATCH_LIMIT` | Delivery cadence and limits |
| `*_COALESCE_SECONDS` | How long a burst is folded into one row |
| `MAX_WATCHED_DESCENDANTS` | Cap on instances watched under the selection |
| `SNAPSHOT_PROPERTIES` | Properties read when an instance comes under watch, so their first change knows its old value |
| `MAX_STRUCTURE_ROWS_PER_BURST` | Cap on `added` or `removed` rows from one operation. The rest share one counting row |

The plugin refuses to start, and shows red, when `COLLECTOR_URL` or `SHARED_TOKEN` is still a placeholder or the URL is not `https`. A developer can correct the address in the red panel itself; that entry survives until an installer run changes the address underneath it.

### 3. Build

No toolchain needed:

```bash
python build.py                  # writes %LOCALAPPDATA%\Roblox\Plugins\StudioActivityLogger.rbxmx
python build.py dist/out.rbxmx   # writes to another path
```

Rojo also works, with `default.project.json` and the versions pinned in `rokit.toml`:

```bash
rokit install
rojo build --plugin StudioActivityLogger.rbxm
```

### 4. Release

1. Raise `Config.VERSION`.
2. `python build.py dist/StudioActivityLogger.rbxmx`. A `.sha256` is written beside it; the installer refuses anything it cannot verify.
3. Install from that build on one machine and test: panel green, rows appear in the sheet.
4. Publish a GitHub release with **both** files attached, named exactly `StudioActivityLogger.rbxmx` and `StudioActivityLogger.rbxmx.sha256`. The installers read `releases/latest/download`, so the newest release is what everyone gets.
5. Raise `minVersion` in the `Config` tab. Machines still on the old build turn red and keep recording.
6. Post the repository link in the team chat. Check `Heartbeat` for a fresh `lastSeen` and the new `version` from every machine.

### Project layout

```
install/
  install.ps1          Windows installer: prompts, verifies, patches, registers
  install.sh           The same for macOS
src/
  init.server.luau     Entry point: config check, start-up, delivery loop
  Deployment.luau      Which collector address is in force, and the supervisor's settings
  Config.luau          Every setting
  Safe.luau            Catches and reports errors so one failure cannot stop logging
  Bin.luau             Owns connections for clean shutdown
  Coalescer.luau       Folds a burst of changes into one row
  Naming.luau          Instance paths and value formatting
  Authorship.luau      Decides authored or observed
  EventLog.luau        Builds every event in one shape
  Transport.luau       Queue, batching, retry, persistence
  StatusUi.luau        Status panel and toolbar button
  Watchers/
    init.luau          Starts, ticks and stops every watcher
    Presence.luau      Collaborators joining and leaving
    Structure.luau     Instances added, removed, moved, cut and pasted
    History.luau       Actions, undo and redo
    Editor.luau        Typing in the script editor
    ScriptSource.luau  Code changed without typing, bulk alarm
    Properties.luau    Properties, attributes, selection
collector/Code.gs      Apps Script collector
build.py               Builder
```

### Adding a watcher

1. Create a module in `src/Watchers/` exposing `Name` and `Start`, optionally `Tick` and `Stop`.
2. Record events with `EventLog.Write`. Wrap signal handlers with `Safe.Handler`.
3. Add the module to `WATCHERS` in `src/Watchers/init.luau`. Order matters: `Presence` starts first so origins are right from the first event, and `ScriptSource` depends on `Structure` and `Editor`.
4. For a new `kind`, add its sentence to `summaryFor` in `Code.gs`.

A watcher that fails to start is skipped and reported. The others keep running.

---

## Troubleshooting

Messages appear in the status panel and in Studio's Output window.

| Message | Cause | Fix |
|---|---|---|
| `request was rejected before it was sent` | HTTP permission not granted | Manage Plugins, allow both domains |
| `HTTP 4xx` / `HTTP 5xx` | Wrong URL or collector unavailable | Check `COLLECTOR_URL` and the deployment |
| `Plugin belum dikonfigurasi...` | `COLLECTOR_URL` or `SHARED_TOKEN` is a placeholder | Set both in `Config.luau` and rebuild |
| `COLLECTOR_URL harus memakai https...` | URL is not `https` | Use the `/exec` URL as copied |
| `Tidak ada watcher yang berhasil dijalankan...` | Every watcher failed to start | Send the Output log to the maintainer |
| `Queue penuh, N event terbuang` | Delivery failed long enough to overflow the queue. The oldest events are lost | Fix delivery first |
| `collector refused the batch: bad token` | The installed token does not match the collector | Correct it in the red panel, or run the installer again |
| `Roblox Studio sedang berjalan` | The installer will not replace a file Studio has open | Close Studio completely, then run it again |
| `Checksum tidak cocok` | The download was truncated, or the release files were replaced | Run it again. Tell the maintainer if it repeats |
| `Versi plugin usang` | Older than `minVersion` in the `Config` tab | Run the installer again. Recording continues meanwhile |
| `collector did not store the batch` | The collector was reached but wrote nothing | Check the Apps Script execution log |
| Panel green, no new rows | `Code.gs` deployed as a saved edit rather than a new version | Manage deployments, Edit, Version: New version |
| No toolbar button | File in a subfolder, or Studio not restarted | Move the file to the `Plugins` root and restart |

One failed delivery does not turn the panel red. The second consecutive failure does.

---

## Privacy and security

**Tell the team what is collected before rollout.** Monitoring people know about deters mistakes. Monitoring they discover later damages trust.

Collected:

- Roblox user ID, place ID and place name
- Instance paths, class names, and property values before and after a change
- Script paths, edited line ranges, character counts, and the **first 200 characters of typed text**

Not collected:

- Username or display name
- Full script source
- Screenshots, or anything outside Roblox Studio

Security:

- `SHARED_TOKEN` is readable by anyone with the plugin file. It filters noise. It is not authentication.
- The collector neutralises values starting with `=`, `+`, `-` or `@`, so an instance name cannot inject a formula into the sheet.
- The collector counts contradictions rather than preventing them: one person reporting from two live sessions, or one session reporting under two people. Both appear in `Heartbeat` and trigger an email. A shared token cannot prove who sent a batch, only that a batch disagrees with the rest.
- Restrict edit access on the spreadsheet to the supervisor. Anyone with edit access can alter the evidence.
