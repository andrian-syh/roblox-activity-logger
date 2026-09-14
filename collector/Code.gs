/**
 * Collector for the Studio Activity Logger.
 *
 * Deploy as a Web App: Execute as "Me", access "Anyone". Bind it to a
 * spreadsheet, then set SHARED_TOKEN to the same value the plugin ships with
 * and paste the /exec URL into the plugin's Config.luau.
 *
 * Two sheets are maintained:
 *   Events    - one row per reported activity, append only
 *   Heartbeat - one row per machine, overwritten, so a machine that stops
 *               reporting is visible at a glance
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

var MAX_CELL_LENGTH = 500;

var EVENT_HEADERS = [
  'receivedAt', 'eventAt', 'userId', 'sessionId', 'placeId', 'placeName',
  'mode', 'kind', 'summary', 'target', 'className', 'confidence', 'via',
  'property', 'oldValue', 'newValue', 'amount', 'location', 'preview',
  'fingerprint'
];

var HEARTBEAT_HEADERS = [
  'userId', 'sessionId', 'placeId', 'placeName', 'lastSeen', 'eventsReceived'
];

/**
 * Makes one value safe to write into a cell. Control characters and line
 * breaks would split a row visually, an over-long value would swamp it, and a
 * leading formula character would make Sheets evaluate logged text as a
 * formula.
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
  if (/^[=+\-@]/.test(text)) {
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
    case 'sessionStart':
      return 'Opened the place in Studio';
    case 'sessionEnd':
      return 'Closed the place';
    case 'added':
      return 'Created ' + (event.className || 'instance') + ' "' + leaf + '"';
    case 'removed':
      return 'Deleted ' + (event.className || 'instance') + ' "' + leaf + '"';
    case 'selection':
      if (amount === 0) {
        return 'Cleared the selection';
      }
      return amount === 1 ? 'Selected "' + leaf + '"' : 'Selected ' + amount + ' instances';
    case 'property':
      return 'Set ' + event.property + ' on "' + leaf + '" from ' +
        (event.oldValue || 'unknown') + ' to ' + (event.newValue || 'unknown');
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
    default:
      return event.kind + (event.target ? ' on ' + event.target : '');
  }
}

/**
 * Builds a short key that is identical across machines for the same
 * underlying change, so replicated reports collapse into one group. The
 * timestamp is bucketed to absorb clock skew between laptops.
 */
function fingerprintOf(event) {
  var bucket = Math.floor((event.epoch || 0) / 5);
  var seed = [event.kind, event.target, event.property || '', bucket].join('|');

  var hash = 0;
  for (var index = 0; index < seed.length; index++) {
    hash = (hash * 31 + seed.charCodeAt(index)) | 0;
  }
  return (hash >>> 0).toString(16);
}

/**
 * Returns a sheet with the given headers, creating it on first use.
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
  }
  return sheet;
}

/**
 * Reports whether this batch has already been stored. A delivery that fails
 * after the collector wrote it is retried by the plugin with the same batch
 * id, and without this check the retry would duplicate every row.
 */
function alreadyStored(batchId) {
  if (!batchId) {
    return false;
  }
  var cache = CacheService.getScriptCache();
  if (cache.get('batch_' + batchId)) {
    return true;
  }
  cache.put('batch_' + batchId, '1', 21600);
  return false;
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
      return ContentService.createTextOutput(JSON.stringify({ ok: false, error: 'bad token' }))
        .setMimeType(ContentService.MimeType.JSON);
    }

    if (alreadyStored(payload.batchId)) {
      return ContentService.createTextOutput(JSON.stringify({ ok: true, accepted: 0, duplicate: true }))
        .setMimeType(ContentService.MimeType.JSON);
    }

    var events = payload.events || [];
    var receivedAt = new Date();
    var rows = [];

    for (var index = 0; index < events.length; index++) {
      var event = events[index];
      rows.push([
        receivedAt,
        event.epoch ? new Date(event.epoch * 1000) : '',
        cell(payload.userId),
        cell(payload.sessionId),
        cell(payload.placeId),
        cell(payload.placeName),
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
        cell(fingerprintOf(event))
      ]);
    }

    if (rows.length > 0) {
      var eventSheet = getSheet('Events', EVENT_HEADERS);
      eventSheet.getRange(eventSheet.getLastRow() + 1, 1, rows.length, EVENT_HEADERS.length).setValues(rows);
    }

    updateHeartbeat(payload, rows.length, receivedAt);

    return ContentService.createTextOutput(JSON.stringify({ ok: true, accepted: rows.length }))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (error) {
    return ContentService.createTextOutput(JSON.stringify({ ok: false, error: String(error) }))
      .setMimeType(ContentService.MimeType.JSON);
  } finally {
    lock.releaseLock();
  }
}

/**
 * Overwrites the sender's heartbeat row so the sheet always shows one line per
 * machine with the time it was last heard from.
 */
function updateHeartbeat(payload, accepted, receivedAt) {
  var sheet = getSheet('Heartbeat', HEARTBEAT_HEADERS);
  var values = sheet.getDataRange().getValues();

  for (var row = 1; row < values.length; row++) {
    if (String(values[row][0]) === String(payload.userId)) {
      sheet.getRange(row + 1, 1, 1, HEARTBEAT_HEADERS.length).setValues([[
        cell(payload.userId), cell(payload.sessionId), cell(payload.placeId),
        cell(payload.placeName), receivedAt, Number(values[row][5] || 0) + accepted
      ]]);
      return;
    }
  }

  sheet.appendRow([
    cell(payload.userId), cell(payload.sessionId), cell(payload.placeId),
    cell(payload.placeName), receivedAt, accepted
  ]);
}

/**
 * Emails the supervisor about every machine that has not reported recently.
 * Attach a time-driven trigger; hourly is enough.
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
