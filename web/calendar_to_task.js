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
  if (!calendar) return;

  const events = calendar.getEvents(aWhileAgo, today, { max: 2000, futureEvents: false });
  Logger.log(`Found ${events.length} events in range`);
  events.forEach(ev => {
  Logger.log(
    `Event: ${buildTaskTitle(ev)} | Color: ${normalizeColor(ev.getColor())} | ` +
    `${normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID ? 'Unwatched' : 'Watched'}`
  );
  });

  const taskList = getTaskListByName(TASK_LIST_NAME);
  if (!taskList) return;

  const tasks = Tasks.Tasks.list(taskList.id, {
    showCompleted: true,
    showHidden: true
  }).items || [];
  Logger.log(`Found ${tasks.length} tasks in list "${TASK_LIST_NAME}"`);
  tasks.forEach(t => {
    Logger.log(`Task: ${t.title} | Notes: ${t.notes || ''} | Status: ${t.status}`);
  });

  const eventByKey = new Map(events.map(ev => [buildTaskTitle(ev), ev]));
  const taskKeys = new Set(tasks.map(t => t.title));
  const tasksByKey = new Map(tasks.map(t => [t.title, t]));

  let created = 0, deleted = 0, reset = 0;

  // === Phase 1: Create tasks for unwatched events ===
  for (const ev of events) {
    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID && !ev.isRecurringEvent()) {
      const key = buildTaskTitle(ev);
      if (!taskKeys.has(key)) {
        if (insertTask(taskList.id, ev, key)) {
          created++;
          taskKeys.add(key);
        }
      }
    }
  }

  // === Phase 2: Handle tasks whose events are missing or mismatched ===
  for (const task of tasks) {
    const ev = eventByKey.get(task.title);

    if (!ev) {
      // No corresponding event found
      if (task.status === 'completed') {
        // Completed + no event → delete
        if (deleteTask(taskList.id, task)) deleted++;
      } else {
        // Incomplete + no event → leave it alone
        Logger.log(`Skipping orphaned incomplete task: ${task.title}`);
      }
      continue;
    }

    // Event is found
    if (normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
      // Event is unwatched → keep task (do nothing)
      continue;
    } else {
      // Event is watched/default → delete task
      if (deleteTask(taskList.id, task)) deleted++;
    }
  }

  // === Phase 3: Completed tasks with matching unwatched events ===
  for (const task of tasks) {
    if (task.status !== 'completed') continue;
    const ev = eventByKey.get(task.title);

    if (ev && normalizeColor(ev.getColor()) === UNWATCHED_COLOR_ID) {
      try {
        ev.setColor(DEFAULT_COLOR_ID);
        reset++;
        Logger.log(`*** RESET COLOR: ${ev.getTitle()}`);

        // Delete the completed task after resetting color
        if (deleteTask(taskList.id, task)) {
          Logger.log(`<<< CLEANED UP completed task: ${task.title}`);
        }
      } catch (e) {
        Logger.log(`Error resetting color: ${e.message}`);
      }
    }
  }

  Logger.log(`Summary — Created: ${created}, Deleted: ${deleted}, Reset: ${reset}`);
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
    Logger.log(`>>> CREATED: ${taskTitle}`);
    return true;
  } catch (e) {
    Logger.log(`Error creating task: ${e.message}`);
    return false;
  }
}

function deleteTask(taskListId, task) {
  try {
    Tasks.Tasks.remove(taskListId, task.id);
    Logger.log(`<<< DELETED: ${task.title}`);
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

function platformIcon(location) {
  if (!location) return '';
  const lc = location.toLowerCase();

  // Big streamers
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
  // Default: no icon
  return '';
}
