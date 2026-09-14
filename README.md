# [UNICTIVE] Studio Activity Logger

Internal tool. Records what each developer does in Roblox Studio and sends it to one shared Google Sheet, so a change nobody admits to can be traced back to a machine.

| | |
|---|---|
| **Version** | 1.0.0 (`Config.VERSION`) |
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

Installation is mandatory on every work machine.

1. Get `StudioActivityLogger.rbxmx` from your maintainer.
2. Copy it to `%LOCALAPPDATA%\Roblox\Plugins`. Put it in that folder directly, not in a subfolder. A nested plugin does not load.
3. Restart Studio.
4. Open **Plugins > Manage Plugins > Studio Activity Logger** and allow HTTP for **both** domains:
   - `script.google.com`
   - `script.googleusercontent.com`
5. Check the status panel at the bottom of Studio. It must be **green**.

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
| `Heartbeat` | One row per machine, showing when it last reported |

### Columns in `Events`

Every column means the same thing on every row. Blank means *not applicable*, never *missing*.

| Column | Meaning |
|---|---|
| `receivedAt` | When the collector stored the row |
| `eventAt` | When the activity happened on the machine |
| `userId` | Roblox user ID of the person signed in to Studio |
| `sessionId` | One Studio session. Changes on every restart |
| `placeId` / `placeName` | The place being edited |
| `mode` | `edit` or `run`. Filter out `run` to ignore playtests |
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

### Who made a change

1. Filter `target` for the instance or script in question.
2. Sort by `fingerprint`. Rows with the same fingerprint describe one change, seen from different machines.
3. The author is the machine that reports it as **`authored`**. If several do, the earliest `eventAt` wins.

| `confidence` | Meaning |
|---|---|
| `authored` | This machine had local activity around the event. The change started here |
| `observed` | No local activity nearby. The change probably came from a collaborator |

`via` names the tool when Studio provides a label, for example `Assistant 12` for the Studio AI assistant. It is often blank. Treat it as a hint, not proof.

### Signs of a sync tool or AI agent

| Signal | Meaning |
|---|---|
| `bulkScriptWrite` row | Many different scripts rewritten within seconds. A person does not edit this way |
| `scriptSource` row | Code changed while nobody typed in that script: Rojo, Argon, an AI agent, another plugin, or the command bar |
| `via` starts with `Assistant` | The Studio AI assistant made the change |

### Silent machines

Every hour the collector checks `Heartbeat` and emails `ALERT_EMAIL` about machines silent for more than `SILENT_MINUTES` (default 120). Silence means Studio was closed, or the plugin was disabled, removed or blocked.

---

## What is recorded

| `kind` | Recorded when |
|---|---|
| `sessionStart` / `sessionEnd` | The plugin loads or unloads |
| `added` / `removed` | An instance is created or deleted |
| `property` | A property of a **selected** instance changes |
| `attribute` | An attribute of a **selected** instance changes |
| `selection` | The user selects something |
| `action` | Studio commits a change, for example `Renaming Part to Door` |
| `undo` / `redo` | The user undoes or redoes an action |
| `scriptOpen` / `scriptClose` | A script opens or closes in the editor |
| `scriptEdit` | The user types in a script. One row per burst of typing |
| `scriptSource` | Script code changes without typing. One row per script per burst |
| `bulkScriptWrite` | Many different scripts are rewritten in a short window |

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
| Naming a collaborator as the author | No Studio API exposes it | Compare rows across machines by `fingerprint` |
| Initial contents of a script created and filled in one step | The watcher attaches after the first write | The `added` row still records the creation |
| CollectionService tag changes | Needs a known tag list | Add one to `Config` if the team uses tags |
| Removal of the plugin | A plugin cannot protect itself | `Heartbeat` tab and alert email |
| A wrong `SHARED_TOKEN` | Apps Script cannot return an error status the plugin can read, so the panel stays green | Confirm rows arrive after every release |

**Unverified:** whether a Team Create collaborator's change looks like local activity on other machines. If it does, `confidence` is less reliable and `fingerprint` becomes the main evidence.

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

4. **Deploy > New deployment > Web app.** Execute as **Me**, access **Anyone**. Copy the `/exec` URL.
5. **Triggers > Add trigger:** function `checkHeartbeats`, time-driven, hourly.

After any change to `Code.gs`, redeploy with **Manage deployments > Edit > Version: New version**. Saving alone does not update the live web app. If the columns changed, delete the `Events` and `Heartbeat` tabs; they are recreated with the new headers.

### 2. Configure the plugin

Edit [src/Config.luau](src/Config.luau).

| Key | Purpose |
|---|---|
| `COMPANY_TAG` | Company tag shown in brackets. Empty string hides it |
| `COLLECTOR_URL` | The `/exec` URL. Must be `https` |
| `SHARED_TOKEN` | Must match the collector |
| `VERSION` | Raise on every release. Sent with every batch |
| `WATCHED_SERVICES` | Services whose contents are recorded |
| `FLUSH_INTERVAL_SECONDS`, `QUEUE_CAPACITY`, `BATCH_LIMIT` | Delivery cadence and limits |
| `*_COALESCE_SECONDS` | How long a burst is folded into one row |
| `MAX_WATCHED_DESCENDANTS` | Cap on instances watched under the selection |

The plugin refuses to start, and shows red, when `COLLECTOR_URL` or `SHARED_TOKEN` is a placeholder or the URL is not `https`.

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
2. Build and test in one Studio: panel green, rows appear in the sheet.
3. Send the `.rbxmx` to the team with the [install steps](#for-developers-install).
4. Check `Heartbeat` for a fresh `lastSeen` from every machine.

### Project layout

```
src/
  init.server.luau     Entry point: config check, start-up, delivery loop
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
    Structure.luau     Instances added and removed
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
3. Add the module to `WATCHERS` in `src/Watchers/init.luau`. Order matters: `ScriptSource` depends on `Structure` and `Editor`.
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
| Panel green, no new rows | `SHARED_TOKEN` mismatch, or `Code.gs` not redeployed | Compare tokens. Deploy a new version |
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
- Restrict edit access on the spreadsheet to the supervisor. Anyone with edit access can alter the evidence.
