// =================================================================
// CONFIG
// =================================================================
const CALENDAR_NAME = 'Entertainment';
const TASK_LIST_NAME = 'Media Backlog 🎞️';
const UNWATCHED_COLOR_ID = '7';   // "Unwatched" color
const DEFAULT_COLOR_ID = '11';    // Calendar's default color
const SCRIPT_TIME_ZONE = Session.getScriptTimeZone();
// =================================================================

function syncCalendarAndTasks(startDate, endDate) {
  // Helper to parse date string in local timezone (avoid UTC conversion)
  const parseDate = (dateStr) => {
    const parts = dateStr.split('-');
    return new Date(parseInt(parts[0]), parseInt(parts[1]) - 1, parseInt(parts[2]));
  };
  
  // Use provided dates or default to last 6 months
  const today = endDate ? parseDate(endDate) : new Date();
  const aWhileAgo = startDate ? parseDate(startDate) : (() => {
    const date = new Date();
    //date.setDate(date.getDate() - 10);
    date.setMonth(date.getMonth() - 6);
    return date;
  })();

  const calendar = getCalendarByName(CALENDAR_NAME);
  if (!calendar) {
    logAction('⚠️ Calendar not found');
    return "⚠️ Calendar not found";
  }

  const events = calendar.getEvents(aWhileAgo, today, { max: 2000, futureEvents: false });
  logAction("📆 FETCHING CALENDAR EVENTS", null, true);
  logAction(`Found ${events.length} events in range`);
  events.forEach(ev => {
    const color = normalizeColor(ev.getColor());
    logAction(
      `Event: ${buildTaskTitle(ev)} | Color: ${color} | ` +
      `${color === UNWATCHED_COLOR_ID ? 'Unwatched' : 'Watched'}`
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
  const phase1Data = [];
  const phase2Data = [];

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
          phase1Data.push({ event: key, status: '➕ Created' });
        } else {
          logAction(`⚠️ Failed creating task for: ${key}`, actions);
        }
      } else {
        phase1Data.push({ event: key, status: '📌 Exists' });
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
        addPhase2Entry(phase2Data, task, '✅ Done → 🗑️ Deleted', null, '—');
      } else if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
        // Task Completed + Event Unwatched -> Reset Event Color
        try {
          ev.setColor(DEFAULT_COLOR_ID);
          reset++;
          logAction(`🔁 RESET COLOR for: ${ev.getTitle()}`, actions);
          // Task is already marked completed, let Bulk Clear handle deletion.
          logAction(`🗑️ DELETE completed task after event reset: ${task.title}`, actions);
          addPhase2Entry(phase2Data, task, '✅ Done → 🗑️ Deleted', ev, '🔁 Reset to Watched');
        } catch (e) {
          logAction(`⚠️ Error resetting color for ${ev.getTitle()}: ${e.message}`, actions);
        }
      } else {
        addPhase2Entry(phase2Data, task, '✅ Done → 🗑️ Deleted', ev, '✓ Watched');
      }
      // For all completed tasks, we simply move on. They will be removed by the final clear() call.
      continue; 
    }

    // --- Case 2: Incomplete Task Handling (status === 'needsAction') ---
    
    if (!ev) {
      // Incomplete Task + No Event (Manual / Orphan Task) -> NO CHANGE, KEEP TASK
      logAction(`Keeping orphaned incomplete task: ${task.title}`);
      addPhase2Entry(phase2Data, task, '📂 Kept (No Event)', null, '—');
      continue;
    }

    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
      // Incomplete Task + Event Unwatched -> NO CHANGE, KEEP TASK (The list item we're still tracking)
      logAction(`Keeping unwatched event's task: ${task.title}`);
      addPhase2Entry(phase2Data, task, '⏳ Tracking', ev, '🔴 Unwatched');
      continue;
    }

    // Incomplete Task + Event Watched/Default -> Mark as Completed for Bulk Clear
    phaseChanges++;
    try {
      const updatedTask = { id: task.id, status: 'completed' };
      Tasks.Tasks.update(updatedTask, taskList.id);
      markedCompleted++; deleted++;
      logAction(`🗑️ DELETE (event watched): ${task.title}`, actions);
      addPhase2Entry(phase2Data, task, '✓ Watched → 🗑️ Deleted', ev, '✓ Watched');
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
      Tasks.Tasks.clear(taskList.id);
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
  
  return generateHtmlReport(summary, phase1Data, phase2Data, aWhileAgo, today);
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

// Helper to add phase 2 data entries
function addPhase2Entry(phase2Data, task, taskStatus, event, eventStatus) {
  phase2Data.push({
    task: task.title,
    taskStatus,
    event: event ? (typeof event === 'string' ? event : event.getTitle()) : 'No Event',
    eventStatus
  });
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

function generateHtmlReport(summary, phase1Data, phase2Data, startDate, endDate) {
  const formatDate = (date) => {
    const year = date.getFullYear();
    const month = String(date.getMonth() + 1).padStart(2, '0');
    const day = String(date.getDate()).padStart(2, '0');
    return year + '-' + month + '-' + day;
  };
  
  const dateRange = formatDate(startDate) + ' to ' + formatDate(endDate);
  const parts = [
    `<div class="summary">📅 Date Range: ${dateRange}<br>📊 ${summary}</div>`
  ];
  
  // Phase 1 Container
  parts.push(generatePhaseHeader('phase1', 'PHASE 1️⃣: CREATE TASKS', phase1Data.length));
  
  if (phase1Data.length > 0) {
    parts.push(`
        <table class="data-table">
          <thead>
            <tr>
              <th>Unwatched Events in Calendar</th>
              <th style="width: 170px; text-align: left;">Task Action</th>
            </tr>
          </thead>
          <tbody>
            ${generateTableRows(phase1Data, [
              { key: 'event' },
              { key: 'status', style: 'text-align: left;' }
            ])}
          </tbody>
        </table>`);
  } else {
    parts.push(`<div class="empty-phase">No unwatched events to process</div>`);
  }
  
  parts.push(`
      </div>
    </div>`);
  
  // Phase 2 Container
  parts.push(generatePhaseHeader('phase2', 'PHASE 2️⃣: CLEANUP TASKS & RESET EVENTS', phase2Data.length));
  
  if (phase2Data.length > 0) {
    parts.push(`
        <table class="data-table">
          <thead>
            <tr>
              <th>Task Name</th>
              <th style="width: 220px;">Task Action</th>
              <th>Calendar Event</th>
              <th style="width: 200px;">Event Status</th>
            </tr>
          </thead>
          <tbody>
            ${generateTableRows(phase2Data, [
              { key: 'task' },
              { key: 'taskStatus' },
              { key: 'event' },
              { key: 'eventStatus' }
            ])}
          </tbody>
        </table>`);
  } else {
    parts.push(`<div class="empty-phase">No tasks to cleanup or events to reset</div>`);
  }
  
  parts.push(`
      </div>
    </div>`);
  
  return parts.join('');
}

// Helper to generate phase header
function generatePhaseHeader(phaseId, title, count) {
  return `
    <div class="phase-container" id="${phaseId}">
      <div class="phase" onclick="togglePhase('${phaseId}')">
        <span>${title}</span>
        <span class="stats-badge">${count}</span>
        <span class="phase-toggle">▼</span>
      </div>
      <div class="table-wrapper">`;
}

// Helper to generate table rows efficiently
function generateTableRows(data, columns) {
  return data.map(row => 
    `<tr>${columns.map(col => `<td${col.style ? ` style="${col.style}"` : ''}>${row[col.key]}</td>`).join('')}</tr>`
  ).join('');
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
          :root {
            /* Ocean Blue Theme (Default) */
            --bg-primary: #ffffff;
            --bg-secondary: #f8fafc;
            --text-primary: #1e293b;
            --text-secondary: #64748b;
            --accent-primary: #0ea5e9;
            --accent-secondary: #0284c7;
            --accent-light: #e0f2fe;
            --border-color: #e2e8f0;
            --shadow: rgba(0, 0, 0, 0.1);
            --table-hover: #f1f5f9;
            --table-stripe: #f8fafc;
          }
          
          @media (prefers-color-scheme: dark) {
            :root {
              --bg-primary: #0f172a;
              --bg-secondary: #1e293b;
              --text-primary: #f1f5f9;
              --text-secondary: #94a3b8;
              --accent-primary: #38bdf8;
              --accent-secondary: #0ea5e9;
              --accent-light: #1e3a5f;
              --border-color: #334155;
              --shadow: rgba(0, 0, 0, 0.3);
              --table-hover: #334155;
              --table-stripe: #1e293b;
            }
          }
          
          body { 
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            padding: 2em;
            max-width: 900px;
            margin: auto;
            background: var(--bg-primary);
            color: var(--text-primary);
            transition: background 0.3s, color 0.3s;
          }
          
          #status { 
            color: var(--text-primary);
            font-weight: bold;
          }
          
          #result { 
            margin-top: 1em;
            opacity: 0;
            transition: opacity 0.3s ease;
          }
          
          #result.visible { opacity: 1; }
          
          #footer { 
            margin-top: 1em;
            font-size: 0.9em;
            color: var(--text-secondary);
          }
          
          button { 
            margin-top: 1em;
            padding: 0.4em 0.8em;
            font-size: 1em;
            background: var(--accent-primary);
            color: white;
            border: none;
            border-radius: 6px;
            cursor: pointer;
            transition: background 0.2s;
          }
          
          button:hover {
            background: var(--accent-secondary);
          }
          
          /* Date range controls at bottom */
          .date-controls {
            margin-top: 2em;
            padding: 1em;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            display: flex;
            align-items: center;
            gap: 0.8em;
            flex-wrap: wrap;
          }
          
          .date-controls label {
            font-weight: 600;
            color: var(--text-primary);
            font-size: 0.95em;
          }
          
          .date-controls input[type="date"] {
            padding: 0.5em 0.7em;
            border: 1px solid var(--border-color);
            border-radius: 4px;
            background: var(--bg-primary);
            color: var(--text-primary);
            font-size: 0.95em;
          }
          
          .date-controls button {
            margin: 0;
            padding: 0.5em 1em;
          }
          
          /* Summary styling */
          .summary {
            margin-top: 1em;
            padding: 1em 1.2em;
            background: var(--accent-light);
            border: 2px solid var(--accent-primary);
            border-radius: 10px;
            font-weight: 600;
            color: var(--accent-primary);
            font-size: 1.1em;
            box-shadow: 0 2px 6px var(--shadow);
            line-height: 1.8;
          }
          
          /* Phase container - card-like wrapper */
          .phase-container {
            margin-top: 2em;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 12px;
            overflow: hidden;
            box-shadow: 0 4px 12px var(--shadow);
            transition: transform 0.2s, box-shadow 0.2s;
          }
          
          .phase-container:hover {
            transform: translateY(-2px);
            box-shadow: 0 6px 16px var(--shadow);
          }
          
          /* Phase header styling */
          .phase {
            padding: 1em 1.2em;
            background: linear-gradient(135deg, var(--accent-light), var(--bg-secondary));
            border-bottom: 2px solid var(--accent-primary);
            font-weight: 600;
            color: var(--text-primary);
            font-size: 1.1em;
            display: flex;
            align-items: center;
            gap: 0.5em;
            cursor: pointer;
            user-select: none;
          }
          
          .phase:hover {
            background: var(--accent-light);
          }
          
          .phase-toggle {
            margin-left: auto;
            transition: transform 0.3s;
            font-size: 1.2em;
          }
          
          .phase-container.collapsed .phase-toggle {
            transform: rotate(-90deg);
          }
          
          /* Table wrapper for padding */
          .table-wrapper {
            padding: 0;
            max-height: 600px;
            overflow-y: auto;
            transition: max-height 0.3s ease-out;
          }
          
          .phase-container.collapsed .table-wrapper {
            max-height: 0;
            overflow: hidden;
          }
          
          /* Table styling */
          .data-table {
            width: 100%;
            border-collapse: collapse;
            background: var(--bg-primary);
          }
          
          .data-table thead {
            background: linear-gradient(135deg, var(--accent-secondary), var(--accent-primary));
            color: white;
          }
          
          .data-table th {
            padding: 0.8em;
            text-align: left;
            font-weight: 600;
            font-size: 0.95em;
            text-transform: uppercase;
            letter-spacing: 0.5px;
          }
          
          .data-table td {
            padding: 0.9em 1em;
            border-bottom: 1px solid var(--border-color);
            background: var(--bg-primary);
            transition: background 0.15s;
          }
          
          .data-table tbody tr:hover td {
            background: var(--table-hover);
          }
          
          .data-table tbody tr:nth-child(even) td {
            background: var(--table-stripe);
          }
          
          .data-table tbody tr:nth-child(even):hover td {
            background: var(--table-hover);
          }
          
          .data-table tbody tr:last-child td {
            border-bottom: none;
          }
          
          /* Empty state */
          .empty-phase {
            padding: 2em;
            text-align: center;
            color: var(--text-secondary);
            font-style: italic;
          }
          
          /* Stats badge */
          .stats-badge {
            background: var(--accent-primary);
            color: white;
            padding: 0.2em 0.6em;
            border-radius: 12px;
            font-size: 0.85em;
            font-weight: 600;
          }
          
          .theme-selector {
            position: fixed;
            top: 1em;
            right: 1em;
            padding: 0.8em;
            background: var(--bg-secondary);
            border: 1px solid var(--border-color);
            border-radius: 8px;
            box-shadow: 0 2px 8px var(--shadow);
            display: flex;
            flex-direction: column;
            gap: 0.5em;
            min-width: 200px;
          }
          
          .theme-selector-row {
            display: flex;
            align-items: center;
            gap: 0.5em;
          }
          
          .theme-selector label {
            font-size: 0.85em;
            font-weight: 600;
            color: var(--text-primary);
            min-width: 60px;
          }
          
          .theme-selector select {
            flex: 1;
            padding: 0.3em 0.5em;
            border: 1px solid var(--border-color);
            border-radius: 4px;
            background: var(--bg-primary);
            color: var(--text-primary);
            cursor: pointer;
            font-size: 0.9em;
          }
          
          h2 {
            margin-top: 1em;
            margin-bottom: 0.5em;
            color: var(--text-primary);
            font-size: 1.8em;
          }
          
          #status {
            font-size: 1.05em;
            padding: 0.5em 0;
          }
        </style>
        <script>
          const themes = {
            'ocean': {
              light: {
                '--bg-primary': '#ffffff',
                '--bg-secondary': '#f8fafc',
                '--text-primary': '#1e293b',
                '--text-secondary': '#64748b',
                '--accent-primary': '#0ea5e9',
                '--accent-secondary': '#0284c7',
                '--accent-light': '#e0f2fe',
                '--border-color': '#e2e8f0',
                '--shadow': 'rgba(0, 0, 0, 0.1)',
                '--table-hover': '#f1f5f9',
                '--table-stripe': '#f8fafc'
              },
              dark: {
                '--bg-primary': '#0f172a',
                '--bg-secondary': '#1e293b',
                '--text-primary': '#f1f5f9',
                '--text-secondary': '#94a3b8',
                '--accent-primary': '#38bdf8',
                '--accent-secondary': '#0ea5e9',
                '--accent-light': '#1e3a5f',
                '--border-color': '#334155',
                '--shadow': 'rgba(0, 0, 0, 0.3)',
                '--table-hover': '#334155',
                '--table-stripe': '#1e293b'
              }
            },
            'forest': {
              light: {
                '--bg-primary': '#ffffff',
                '--bg-secondary': '#f7faf8',
                '--text-primary': '#1a3a2e',
                '--text-secondary': '#5a7a6f',
                '--accent-primary': '#10b981',
                '--accent-secondary': '#059669',
                '--accent-light': '#d1fae5',
                '--border-color': '#d4ebe0',
                '--shadow': 'rgba(0, 0, 0, 0.1)',
                '--table-hover': '#e8f5ed',
                '--table-stripe': '#f7faf8'
              },
              dark: {
                '--bg-primary': '#0d1f17',
                '--bg-secondary': '#1a3a2e',
                '--text-primary': '#e8f5ed',
                '--text-secondary': '#8fb8a8',
                '--accent-primary': '#34d399',
                '--accent-secondary': '#10b981',
                '--accent-light': '#1a4430',
                '--border-color': '#2d5a47',
                '--shadow': 'rgba(0, 0, 0, 0.3)',
                '--table-hover': '#2d5a47',
                '--table-stripe': '#1a3a2e'
              }
            },
            'sunset': {
              light: {
                '--bg-primary': '#ffffff',
                '--bg-secondary': '#fef8f4',
                '--text-primary': '#422006',
                '--text-secondary': '#78716c',
                '--accent-primary': '#f97316',
                '--accent-secondary': '#ea580c',
                '--accent-light': '#ffedd5',
                '--border-color': '#fed7aa',
                '--shadow': 'rgba(0, 0, 0, 0.1)',
                '--table-hover': '#fff7ed',
                '--table-stripe': '#fef8f4'
              },
              dark: {
                '--bg-primary': '#1c1917',
                '--bg-secondary': '#292524',
                '--text-primary': '#fafaf9',
                '--text-secondary': '#a8a29e',
                '--accent-primary': '#fb923c',
                '--accent-secondary': '#f97316',
                '--accent-light': '#422006',
                '--border-color': '#44403c',
                '--shadow': 'rgba(0, 0, 0, 0.3)',
                '--table-hover': '#44403c',
                '--table-stripe': '#292524'
              }
            },
            'purple': {
              light: {
                '--bg-primary': '#ffffff',
                '--bg-secondary': '#faf5ff',
                '--text-primary': '#3b0764',
                '--text-secondary': '#6b7280',
                '--accent-primary': '#a855f7',
                '--accent-secondary': '#9333ea',
                '--accent-light': '#f3e8ff',
                '--border-color': '#e9d5ff',
                '--shadow': 'rgba(0, 0, 0, 0.1)',
                '--table-hover': '#faf5ff',
                '--table-stripe': '#faf5ff'
              },
              dark: {
                '--bg-primary': '#1e1b4b',
                '--bg-secondary': '#312e81',
                '--text-primary': '#f5f3ff',
                '--text-secondary': '#c4b5fd',
                '--accent-primary': '#c084fc',
                '--accent-secondary': '#a855f7',
                '--accent-light': '#3b0764',
                '--border-color': '#4c1d95',
                '--shadow': 'rgba(0, 0, 0, 0.3)',
                '--table-hover': '#4c1d95',
                '--table-stripe': '#312e81'
              }
            },
            'rose': {
              light: {
                '--bg-primary': '#ffffff',
                '--bg-secondary': '#fef8fa',
                '--text-primary': '#4c0519',
                '--text-secondary': '#71717a',
                '--accent-primary': '#f43f5e',
                '--accent-secondary': '#e11d48',
                '--accent-light': '#ffe4e6',
                '--border-color': '#fecdd3',
                '--shadow': 'rgba(0, 0, 0, 0.1)',
                '--table-hover': '#fff1f2',
                '--table-stripe': '#fef8fa'
              },
              dark: {
                '--bg-primary': '#1f1a1d',
                '--bg-secondary': '#3f1d2b',
                '--text-primary': '#fff1f2',
                '--text-secondary': '#fda4af',
                '--accent-primary': '#fb7185',
                '--accent-secondary': '#f43f5e',
                '--accent-light': '#4c0519',
                '--border-color': '#881337',
                '--shadow': 'rgba(0, 0, 0, 0.3)',
                '--table-hover': '#881337',
                '--table-stripe': '#3f1d2b'
              }
            }
          };

          function applyTheme(themeName, mode) {
            const root = document.documentElement;
            const theme = themes[themeName][mode];
            for (const [key, value] of Object.entries(theme)) {
              root.style.setProperty(key, value);
            }
          }

          function getEffectiveMode() {
            const modePreference = localStorage.getItem('modePreference') || 'system';
            
            if (modePreference === 'system') {
              return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
            }
            
            return modePreference;
          }

          function changeTheme(themeName) {
            const mode = getEffectiveMode();
            applyTheme(themeName, mode);
            localStorage.setItem('selectedTheme', themeName);
          }

          function changeMode(modePreference) {
            localStorage.setItem('modePreference', modePreference);
            const savedTheme = localStorage.getItem('selectedTheme') || 'ocean';
            changeTheme(savedTheme);
          }

          function initTheme() {
            const savedTheme = localStorage.getItem('selectedTheme') || 'ocean';
            const savedMode = localStorage.getItem('modePreference') || 'system';
            
            document.getElementById('themeSelect').value = savedTheme;
            document.getElementById('modeSelect').value = savedMode;
            
            changeTheme(savedTheme);
          }

          window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
            const modePreference = localStorage.getItem('modePreference') || 'system';
            if (modePreference === 'system') {
              const savedTheme = localStorage.getItem('selectedTheme') || 'ocean';
              changeTheme(savedTheme);
            }
          });

          // Toggle phase visibility
          function togglePhase(phaseId) {
            const container = document.getElementById(phaseId);
            container.classList.toggle('collapsed');
          }

          // Initialize date inputs with default values
          function initDates() {
            const today = new Date();
            const sixMonthsAgo = new Date();
            sixMonthsAgo.setMonth(sixMonthsAgo.getMonth() - 6);
            
            const formatDate = (date) => {
              const year = date.getFullYear();
              const month = String(date.getMonth() + 1).padStart(2, '0');
              const day = String(date.getDate()).padStart(2, '0');
              return year + '-' + month + '-' + day;
            };
            
            document.getElementById('startDate').value = formatDate(sixMonthsAgo);
            document.getElementById('endDate').value = formatDate(today);
          }

          function run() {
            const startDate = document.getElementById('startDate').value;
            const endDate = document.getElementById('endDate').value;
            
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
              .syncCalendarAndTasks(startDate, endDate);
          }
        </script>
      </head>
      <body onload="initTheme(); initDates(); run();">
        <div class="theme-selector">
          <div class="theme-selector-row">
            <label for="modeSelect">🌓 Mode:</label>
            <select id="modeSelect" onchange="changeMode(this.value)">
              <option value="system">System</option>
              <option value="light">Light</option>
              <option value="dark">Dark</option>
            </select>
          </div>
          <div class="theme-selector-row">
            <label for="themeSelect">🎨 Color:</label>
            <select id="themeSelect" onchange="changeTheme(this.value)">
              <option value="ocean">Ocean Blue</option>
              <option value="forest">Forest Green</option>
              <option value="sunset">Sunset Orange</option>
              <option value="purple">Purple Dream</option>
              <option value="rose">Rose Pink</option>
            </select>
          </div>
        </div>
        
        <h2>📌 Calendar to Tasks Sync</h2>
        <div id="status">Initializing…</div>
        <div id="result"></div>
        
        <div class="date-controls">
          <label for="startDate">From:</label>
          <input type="date" id="startDate" />
          
          <label for="endDate">To:</label>
          <input type="date" id="endDate" />
          
          <button onclick="run()">🔄 Run Again</button>
        </div>
        
        <p id="footer">
          Ran at <span id="ranAt">—</span>
        </p>
      </body>
    </html>`
  ).setTitle('📌 Calendar to Tasks Sync Report');
  return html;
}

function doPost(e) {
  return doGet(e); // same shell; still calls sync on load
}
