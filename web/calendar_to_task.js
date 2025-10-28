// =================================================================
// CONFIG
// =================================================================
const CALENDAR_NAME = 'Entertainment';
const TASK_LIST_NAME = 'Test';
const UNWATCHED_COLOR_ID = '7';
const DEFAULT_COLOR_ID = '11';
// =================================================================

function syncCalendarAndTasks() {
  const today = new Date();
  const aWhileAgo = new Date();
  aWhileAgo.setDate(today.getDate() - 10);

  const calendar = getCalendarByName(CALENDAR_NAME);
  if (!calendar) return;

  const events = calendar.getEvents(aWhileAgo, today, { max: 2000, futureEvents: false });
  const eventById = new Map(events.map(ev => [safeEventId(ev), ev]));

  const taskList = getTaskListByName(TASK_LIST_NAME);
  if (!taskList) return;

  const tasks = Tasks.Tasks.list(taskList.id, {
    showCompleted: true,
    showHidden: true
  }).items || [];  const eventIdsWithTasks = new Set();
  const tasksByEventId = new Map();

  tasks.forEach(t => {
    const evId = extractEventIdFromNotes(t.notes || '');
    if (evId) {
      eventIdsWithTasks.add(evId);
      tasksByEventId.set(evId, t);
    }
  });

  let created = 0, deleted = 0, reset = 0;

  // === Phase 1: Create tasks for unwatched events ===
  events.forEach(ev => {
    if (ev.getColor() === UNWATCHED_COLOR_ID && !ev.isRecurringEvent()) {
      const evId = safeEventId(ev);
      if (!eventIdsWithTasks.has(evId)) {
        if (insertTask(taskList.id, ev)) {
          created++;
          eventIdsWithTasks.add(evId);
        }
      }
    }
  });

  // === Phase 2: Delete tasks for events no longer matching ===
  tasks.forEach(task => {
    if (task.status === 'completed') return; // keep completed tasks
    const evId = extractEventIdFromNotes(task.notes || '');
    if (!evId) return;
    const ev = eventById.get(evId);
    if (!ev || ev.getColor() !== UNWATCHED_COLOR_ID) {
      if (deleteTask(taskList.id, task)) deleted++;
    }
  });

  // === Phase 3: Completed tasks reset event color ===
  tasks.forEach(task => {
    if (task.status !== 'completed') return;
    const evId = extractEventIdFromNotes(task.notes || '');
    if (!evId) return;
    const ev = eventById.get(evId);
    if (ev && ev.getColor() === UNWATCHED_COLOR_ID) {
      try {
        ev.setColor(DEFAULT_COLOR_ID);
        reset++;
        Logger.log(`*** RESET COLOR: ${ev.getTitle()}`);
      } catch (e) {
        Logger.log(`Error resetting color: ${e.message}`);
      }
    }
  });

  Logger.log(`Created: ${created}, Deleted: ${deleted}, Reset: ${reset}`);
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

function insertTask(taskListId, ev) {
  const tz = Session.getScriptTimeZone();
  const eventDate = Utilities.formatDate(ev.getStartTime(), tz, 'MM/dd/yyyy');
  const taskTitle = `${ev.getTitle()} (${eventDate})`;
  const notes = `On: ${ev.getLocation() || 'N/A'}\nEventID: ${safeEventId(ev)}`;

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

// Normalize Calendar event IDs so they’re stable
function safeEventId(event) {
  // Strip off any suffix after an underscore (recurring instances)
  return event.getId().split('_')[0];
}

// Extract and normalize the EventID stored in task notes
function extractEventIdFromNotes(notes) {
  const m = notes.match(/EventID:\s*(.+)/);
  return m ? m[1].trim().split('_')[0] : null;
}