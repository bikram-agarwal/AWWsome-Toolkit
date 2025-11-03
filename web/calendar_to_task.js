// =================================================================
// CONFIG
// =================================================================
const CALENDAR_NAME = 'Entertainment';
const TASK_LIST_NAME = 'Media Backlog 🎞️';
const UNWATCHED_COLOR_ID = '7';   // "Unwatched" color
const DEFAULT_COLOR_ID = '11';    // Calendar's default color
// =================================================================

function syncCalendarAndTasks() {
  const today = new Date();
  const aWhileAgo = new Date();
  //aWhileAgo.setDate(today.getDate() - 10);
  aWhileAgo.setMonth(today.getMonth() - 6);

  const calendar = getCalendarByName(CALENDAR_NAME);
  if (!calendar) {
    logAction('⚠️ Calendar not found');
    return "⚠️ Calendar not found";
  }

  const events = calendar.getEvents(aWhileAgo, today, { max: 2000, futureEvents: false });
  logAction("📆 FETCHING CALENDAR EVENTS", null, true);
  logAction(`Found ${events.length} events in range`);
  events.forEach(ev => {
    logAction(
      `Event: ${buildTaskTitle(ev)} | Color: ${normalizeColor(ev.getColor())} | ` +
      `${normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID ? 'Unwatched' : 'Watched'}`
    );
  });

  const taskList = getTaskListByName(TASK_LIST_NAME);
  if (!taskList) {
    logAction('⚠️ Task list not found');
    return "⚠️ Task list not found";
  }

  const tasks = listAllTasks(taskList.id);
  logAction("📋 FETCHING TASKS", null, true);
  logAction(`Found ${tasks.length} tasks in list "${TASK_LIST_NAME}"`);
  tasks.forEach(t => {
    logAction(`Task: ${t.title} | Notes: ${t.notes || ''} | Status: ${t.status}`);
  });

  const eventByKey = new Map(events.map(ev => [buildTaskTitle(ev), ev]));
  const taskKeys = new Set(tasks.map(t => t.title));

  let created = 0, deleted = 0, reset = 0, phaseChanges = 0;
  const actions = [];

  // === Phase 1: Create tasks for unwatched events ===
  logAction("PHASE 1️⃣: CREATE TASKS", actions, true);
  for (const ev of events) {
    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID && !ev.isRecurringEvent()) {
      const key = buildTaskTitle(ev);
      if (!taskKeys.has(key)) {
        phaseChanges++;
        if (insertTask(taskList.id, ev, key)) {
          created++;
          logAction(`🆕 CREATED task for: ${key}`, actions);
          taskKeys.add(key);
        } else {
          logAction(`⚠️ Failed creating task for: ${key}`, actions);
        }
      }
    }
  }

  ifNoChange(phaseChanges, actions);

  // === Phase 2: Handle tasks whose events are missing or mismatched ===
  logAction("PHASE 2️⃣: CLEANUP TASKS & RESET EVENTS", actions, true);
  phaseChanges = 0;
  for (const task of tasks) {
    const ev = eventByKey.get(task.title);
    if (!ev) {
      // No corresponding event found
      if (task.status === 'completed') {
        // Task Completed + No Event → Delete Task
        phaseChanges++;
        if (deleteTask(taskList.id, task)) {
          deleted++;
          logAction(`🗑️ DELETED completed orphan task: ${task.title}`, actions);
        } else {
          logAction(`⚠️ Failed deleting completed orphan task: ${task.title}`, actions);
        }
      } else {
        // Task Incomplete + No Event → No change, keep task
        logAction(`Kept orphaned incomplete task: ${task.title}`);
      }
      continue;
    }

    // Event is found
    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
      // Event is Unwatched
      if (task.status === 'completed') {
        // Task Completed + Event Unwatched → reset event color + delete task
        phaseChanges++;
        try {
          ev.setColor(DEFAULT_COLOR_ID);
          reset++;
          logAction(`🔁 RESET COLOR for: ${ev.getTitle()}`, actions);

          if (deleteTask(taskList.id, task)) {
            logAction(`🗑️ DELETED completed task after reset: ${task.title}`, actions);
          } else {
            logAction(`⚠️ Failed deleting completed task after reset: ${task.title}`, actions);
          }
        } catch (e) {
          logAction(`⚠️ Error resetting color for ${ev.getTitle()}: ${e.message}`, actions);
        }
      } else {
        // Task Incomplete + Event Unwatched → No change, keep task
        logAction(`Keeping task for unwatched event: ${task.title}`);
      }
    } else {
      // Event is watched/default → delete task
      phaseChanges++;
      if (deleteTask(taskList.id, task)) {
        deleted++;
        logAction(`🗑️ DELETED (event watched): ${task.title}`, actions);
      } else {
        logAction(`⚠️ Failed deleting task (event watched): ${task.title}`, actions);
      }
    }
  }

  ifNoChange(phaseChanges, actions);

  // Summary
  logAction("✅ SYNC COMPLETE", actions, true);
  const summary = `Created: ${created}, Deleted: ${deleted}, Reset: ${reset}`;
  logAction(`📊 Summary — ${summary}`, actions);
  return summary + "<br>" + actions.join("<br>");
}

// -----------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------

function getCalendarByName(name) {
  return CalendarApp.getAllCalendars().find(cal => cal.getName() === name);
}

function getTaskListByName(name) {
  const resp = Tasks.Tasklists.list({ fields: 'items(title,id)' });
  return resp.items?.find(list => list.title === name) || null;
}

function listAllTasks(taskListId) {
  let all = [];
  let pageToken;
  do {
    const resp = Tasks.Tasks.list(taskListId, {
      showCompleted: true,
      showHidden: true,
      maxResults: 100,   // can request up to 100 per page
      pageToken: pageToken
    });
    if (resp.items) all = all.concat(resp.items);
    pageToken = resp.nextPageToken;
  } while (pageToken);
  return all;
}

// Unified logging helper
function logAction(msg, actions, isHeader = false) {
  let logMsg = msg;
  let htmlMsg = msg;

  if (isHeader) {
    const line = "====================";
    logMsg = `${line} ${msg} ${line}`;
    htmlMsg = `<div class="phase">${msg}</div>`;
  }

  Logger.log(logMsg);

  if (actions) {
    actions.push(isHeader ? htmlMsg : msg);
  }
}

function ifNoChange(phaseChanges, actions) {
  if (phaseChanges === 0) {
    logAction("No changes in this phase", actions);
  }
}

function buildTaskTitle(ev) {
  const tz = Session.getScriptTimeZone();
  const eventDate = Utilities.formatDate(ev.getStartTime(), tz, 'MM/dd/yyyy');
  return `${ev.getTitle()} (${eventDate})`;
}

function insertTask(taskListId, ev, taskTitle) {
  const icon = platformIcon(ev.getLocation());
  const notes = `On: ${icon} ${ev.getLocation() || 'N/A'}`;
  const task = { title: taskTitle, notes, status: 'needsAction' };
  try {
    Tasks.Tasks.insert(task, taskListId);
    return true;
  } catch (e) {
    Logger.log(`Error creating task: ${e.message}`);
    return false;
  }
}

function deleteTask(taskListId, task) {
  try {
    Tasks.Tasks.remove(taskListId, task.id);
    return true;
  } catch (e) {
    Logger.log(`Error deleting task: ${e.message}`);
    return false;
  }
}

// Normalize color: treat "" as DEFAULT_COLOR_ID
function normalizeColor(color) {
  return color === "" ? DEFAULT_COLOR_ID : color;
}

// Expanded platform icon mapping
function platformIcon(location) {
  if (!location) return '';
  const lc = location.toLowerCase();
  if (lc.includes('netflix')) return '🍿';
  if (lc.includes('prime') || lc.includes('amazon')) return '📦';
  if (lc.includes('disney')) return '🪄';
  if (lc.includes('hulu')) return '💚';
  if (lc.includes('hbo') || lc.includes('max')) return '🎥';
  if (lc.includes('apple')) return '🍎'; 
  if (lc.includes('peacock')) return '🦚';
  if (lc.includes('paramount')) return '🌄';
  if (lc.includes('starz')) return '⭐';
  if (lc.includes('game pass') || lc.includes('xbox')) return '🎮';
  return '';
}

// -----------------------------------------------------------------
// Web App Wrappers
// -----------------------------------------------------------------

function doGet(e) {
  const html = HtmlService.createHtmlOutput(
    `<html>
      <head>
        <meta charset="utf-8">
        <link rel="icon" href='data:image/svg+xml,<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"><text y=".9em" font-size="90">📆</text></svg>'>
        <title>📌 Media Sync</title>
        <style>
          body { font-family: sans-serif; padding: 2em; max-width: 700px; margin: auto; }
          #status { color: #444; font-weight: bold; }
          #result { margin-top: 1em; opacity: 0; transition: opacity 0.3s ease; }
          #result.visible { opacity: 1; }
          #footer { margin-top: 1em; font-size: 0.9em; color: #666; }
          button { margin-top: 1em; padding: 0.4em 0.8em; font-size: 1em; }
          /* Phase header styling */
          .phase {
            margin-top: 1em;
            padding: 0.6em 0.9em;
            background: #e8f4ff;          /* pale blue background */
            border-left: 4px solid #0078d4; /* Microsoft blue accent */
            font-weight: 600;
            font-family: sans-serif;
            color: #222;
            border-radius: 4px;
          }
        </style>
        <script>
          function run() {
            document.getElementById('status').textContent = '⏳ Running…';
            document.getElementById('result').classList.remove('visible');
            document.getElementById('result').innerHTML = '';
            document.getElementById('ranAt').textContent = '—';
            google.script.run
              .withSuccessHandler(function(summary) {
                document.getElementById('status').textContent = '✔ Done';
                document.getElementById('result').innerHTML = summary;
                document.getElementById('result').classList.add('visible');
                document.getElementById('ranAt').textContent = new Date().toLocaleString();
              })
              .syncCalendarAndTasks();
          }
        </script>
      </head>
      <body onload="run()">
        <h2>📌 Calendar to Tasks Sync</h2>
        <div id="status">Initializing…</div>
        <div id="result"></div>
        <p id="footer">
          Ran at <span id="ranAt">—</span>
        </p>
        <button onclick="run()">🔄 Run Again</button>
      </body>
    </html>`
  ).setTitle('📌 Calendar to Tasks Sync Report');
  return html;
}

function doPost(e) {
  return doGet(e); // same shell; still calls sync on load
}
