/**
 * Collector for the Studio Activity Logger. Runs as a web app bound to one
 * spreadsheet; the deployment steps and the settings below are described in
 * README.md.
 *
 * Tabs maintained:
 *   Events    - one row per reported activity, append only
 *   Heartbeat - one row per machine, overwritten, so a machine that stops
 *               reporting is visible at a glance
 *   Config    - the settings a supervisor changes without redeploying
 *   Rules     - which alerts are emailed, and their thresholds
 *   Daily     - one row per person per day, rebuilt every night
 *   Gaps      - every run of numbered events found missing
 *
 * A batch is addressable after the fact, so a sender whose reply it could not
 * read can ask whether the batch landed and be told when it was refused.
 *
 * Every column means the same thing for every event kind. The plugin sends
 * structured fields only; the readable sentence in the summary column is
 * composed here, so the wording can change without rebuilding and
 * redistributing the plugin.
 */

var COMPANY_TAG = '';
var SHARED_TOKEN = 'PASTE_SHARED_TOKEN_HERE';

// Two sessions reporting for one person at once means one of them is forged,
// since a person edits from one Studio at a time.
var CONFLICT_MINUTES = 5;

var MAX_CELL_LENGTH = 500;
var BATCH_MEMORY_SECONDS = 21600;
var RULES_MEMORY_SECONDS = 60;
var MAX_COOLDOWN_SECONDS = 21600;

// Two events further apart than this count as separate stretches of work.
var IDLE_MINUTES = 5;

// Caps the rows one night's archiving moves, so a first run on a large sheet
// finishes inside the execution limit and the rest follows on later nights.
var MAX_ARCHIVE_ROWS = 20000;
var DAILY_READ_CHUNK = 5000;

var EVENT_HEADERS = [
  'receivedAt', 'eventAt', 'userId', 'sessionId', 'placeId', 'placeName',
  'mode', 'kind', 'summary', 'target', 'className', 'confidence', 'via',
  'property', 'oldValue', 'newValue', 'amount', 'location', 'preview',
  'fingerprint', 'origin', 'seq'
];

var CONFIG_HEADERS = ['key', 'value', 'notes'];

var CONFIG_DEFAULTS = [
  ['minVersion', '', 'Plugins older than this show a red panel and keep recording. Blank turns the check off'],
  ['announcement', '', 'One line shown in every plugin panel. Blank shows nothing'],
  ['enabled', 'TRUE', 'FALSE holds delivery on every machine. Recording continues and catches up when it is TRUE again'],
  ['alertEmail', '', 'Where alerts are emailed. Separate several addresses with commas. Blank sends nothing'],
  ['retentionDays', '180', 'Events older than this many days move to a monthly archive spreadsheet. Blank or 0 keeps everything here']
];

var RULE_HEADERS = ['rule', 'enabled', 'threshold', 'windowMinutes', 'scope', 'cooldownMinutes', 'notes'];

var RULE_DEFAULTS = [
  ['massDelete', 'TRUE', 20, 1, '', 30, 'One person deletes at least threshold instances, nested ones included, within windowMinutes. Scope limits it to paths starting with one of its comma-separated prefixes'],
  ['bulkScriptWrite', 'TRUE', '', '', '', 30, 'Many scripts rewritten at once, typical of a sync tool or an AI agent'],
  ['protectedPath', 'FALSE', '', '', 'ServerScriptService, ServerStorage', 30, 'Any change under one of the comma-separated paths in scope'],
  ['silentMachine', 'TRUE', '', 120, '', 360, 'A machine that has not reported for longer than windowMinutes. Checked hourly'],
  ['conflict', 'TRUE', '', '', '', 60, 'One person reporting from two sessions at once, or one session under two people'],
  ['sequenceGap', 'TRUE', '', '', '', 30, 'Numbered events missing, either never delivered or removed from Events afterwards'],
  ['outdated', 'FALSE', '', '', '', 360, 'A machine sending from a plugin older than minVersion']
];

var RULE_TITLES = {
  massDelete: 'Hapus massal',
  bulkScriptWrite: 'Script ditulis ulang massal',
  protectedPath: 'Perubahan di path terlindungi',
  silentMachine: 'Mesin diam',
  conflict: 'Laporan bertentangan',
  sequenceGap: 'Event hilang',
  outdated: 'Plugin usang'
};

var HEARTBEAT_HEADERS = [
  'userId', 'sessionId', 'placeId', 'placeName', 'lastSeen', 'eventsReceived',
  'version', 'conflicts'
];

var DAILY_HEADERS = [
  'date', 'userId', 'places', 'sessions', 'firstEvent', 'lastEvent', 'activeMinutes',
  'changes', 'created', 'deleted', 'propertyChanges', 'scriptsEdited', 'charactersTyped',
  'unattendedChanges'
];

var GAP_HEADERS = ['detectedAt', 'userId', 'sessionId', 'firstMissing', 'lastMissing', 'count', 'foundBy'];

var CHANGE_KINDS = {
  added: true, removed: true, restored: true, moved: true, property: true,
  attribute: true, scriptEdit: true, scriptSource: true
};

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
  return sheetIn(SpreadsheetApp.getActiveSpreadsheet(), name, headers);
}

/**
 * Does what getSheet does, in any spreadsheet rather than only this one.
 */
function sheetIn(book, name, headers) {
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
 * Reads a key and value tab into an object, first adding any documented row
 * the tab lacks. A deleted row comes back with its default, so no reader is
 * ever left without an answer.
 */
function readKeyedTab(name, headers, defaults) {
  var sheet = getSheet(name, headers);
  var values = sheet.getDataRange().getValues();
  var columns = values[0].map(function (header) {
    return String(header).trim();
  });

  var present = {};
  for (var row = 1; row < values.length; row++) {
    var key = String(values[row][0]).trim();
    if (key) {
      present[key] = byHeader(columns, values[row]);
    }
  }

  var missing = defaults.filter(function (entry) {
    return !present[entry[0]];
  }).map(function (entry) {
    return columns.map(function (column) {
      var index = headers.indexOf(column);
      return index === -1 ? '' : entry[index];
    });
  });

  if (missing.length > 0) {
    sheet.getRange(sheet.getLastRow() + 1, 1, missing.length, columns.length).setValues(missing);
    missing.forEach(function (entry) {
      present[entry[0]] = byHeader(columns, entry);
    });
  }

  return present;
}

/**
 * Pairs each value in a row with the header above it, so a tab whose columns
 * were rearranged or left over from an older version still reads correctly.
 */
function byHeader(columns, row) {
  var named = {};
  columns.forEach(function (column, index) {
    named[column] = row[index];
  });
  return named;
}

/**
 * Reads the settings a supervisor controls.
 */
function readConfig() {
  var rows = readKeyedTab('Config', CONFIG_HEADERS, CONFIG_DEFAULTS);
  var settings = {};
  Object.keys(rows).forEach(function (key) {
    settings[key] = rows[key].value;
  });
  return settings;
}

/**
 * Reads every alert rule and the settings they depend on, answering from a
 * short-lived copy so a busy collector does not read two tabs per batch.
 */
function readRules(fresh) {
  var cache = CacheService.getScriptCache();
  if (!fresh) {
    var cached = cache.get('rules');
    if (cached) {
      return JSON.parse(cached);
    }
  }

  var settings = readConfig();
  var rows = readKeyedTab('Rules', RULE_HEADERS, RULE_DEFAULTS);
  var rules = {};

  Object.keys(rows).forEach(function (name) {
    var row = rows[name];
    rules[name] = {
      enabled: String(row.enabled).toUpperCase() === 'TRUE',
      threshold: Number(row.threshold) || 0,
      windowMinutes: Number(row.windowMinutes) || 0,
      scope: String(row.scope || '').split(',').map(function (part) {
        return part.trim();
      }).filter(function (part) {
        return part !== '';
      }),
      cooldownMinutes: Number(row.cooldownMinutes) || 0
    };
  });

  var answer = {
    recipients: String(settings.alertEmail || '').trim(),
    minVersion: String(settings.minVersion || ''),
    retentionDays: Number(settings.retentionDays) || 0,
    rules: rules
  };
  cache.put('rules', JSON.stringify(answer), RULES_MEMORY_SECONDS);
  return answer;
}

/**
 * Reports whether version a is older than version b, comparing each part as a
 * number so 1.10 counts as newer than 1.9.
 */
function versionOlder(a, b) {
  var mine = String(a || '').match(/\d+/g) || [];
  var theirs = String(b || '').match(/\d+/g) || [];
  for (var index = 0; index < Math.max(mine.length, theirs.length); index++) {
    var left = Number(mine[index] || 0);
    var right = Number(theirs[index] || 0);
    if (left !== right) {
      return left < right;
    }
  }
  return false;
}

/**
 * Emails one alert. Missing or malformed addresses, or a refusal from the mail
 * service, are logged and never thrown, since an alert must not cost the batch
 * it came from.
 */
function sendAlertEmail(recipients, subject, body) {
  var addresses = recipients.split(',').map(function (address) {
    return address.trim();
  }).filter(function (address) {
    return /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(address);
  });
  if (addresses.length === 0) {
    return false;
  }

  try {
    MailApp.sendEmail(addresses.join(','), subject, body);
    return true;
  } catch (error) {
    console.warn('Alert email could not be sent: ' + error);
    return false;
  }
}

/**
 * Raises one alert when its rule is on and the same alert about the same
 * subject is not still cooling down. The cooldown starts only once the email
 * was sent, so a failed send is retried by the next trigger.
 */
function raiseAlert(config, ruleName, subject, message) {
  var rule = config.rules[ruleName];
  if (!rule || !rule.enabled || !config.recipients) {
    return;
  }

  var cache = CacheService.getScriptCache();
  var cooldownKey = 'alert_' + ruleName + '_' + subject;
  if (cache.get(cooldownKey)) {
    return;
  }

  var heading = (COMPANY_TAG ? '[' + COMPANY_TAG + '] ' : '') +
    'Studio Activity Logger: ' + (RULE_TITLES[ruleName] || ruleName);

  if (sendAlertEmail(config.recipients, heading, message) && rule.cooldownMinutes > 0) {
    cache.put(cooldownKey, '1', Math.min(rule.cooldownMinutes * 60, MAX_COOLDOWN_SECONDS));
  }
}

/**
 * Names a person and place the way every alert does.
 */
function whoAndWhere(payload) {
  return 'userId ' + payload.userId + (payload.placeName ? ' di "' + payload.placeName + '"' : '');
}

/**
 * Reports whether a path falls under one of the given prefixes. An empty list
 * covers every path.
 */
function inScope(path, prefixes) {
  if (prefixes.length === 0) {
    return true;
  }
  var text = String(path || '');
  return prefixes.some(function (prefix) {
    return text === prefix || text.indexOf(prefix + '.') === 0;
  });
}

/**
 * Checks every numbered event in a batch against the last number seen for
 * its session, and records each run that never arrived. Numbers already seen
 * are a retry and say nothing.
 *
 * Returns the runs found, for the alert.
 */
function trackSequence(payload, events, receivedAt) {
  var cache = CacheService.getScriptCache();
  var lastBySession = {};
  var gaps = [];

  events.forEach(function (event) {
    var seq = Number(event.seq);
    if (!(seq > 0)) {
      return;
    }

    var sessionId = String(event.sessionId || payload.sessionId);
    if (!(sessionId in lastBySession)) {
      lastBySession[sessionId] = Number(cache.get('seq_' + sessionId) || 0);
    }

    var last = lastBySession[sessionId];
    if (last > 0 && seq > last + 1) {
      gaps.push([
        receivedAt, cell(event.userId === undefined ? payload.userId : event.userId),
        cell(sessionId), last + 1, seq - 1, seq - 1 - last, 'arrival'
      ]);
    }
    if (seq > last) {
      lastBySession[sessionId] = seq;
    }
  });

  Object.keys(lastBySession).forEach(function (sessionId) {
    cache.put('seq_' + sessionId, String(lastBySession[sessionId]), BATCH_MEMORY_SECONDS);
  });

  if (gaps.length > 0) {
    var sheet = getSheet('Gaps', GAP_HEADERS);
    sheet.getRange(sheet.getLastRow() + 1, 1, gaps.length, GAP_HEADERS.length).setValues(gaps);
  }
  return gaps;
}

/**
 * Checks one stored batch against every rule that can be judged from a batch
 * alone.
 */
function evaluateBatch(payload, events, gaps) {
  var config = readRules(false);
  var own = events.filter(function (event) {
    return event.confidence !== 'observed';
  });

  gaps.forEach(function (gap) {
    raiseAlert(config, 'sequenceGap', gap[2],
      whoAndWhere(payload) + ': ' + gap[5] + ' event nomor ' + gap[3] + '-' + gap[4] +
      ' tidak pernah sampai (sesi ' + gap[2] + '). Antrean plugin penuh, atau event dibuang sebelum dikirim.');
  });

  var massDelete = config.rules.massDelete;
  if (massDelete && massDelete.enabled && massDelete.threshold > 0) {
    checkMassDelete(config, massDelete, payload, own);
  }

  own.forEach(function (event) {
    if (event.kind === 'bulkScriptWrite') {
      raiseAlert(config, 'bulkScriptWrite', String(payload.userId),
        whoAndWhere(payload) + ': ' + (event.amount || 0) + ' script ditulis ulang sekaligus. ' +
        'Biasanya tool sync atau AI agent.');
    }
  });

  var protectedPath = config.rules.protectedPath;
  if (protectedPath && protectedPath.enabled && protectedPath.scope.length > 0) {
    var touched = own.filter(function (event) {
      return CHANGE_KINDS[event.kind] && inScope(event.target, protectedPath.scope);
    });
    if (touched.length > 0) {
      raiseAlert(config, 'protectedPath', String(payload.userId),
        whoAndWhere(payload) + ': ' + touched.length + ' perubahan di path terlindungi, antara lain\n' +
        touched.slice(0, 5).map(function (event) {
          return '- ' + summaryFor(event);
        }).join('\n'));
    }
  }

  if (config.minVersion && payload.version && versionOlder(payload.version, config.minVersion)) {
    raiseAlert(config, 'outdated', String(payload.userId),
      whoAndWhere(payload) + ' masih memakai plugin ' + payload.version + ', minimum ' + config.minVersion + '.');
  }
}

/**
 * Counts one person's deletions across batches within the rule's window, and
 * alerts once they reach the threshold. The count starts over after an alert.
 */
function checkMassDelete(config, rule, payload, events) {
  var cache = CacheService.getScriptCache();
  var key = 'deletes_' + payload.userId;
  var recent = JSON.parse(cache.get(key) || '[]');
  var first = '';

  events.forEach(function (event) {
    if (event.kind !== 'removed' || !inScope(event.target, rule.scope)) {
      return;
    }
    var amount = Number(event.amount || 0);
    var count = event.operation === 'burst' ? amount : 1 + amount;
    recent.push([Number(event.epoch || 0), count]);
    first = first || String(event.target || '');
  });

  if (recent.length === 0) {
    return;
  }

  var newest = Math.max.apply(null, recent.map(function (entry) {
    return entry[0];
  }));
  var windowSeconds = Math.max(rule.windowMinutes, 0) * 60;
  recent = recent.filter(function (entry) {
    return newest - entry[0] <= windowSeconds;
  });

  var total = recent.reduce(function (sum, entry) {
    return sum + entry[1];
  }, 0);

  if (total >= rule.threshold) {
    raiseAlert(config, 'massDelete', String(payload.userId),
      whoAndWhere(payload) + ': ' + total + ' instance dihapus dalam ' + rule.windowMinutes +
      ' menit' + (first ? ', antara lain ' + first : '') + '.');
    recent = [];
  }

  cache.put(key, JSON.stringify(recent), BATCH_MEMORY_SECONDS);
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
 * Appends a batch of events, refreshes the sender's heartbeat row, and checks
 * the batch against the alert rules once it is safely stored.
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
        cell(event.origin),
        Number(event.seq) > 0 ? Number(event.seq) : ''
      ]);
    }

    if (rows.length > 0) {
      var eventSheet = getSheet('Events', EVENT_HEADERS);
      eventSheet.getRange(eventSheet.getLastRow() + 1, 1, rows.length, EVENT_HEADERS.length).setValues(rows);
    }

    updateHeartbeat(payload, rows.length, receivedAt);
    markStored(payload.batchId);

    try {
      var gaps = trackSequence(payload, events, receivedAt);
      evaluateBatch(payload, events, gaps);
    } catch (alertError) {
      console.error('Alert rules failed on a stored batch: ' + alertError);
    }

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
        raiseAlert(readRules(false), 'conflict', String(payload.userId),
          reason + '\nSatu orang memakai satu Studio dalam satu waktu, jadi salah satu laporan ' +
          'tidak datang dari mesin yang diakuinya. Periksa tab Heartbeat kolom conflicts.');
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
 * Alerts about every machine that has not reported for longer than the rule
 * allows. Runs from an hourly trigger.
 */
function checkHeartbeats() {
  var config = readRules(true);
  var rule = config.rules.silentMachine;
  if (!rule || !rule.enabled) {
    return;
  }

  var sheet = getSheet('Heartbeat', HEARTBEAT_HEADERS);
  var values = sheet.getDataRange().getValues();
  var cutoff = Date.now() - (rule.windowMinutes || 120) * 60 * 1000;

  for (var row = 1; row < values.length; row++) {
    var lastSeen = values[row][4];
    if (lastSeen && new Date(lastSeen).getTime() < cutoff) {
      raiseAlert(config, 'silentMachine', String(values[row][0]),
        'userId ' + values[row][0] + ' tidak mengirim aktivitas sejak ' + lastSeen +
        (values[row][3] ? ' (terakhir di "' + values[row][3] + '")' : '') +
        '. Studio ditutup, atau plugin dimatikan, dihapus, atau diblokir.');
    }
  }
}

/**
 * Runs everything that happens once a night: archiving old events, auditing
 * Events for removed rows, and rebuilding yesterday's summary.
 */
function runDailyMaintenance() {
  var config = readRules(true);

  var lock = LockService.getScriptLock();
  lock.waitLock(300000);
  try {
    archiveOldEvents(config.retentionDays);
    auditSequences(config);
  } finally {
    lock.releaseLock();
  }

  buildDaily();
}

/**
 * Moves events older than the retention period into a spreadsheet of their
 * own per month, then removes them here. Rows leave this sheet only after
 * their copy is written.
 */
function archiveOldEvents(retentionDays) {
  if (!(retentionDays > 0)) {
    return;
  }

  var book = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = getSheet('Events', EVENT_HEADERS);
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) {
    return;
  }

  var cutoff = Date.now() - retentionDays * 24 * 60 * 60 * 1000;
  var scanned = Math.min(lastRow - 1, MAX_ARCHIVE_ROWS);
  var received = sheet.getRange(2, 1, scanned, 1).getValues();

  var expired = 0;
  while (expired < received.length && received[expired][0] && new Date(received[expired][0]).getTime() < cutoff) {
    expired++;
  }
  if (expired === 0) {
    return;
  }

  var rows = sheet.getRange(2, 1, expired, EVENT_HEADERS.length).getValues();
  var zone = book.getSpreadsheetTimeZone();
  var byMonth = {};

  rows.forEach(function (row) {
    var month = Utilities.formatDate(new Date(row[0]), zone, 'yyyy-MM');
    (byMonth[month] = byMonth[month] || []).push(row.map(function (value) {
      return value instanceof Date || typeof value === 'number' ? value : cell(value);
    }));
  });

  var properties = PropertiesService.getScriptProperties();
  Object.keys(byMonth).forEach(function (month) {
    var id = properties.getProperty('archive_' + month);
    var archive = id ? SpreadsheetApp.openById(id) : null;
    if (!archive) {
      archive = SpreadsheetApp.create(book.getName() + ' Archive ' + month);
      properties.setProperty('archive_' + month, archive.getId());
    }
    var target = sheetIn(archive, 'Events', EVENT_HEADERS);
    var monthRows = byMonth[month];
    target.getRange(target.getLastRow() + 1, 1, monthRows.length, EVENT_HEADERS.length).setValues(monthRows);
  });

  SpreadsheetApp.flush();
  sheet.deleteRows(2, expired);
}

/**
 * Looks for numbered events missing from Events that were never reported as
 * lost on arrival. Those were delivered and later removed, and each run found
 * is recorded and alerted once.
 */
function auditSequences(config) {
  var sheet = getSheet('Events', EVENT_HEADERS);
  var lastRow = sheet.getLastRow();
  if (lastRow < 2) {
    return;
  }

  var userColumn = sheet.getRange(2, 3, lastRow - 1, 2).getValues();
  var seqColumn = sheet.getRange(2, EVENT_HEADERS.length, lastRow - 1, 1).getValues();
  var sessions = {};

  for (var index = 0; index < seqColumn.length; index++) {
    var seq = Number(seqColumn[index][0]);
    if (!(seq > 0)) {
      continue;
    }
    var sessionId = String(userColumn[index][1]);
    var session = sessions[sessionId] = sessions[sessionId] || { userId: userColumn[index][0], seqs: {} };
    session.seqs[seq] = true;
  }

  var gapSheet = getSheet('Gaps', GAP_HEADERS);
  var known = {};
  gapSheet.getDataRange().getValues().slice(1).forEach(function (row) {
    known[row[2] + '|' + row[3] + '|' + row[4]] = true;
  });

  var found = [];
  var now = new Date();

  Object.keys(sessions).forEach(function (sessionId) {
    var numbers = Object.keys(sessions[sessionId].seqs).map(Number).sort(function (a, b) {
      return a - b;
    });
    for (var position = 1; position < numbers.length; position++) {
      var firstMissing = numbers[position - 1] + 1;
      var lastMissing = numbers[position] - 1;
      if (lastMissing >= firstMissing && !known[sessionId + '|' + firstMissing + '|' + lastMissing]) {
        found.push([now, cell(sessions[sessionId].userId), cell(sessionId), firstMissing, lastMissing,
          lastMissing - firstMissing + 1, 'audit']);
      }
    }
  });

  if (found.length === 0) {
    return;
  }

  gapSheet.getRange(gapSheet.getLastRow() + 1, 1, found.length, GAP_HEADERS.length).setValues(found);
  found.forEach(function (gap) {
    raiseAlert(config, 'sequenceGap', 'audit_' + gap[2] + '_' + gap[3],
      'userId ' + gap[1] + ': ' + gap[5] + ' baris (event nomor ' + gap[3] + '-' + gap[4] + ', sesi ' + gap[2] +
      ') sudah pernah masuk tetapi kini tidak ada di tab Events. Kemungkinan dihapus manual.');
  });
}

/**
 * Rebuilds one day's summary rows, yesterday unless a date is given as
 * yyyy-MM-dd. Safe to run again: the day's old rows are replaced.
 */
function buildDaily(date) {
  var book = SpreadsheetApp.getActiveSpreadsheet();
  var zone = book.getSpreadsheetTimeZone();
  var day = date || Utilities.formatDate(new Date(Date.now() - 24 * 60 * 60 * 1000), zone, 'yyyy-MM-dd');

  var events = getSheet('Events', EVENT_HEADERS);
  var lastRow = events.getLastRow();
  var people = {};
  var oldestUseful = new Date(day + 'T00:00:00').getTime() - 24 * 60 * 60 * 1000;

  for (var end = lastRow; end >= 2; end -= DAILY_READ_CHUNK) {
    var start = Math.max(2, end - DAILY_READ_CHUNK + 1);
    var chunk = events.getRange(start, 1, end - start + 1, 21).getValues();
    var reachedOlder = false;

    chunk.forEach(function (row) {
      if (!row[1]) {
        return;
      }
      if (new Date(row[0]).getTime() < oldestUseful) {
        reachedOlder = true;
      }
      if (Utilities.formatDate(new Date(row[1]), zone, 'yyyy-MM-dd') !== day || row[11] === 'observed') {
        return;
      }
      tallyDaily(people, row);
    });

    if (reachedOlder) {
      break;
    }
  }

  var rows = Object.keys(people).map(function (userId) {
    var person = people[userId];
    person.epochs.sort(function (a, b) {
      return a - b;
    });

    var activeMs = 0;
    for (var index = 1; index < person.epochs.length; index++) {
      var gap = person.epochs[index] - person.epochs[index - 1];
      if (gap <= IDLE_MINUTES * 60 * 1000) {
        activeMs += gap;
      }
    }

    return [
      cell(day), cell(userId), cell(Object.keys(person.places).join(', ')),
      Object.keys(person.sessions).length,
      new Date(person.epochs[0]), new Date(person.epochs[person.epochs.length - 1]),
      Math.round(activeMs / 60000), person.changes, person.created, person.deleted,
      person.propertyChanges, Object.keys(person.scripts).length, person.characters, person.unattended
    ];
  });

  var daily = getSheet('Daily', DAILY_HEADERS);
  var existing = daily.getDataRange().getValues();
  for (var row = existing.length - 1; row >= 1; row--) {
    var stamp = existing[row][0] instanceof Date
      ? Utilities.formatDate(existing[row][0], zone, 'yyyy-MM-dd')
      : String(existing[row][0]);
    if (stamp === day) {
      daily.deleteRow(row + 1);
    }
  }

  if (rows.length > 0) {
    daily.getRange(daily.getLastRow() + 1, 1, rows.length, DAILY_HEADERS.length).setValues(rows);
  }
}

/**
 * Adds one event row to its person's running totals for the day.
 */
function tallyDaily(people, row) {
  var userId = String(row[2]);
  var person = people[userId] = people[userId] || {
    places: {}, sessions: {}, epochs: [], scripts: {},
    changes: 0, created: 0, deleted: 0, propertyChanges: 0, characters: 0, unattended: 0
  };

  var kind = row[7];
  person.epochs.push(new Date(row[1]).getTime());
  person.sessions[row[3]] = true;
  if (row[5]) {
    person.places[row[5]] = true;
  }

  if (!CHANGE_KINDS[kind]) {
    return;
  }

  person.changes++;
  if (kind === 'added') {
    person.created++;
  } else if (kind === 'removed') {
    person.deleted++;
  } else if (kind === 'property' || kind === 'attribute') {
    person.propertyChanges++;
  } else if (kind === 'scriptEdit') {
    person.scripts[row[9]] = true;
    person.characters += Math.abs(Number(row[16] || 0));
  }
  if (row[20] === 'unattended' || row[20] === 'assistant' || row[20] === 'tool') {
    person.unattended++;
  }
}

/**
 * Creates every tab and installs the hourly and nightly triggers. Run once from
 * the editor after deploying; running it again replaces the triggers rather
 * than doubling them.
 */
function setup() {
  var handlers = { checkHeartbeats: true, runDailyMaintenance: true };
  ScriptApp.getProjectTriggers().forEach(function (trigger) {
    if (handlers[trigger.getHandlerFunction()]) {
      ScriptApp.deleteTrigger(trigger);
    }
  });

  ScriptApp.newTrigger('checkHeartbeats').timeBased().everyHours(1).create();
  ScriptApp.newTrigger('runDailyMaintenance').timeBased().everyDays(1).atHour(1).create();

  getSheet('Events', EVENT_HEADERS);
  getSheet('Heartbeat', HEARTBEAT_HEADERS);
  getSheet('Daily', DAILY_HEADERS);
  getSheet('Gaps', GAP_HEADERS);
  readRules(true);
}

/**
 * Sends a test email, so the address can be proven before a real alert
 * depends on it. Run from the editor.
 */
function testEmail() {
  var config = readRules(true);
  if (!sendAlertEmail(config.recipients, 'Studio Activity Logger: tes email', 'Tes email alert berhasil.')) {
    throw new Error('Alamat kosong, salah format, atau email ditolak. Periksa alertEmail di tab Config.');
  }
}
