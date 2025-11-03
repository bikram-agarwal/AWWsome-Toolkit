// =================================================================
// CONFIG
// =================================================================
const CALENDAR_NAME = 'Entertainment';
const TASK_LIST_NAME = 'Media Backlog 🎞️';
const UNWATCHED_COLOR_ID = '7';   // "Unwatched" color
const DEFAULT_COLOR_ID = '11';    // Calendar's default color
const SCRIPT_TIME_ZONE = Session.getScriptTimeZone();
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

  let created = 0, deleted = 0, reset = 0, phaseChanges = 0, markedCompleted = 0;
  const actions = [];

  // === Phase 1: Create tasks for unwatched events ===
  logAction("PHASE 1️⃣: CREATE TASKS", actions, true);
  for (const ev of events) {
    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID && !ev.isRecurringEvent()) {
      const key = buildTaskTitle(ev);
      if (!taskKeys.has(key)) {
        phaseChanges++;
        if (insertTask(taskList.id, key, ev.getLocation())) {
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

// === Phase 2: Cleanup Tasks & Reset Events ===
  logAction("PHASE 2️⃣: CLEANUP TASKS & RESET EVENTS", actions, true);
  phaseChanges = 0;
  for (const task of tasks) {
    const ev = eventByKey.get(task.title);

    // --- Case 1: Completed Tasks ---
    if (task.status === 'completed') {
      phaseChanges++;
      if (!ev) {
        // Task Completed + No Event (Manual / Orphan Task) -> Let Bulk Clear handle deletion
        deleted++;
        logAction(`🗑️ DELETE completed orphan task: ${task.title}`, actions);
      } else if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
        // Task Completed + Event Unwatched -> Reset Event Color
        try {
          ev.setColor(DEFAULT_COLOR_ID);
          reset++;
          logAction(`🔁 RESET COLOR for: ${ev.getTitle()}`, actions);
          // Task is already marked completed, let Bulk Clear handle deletion.
          logAction(`🗑️ DELETE completed task after event reset: ${task.title}`, actions);
        } catch (e) {
          logAction(`⚠️ Error resetting color for ${ev.getTitle()}: ${e.message}`, actions);
        }
      }
      // For all completed tasks, we simply move on. They will be removed by the final clear() call.
      continue; 
    }

    // --- Case 2: Incomplete Task Handling (status === 'needsAction') ---
    
    if (!ev) {
      // Incomplete Task + No Event (Manual / Orphan Task) -> NO CHANGE, KEEP TASK
      logAction(`Keeping orphaned incomplete task: ${task.title}`);
      continue;
    }

    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
      // Incomplete Task + Event Unwatched -> NO CHANGE, KEEP TASK (The list item we're still tracking)
      logAction(`Keeping unwatched event's task: ${task.title}`);
      continue;
    }

    // Incomplete Task + Event Watched/Default -> Mark as Completed for Bulk Clear
    phaseChanges++;
    try {
      const updatedTask = { id: task.id, status: 'completed' };
      Tasks.Tasks.update(updatedTask, taskListId);
      markedCompleted++; deleted++;
      logAction(`🗑️ DELETE (event watched): ${task.title}`, actions);
    } catch (e) {
      logAction(`⚠️ Failed marking task (event watched) as completed: ${task.title}`, actions);
    }
  }
  
  // Clear all completed tasks in bulk
  const completedBeforeRun = tasks.filter(t => t.status === 'completed').length;
  deleted = completedBeforeRun + markedCompleted;

  if (deleted > 0) {
    try {
      // This API call clears all tasks with status='completed' in the list.
      Tasks.Tasks.clear(taskListId);
      logAction(`🧹 BULK CLEARED all completed tasks (Approx. ${deleted} total deletions)`, actions);
    } catch (e) {
      logAction(`⚠️ FAILED to bulk clear completed tasks!`, actions);
    }
  }

  ifNoChange(phaseChanges + markedCompleted, actions);

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
  const calendars = CalendarApp.getCalendarsByName(name);
  return calendars.length > 0 ? calendars[0] : null; 
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
      maxResults: 100,
      pageToken: pageToken,
      fields: 'items(title,id,notes,status),nextPageToken' 
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
  const eventDate = Utilities.formatDate(ev.getStartTime(), SCRIPT_TIME_ZONE, 'MM/dd/yyyy');
  return `${ev.getTitle()} (${eventDate})`;
}

function insertTask(taskListId, taskTitle, location) {
  const icon = platformIcon(location);
  const notes = `On: ${icon} ${location || 'N/A'}`;
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
  const platformMap = new Map([
    [['netflix'], '🍿'],
    [['prime', 'amazon'], '📦'],
    [['disney'], '🪄'],
    [['hulu'], '💚'],
    [['hbo', 'max'], '🎥'],
    [['apple'], '🍎'],
    [['peacock'], '🦚'],
    [['paramount'], '🌄'],
    [['starz'], '⭐'],
    [['youtube'], '▶️'],
    [['game pass', 'xbox'], '🎮']
  ]);

  for (const [keywords, icon] of platformMap.entries()) {
    if (keywords.some(keyword => lc.includes(keyword))) {
      return icon;
    }
  }
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
