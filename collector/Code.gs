/**
 * Collector for the Studio Activity Logger. Runs as a web app bound to one
 * spreadsheet; the deployment steps and the settings below are described in
 * README.md.
 *
 * Two sheets are maintained:
 *   Events    - one row per reported activity, append only
 *   Heartbeat - one row per machine, overwritten, so a machine that stops
 *               reporting is visible at a glance
 *
 * A batch is addressable after the fact, so a sender whose reply it could not
 * read can ask whether the batch landed and be told when it was refused.
 *
 * A third sheet, Config, holds the few settings a supervisor changes without
 * anyone rebuilding or redeploying anything. Machines read it when they start
 * and at intervals after that.
 *
 * Every column means the same thing for every event kind. The plugin sends
 * structured fields only; the readable sentence in the summary column is
 * composed here, so the wording can change without rebuilding and
 * redistributing the plugin.
 */

var COMPANY_TAG = 'UNICTIVE';
var SHARED_TOKEN = 'PASTE_SHARED_TOKEN_HERE';
var ALERT_EMAIL = 'PASTE_SUPERVISOR_EMAIL_HERE';
var SILENT_MINUTES = 120;

// Two sessions reporting for one person at once means one of them is forged,
// since a person edits from one Studio at a time.
var CONFLICT_MINUTES = 5;

var MAX_CELL_LENGTH = 500;
var BATCH_MEMORY_SECONDS = 21600;

var EVENT_HEADERS = [
  'receivedAt', 'eventAt', 'userId', 'sessionId', 'placeId', 'placeName',
  'mode', 'kind', 'summary', 'target', 'className', 'confidence', 'via',
  'property', 'oldValue', 'newValue', 'amount', 'location', 'preview',
  'fingerprint', 'origin'
];

var CONFIG_HEADERS = ['key', 'value', 'notes'];

var CONFIG_DEFAULTS = [
  ['minVersion', '', 'Plugins older than this show a red panel and keep recording. Blank turns the check off'],
  ['announcement', '', 'One line shown in every plugin panel. Blank shows nothing'],
  ['enabled', 'TRUE', 'FALSE holds delivery on every machine. Recording continues and catches up when it is TRUE again']
];

var HEARTBEAT_HEADERS = [
  'userId', 'sessionId', 'placeId', 'placeName', 'lastSeen', 'eventsReceived',
  'version', 'conflicts'
];

/**
 * Makes one value safe to write into a cell. Untrimmed text disfigures a row,
 * a name that opens like a formula is evaluated as one, and a version reads as
 * a date, unless each is neutralised here.
 */
function cell(value) {
  if (value === null || value === undefined || value === '') {
    return '';
  }
  if (typeof value === 'number') {
    return value;
  }
  var text = String(value).replace(/[\x00-\x1f\x7f]+/g, ' ').trim();
  if (text.length > MAX_CELL_LENGTH) {
    text = text.substring(0, MAX_CELL_LENGTH) + '...';
  }
  if (/^[=+\-@]/.test(text) || /^[0-9]+([.\-\/][0-9]+)+$/.test(text)) {
    text = "'" + text;
  }
  return text;
}

/**
 * Returns the last segment of an instance path, for summaries that would be
 * unreadable with the full path in them.
 */
function leafOf(path) {
  if (!path) {
    return '';
  }
  var parts = String(path).split('.');
  return parts[parts.length - 1];
}

/**
 * Composes the one-line description of an event. Falls back to the raw kind
 * for anything this does not know about, so a new event kind still lands in
 * the sheet rather than blanking the column.
 */
function summaryFor(event) {
  var leaf = leafOf(event.target);
  var amount = Number(event.amount || 0);

  switch (event.kind) {
    case 'installed':
      return 'Installed the plugin on this machine (version ' + (event.target || 'unknown') + ')';
    case 'loggingPaused':
      return 'Delivery held by the supervisor. Recording continues';
    case 'loggingResumed':
      return 'Delivery released by the supervisor';
    case 'sessionStart':
      return 'Opened the place in Studio';
    case 'sessionEnd':
      return 'Closed the place';
    case 'added':
    case 'removed':
      var verb = event.kind === 'added' ? 'Created ' : 'Deleted ';
      if (event.operation === 'burst') {
        return verb + amount + ' more instances in the same operation, starting with "' + leaf + '"';
      }
      return verb + (event.className || 'instance') + ' "' + leaf + '"' +
        (amount > 0 ? ' with ' + amount + ' nested instance' + (amount === 1 ? '' : 's') : '');
    case 'restored':
      return 'Restored ' + (event.className || 'instance') + ' "' + leaf + '" after removing it' +
        (amount > 0 ? ' with ' + amount + ' nested instance' + (amount === 1 ? '' : 's') : '');
    case 'moved':
      return (event.operation === 'cutPaste' ? 'Cut and pasted ' : 'Moved ') +
        (event.className || 'instance') + ' "' + leaf + '" from ' +
        (event.oldValue || 'unknown') + ' to ' + (event.newValue || 'unknown') +
        (amount > 0 ? ' with ' + amount + ' nested instance' + (amount === 1 ? '' : 's') : '');
    case 'selection':
      if (amount === 0) {
        return 'Cleared the selection';
      }
      return amount === 1 ? 'Selected "' + leaf + '"' : 'Selected ' + amount + ' instances';
    case 'property':
      var changed = String(event.property || '').split(', ');
      var leading = changed.shift();
      return 'Set ' + leading + ' on "' + leaf + '" from ' +
        (event.oldValue || 'unknown') + ' to ' + (event.newValue || 'unknown') +
        (changed.length > 0 ? ', and ' + changed.join(', ') : '');
    case 'attribute':
      return 'Set attribute ' + event.property + ' on "' + leaf + '" to ' + (event.newValue || '');
    case 'scriptEdit':
      return 'Typed ' + amount + ' characters into "' + leaf + '"' +
        (event.location ? ' at ' + event.location : '');
    case 'scriptSource':
      return 'Code in "' + leaf + '" was rewritten without anyone typing (' +
        (amount >= 0 ? '+' : '') + amount + ' characters)';
    case 'bulkScriptWrite':
      return 'WARNING: ' + amount + ' scripts rewritten at once, typical of a sync tool or an agent';
    case 'scriptOpen':
      return 'Opened "' + leaf + '" in the editor';
    case 'scriptClose':
      return 'Closed "' + leaf + '" in the editor';
    case 'action':
      return 'Studio recorded: ' + event.target;
    case 'undo':
      return 'Undid: ' + event.target;
    case 'redo':
      return 'Redid: ' + event.target;
    case 'collaboratorJoined':
      return 'Collaborator ' + event.target +
        (event.operation === 'present' ? ' was already editing' : ' joined') +
        ' (' + amount + ' other editor' + (amount === 1 ? '' : 's') + ' now)';
    case 'collaboratorLeft':
      return 'Collaborator ' + event.target + ' left (' + amount + ' other editor' + (amount === 1 ? '' : 's') + ' now)';
    default:
      return event.kind + (event.target ? ' on ' + event.target : '');
  }
}

/**
 * Builds a short key that is identical across machines for the same
 * underlying change, so replicated reports collapse into one group. Machines
 * disagree about the clock, so the time is coarsened before it is hashed.
 */
function fingerprintOf(event) {
  var bucket = Math.floor((event.epoch || 0) / 30);
  var seed = [event.kind, event.target, event.property || '', bucket].join('|');

  var hash = 0;
  for (var index = 0; index < seed.length; index++) {
    hash = (hash * 31 + seed.charCodeAt(index)) | 0;
  }
  return (hash >>> 0).toString(16);
}

/**
 * Returns a sheet with the given headers, creating it on first use. A tab made
 * by an older deployment with fewer columns gets its header and filter
 * extended, so new columns are labelled without deleting any rows.
 */
function getSheet(name, headers) {
  var book = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = book.getSheetByName(name);
  if (!sheet) {
    sheet = book.insertSheet(name);
    sheet.appendRow(headers);
    sheet.setFrozenRows(1);
    sheet.getRange(1, 1, 1, headers.length).setFontWeight('bold');
    sheet.getRange(1, 1, sheet.getMaxRows(), headers.length).createFilter();
  } else if (sheet.getLastColumn() < headers.length) {
    sheet.getRange(1, 1, 1, headers.length).setValues([headers]).setFontWeight('bold');
    var filter = sheet.getFilter();
    if (filter) {
      filter.remove();
    }
    sheet.getRange(1, 1, sheet.getMaxRows(), headers.length).createFilter();
  }
  return sheet;
}

/**
 * Reports whether this batch is already in the sheet. A delivery that fails
 * after the rows were written is retried under the same batch id, and without
 * this check the retry would duplicate every row.
 */
function alreadyStored(batchId) {
  if (!batchId) {
    return false;
  }
  return CacheService.getScriptCache().get('batch_' + batchId) === 'stored';
}

/**
 * Remembers that a batch reached the sheet. Called only once the rows are
 * written: marking it beforehand would turn a failed write into a batch the
 * plugin is told to stop retrying, losing it for good.
 */
function markStored(batchId) {
  if (!batchId) {
    return;
  }
  CacheService.getScriptCache().put('batch_' + batchId, 'stored', BATCH_MEMORY_SECONDS);
}

/**
 * Returns one JSON response.
 */
function json(payload) {
  return ContentService.createTextOutput(JSON.stringify(payload))
    .setMimeType(ContentService.MimeType.JSON);
}

/**
 * Reads the settings a supervisor controls, seeding the sheet with documented
 * defaults the first time it is asked for. Anything the sheet does not name
 * falls back to the default, so a deleted row cannot leave a machine without
 * an answer.
 */
function readConfig() {
  var sheet = getSheet('Config', CONFIG_HEADERS);

  if (sheet.getLastRow() < 2) {
    sheet.getRange(2, 1, CONFIG_DEFAULTS.length, CONFIG_HEADERS.length).setValues(CONFIG_DEFAULTS);
  }

  var settings = {};
  for (var index = 0; index < CONFIG_DEFAULTS.length; index++) {
    settings[CONFIG_DEFAULTS[index][0]] = CONFIG_DEFAULTS[index][1];
  }

  var values = sheet.getDataRange().getValues();
  for (var row = 1; row < values.length; row++) {
    var key = String(values[row][0]).trim();
    if (key) {
      settings[key] = values[row][1];
    }
  }
  return settings;
}

/**
 * Answers the plugin's questions: whether a batch it could not read the reply
 * to was stored, what the supervisor has set, or failing both, that the
 * collector is reachable and the token is accepted.
 */
function doGet(request) {
  var params = (request && request.parameter) || {};

  if (params.token !== SHARED_TOKEN) {
    return json({ ok: false, error: 'bad token' });
  }
  if (params.batchId) {
    return json({ ok: true, stored: alreadyStored(params.batchId) });
  }
  if (params.bootstrap) {
    var settings = readConfig();
    return json({
      ok: true,
      enabled: String(settings.enabled).toUpperCase() !== 'FALSE',
      minVersion: String(settings.minVersion || ''),
      announcement: String(settings.announcement || '')
    });
  }
  return json({ ok: true });
}

/**
 * Appends a batch of events and refreshes the sender's heartbeat row.
 */
function doPost(request) {
  var lock = LockService.getScriptLock();
  lock.waitLock(30000);
  try {
    var payload = JSON.parse(request.postData.contents);

    if (payload.token !== SHARED_TOKEN) {
      return json({ ok: false, error: 'bad token' });
    }

    if (alreadyStored(payload.batchId)) {
      return json({ ok: true, accepted: 0, duplicate: true });
    }

    var events = payload.events || [];
    var receivedAt = new Date();
    var rows = [];

    for (var index = 0; index < events.length; index++) {
      var event = events[index];
      var placeId = event.placeId === undefined ? payload.placeId : event.placeId;
      var samePlace = String(placeId) === String(payload.placeId);
      rows.push([
        receivedAt,
        event.epoch ? new Date(event.epoch * 1000) : '',
        cell(event.userId === undefined ? payload.userId : event.userId),
        cell(event.sessionId || payload.sessionId),
        cell(placeId),
        cell(samePlace ? payload.placeName : event.placeName),
        cell(event.mode),
        cell(event.kind),
        cell(summaryFor(event)),
        cell(event.target),
        cell(event.className),
        cell(event.confidence),
        cell(event.via),
        cell(event.property),
        cell(event.oldValue),
        cell(event.newValue),
        event.amount === undefined || event.amount === null ? '' : Number(event.amount),
        cell(event.location),
        cell(event.preview),
        cell(fingerprintOf(event)),
        cell(event.origin)
      ]);
    }

    if (rows.length > 0) {
      var eventSheet = getSheet('Events', EVENT_HEADERS);
      eventSheet.getRange(eventSheet.getLastRow() + 1, 1, rows.length, EVENT_HEADERS.length).setValues(rows);
    }

    updateHeartbeat(payload, rows.length, receivedAt);
    markStored(payload.batchId);

    return json({ ok: true, accepted: rows.length });
  } catch (error) {
    return json({ ok: false, error: String(error) });
  } finally {
    lock.releaseLock();
  }
}

/**
 * Reports whether this batch contradicts what is already known about who is
 * reporting: one person sending from two live sessions, or one session
 * sending under two people. Neither happens while people work normally.
 */
function conflictReason(payload, previousRow, receivedAt) {
  var cache = CacheService.getScriptCache();
  var sessionKey = 'session_' + payload.sessionId;
  var sessionOwner = cache.get(sessionKey);

  if (sessionOwner && sessionOwner !== String(payload.userId)) {
    return 'sessionId ' + payload.sessionId + ' reported by userId ' + payload.userId +
      ' and by userId ' + sessionOwner;
  }
  cache.put(sessionKey, String(payload.userId), BATCH_MEMORY_SECONDS);

  if (!previousRow) {
    return '';
  }

  var sameSession = String(previousRow[1]) === String(payload.sessionId);
  var lastSeen = previousRow[4] ? new Date(previousRow[4]).getTime() : 0;
  var minutesApart = (receivedAt.getTime() - lastSeen) / 60000;

  if (!sameSession && lastSeen > 0 && minutesApart < CONFLICT_MINUTES) {
    return 'userId ' + payload.userId + ' reported from two sessions at once: ' +
      previousRow[1] + ' and ' + payload.sessionId;
  }

  return '';
}

/**
 * Emails the supervisor about a contradiction, rate limited per person, so a
 * machine stuck in a conflicting state cannot fill an inbox.
 */
function reportConflict(userId, reason) {
  if (ALERT_EMAIL.indexOf('PASTE_') !== -1) {
    return;
  }

  var cache = CacheService.getScriptCache();
  var key = 'conflict_' + userId;
  if (cache.get(key)) {
    return;
  }
  cache.put(key, '1', 3600);

  MailApp.sendEmail(
    ALERT_EMAIL,
    (COMPANY_TAG ? '[' + COMPANY_TAG + '] ' : '') + 'Studio Activity Logger: laporan bertentangan',
    'Laporan aktivitas bertentangan dengan yang sudah tercatat:\n\n' + reason +
      '\n\nSatu orang memakai satu Studio dalam satu waktu, jadi salah satu laporan ' +
      'tidak datang dari mesin yang diakuinya. Periksa tab Heartbeat kolom conflicts.'
  );
}

/**
 * Overwrites the sender's heartbeat row so the sheet always shows one line per
 * machine with the time it was last heard from, and counts every batch that
 * contradicted what that row already said.
 */
function updateHeartbeat(payload, accepted, receivedAt) {
  var sheet = getSheet('Heartbeat', HEARTBEAT_HEADERS);
  var values = sheet.getDataRange().getValues();

  for (var row = 1; row < values.length; row++) {
    if (String(values[row][0]) === String(payload.userId)) {
      var reason = conflictReason(payload, values[row], receivedAt);
      var conflicts = Number(values[row][7] || 0) + (reason ? 1 : 0);

      if (reason) {
        reportConflict(payload.userId, reason);
      }

      sheet.getRange(row + 1, 1, 1, HEARTBEAT_HEADERS.length).setValues([[
        cell(payload.userId), cell(payload.sessionId), cell(payload.placeId),
        cell(payload.placeName), receivedAt, Number(values[row][5] || 0) + accepted,
        cell(payload.version), conflicts
      ]]);
      return;
    }
  }

  conflictReason(payload, null, receivedAt);

  sheet.appendRow([
    cell(payload.userId), cell(payload.sessionId), cell(payload.placeId),
    cell(payload.placeName), receivedAt, accepted, cell(payload.version), 0
  ]);
}

/**
 * Emails the supervisor about every machine that has not reported recently.
 * Runs from a time-driven trigger.
 */
function checkHeartbeats() {
  var sheet = getSheet('Heartbeat', HEARTBEAT_HEADERS);
  var values = sheet.getDataRange().getValues();
  var cutoff = Date.now() - SILENT_MINUTES * 60 * 1000;
  var silent = [];

  for (var row = 1; row < values.length; row++) {
    var lastSeen = values[row][4];
    if (lastSeen && new Date(lastSeen).getTime() < cutoff) {
      silent.push('userId ' + values[row][0] + ' (terakhir ' + lastSeen + ')');
    }
  }

  if (silent.length > 0 && ALERT_EMAIL.indexOf('PASTE_') === -1) {
    MailApp.sendEmail(
      ALERT_EMAIL,
      (COMPANY_TAG ? '[' + COMPANY_TAG + '] ' : '') + 'Studio Activity Logger: ' + silent.length + ' mesin diam',
      'Mesin berikut tidak mengirim aktivitas lebih dari ' + SILENT_MINUTES + ' menit:\n\n' + silent.join('\n')
    );
  }
}
