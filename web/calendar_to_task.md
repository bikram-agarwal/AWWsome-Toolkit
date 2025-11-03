# Calendar to Task Sync

A Google Apps Script with a beautiful web interface that automatically syncs specific calendar events to Google Tasks, creating a seamless workflow for tracking watchlists, entertainment queues, or any calendar-based TODO system.

## 🎯 What It Does

Automatically collects all "unwatched" shows/movies from your calendar (marked with a specific color) into a single task list. 

Instead of scrolling through multiple months of calendar views trying to spot unwatched items among all your other events and calendars, you just open one task list and pick what to watch next.

**How it works:**
1. You mark some calendar events as `unwatched` by changing their color. (e.g., Peacock = unwatched). 
2. When the script runs, it creates corresponding tasks in your dedicated task list.
3. When you are done, the script handles cleanup in one of two ways:
   1. You complete the task → the task is deleted, and the event color is reset to default/watched.
   2. You reset the event color → the corresponding task is deleted.

**Usage Example:**

1. **Friday, Nov 7**: "_Frankensteine_" comes to Netflix. You create a calendar event with the default color.
2. **You get busy**: Don't watch it that day. Later that week, you manually change the event color to Peacock (7) to mark it as "unwatched."
3. **Script runs on schedule**: A task "_Frankensteine (11/07/2025)_" appears in your "Media Backlog" task list.
4. **Two months later**: Instead of scrolling through multiple months in calendar, looking for unwatched events, you just open your "Media Backlog" task list.
5. **Pick and watch**: You see "_Frankensteine_" in the list, watch it, and mark the task as completed.
6. **Script cleans up**: The calendar event changes back to default color, and the completed task is removed.

Your task list becomes your single source of truth for "_what haven't I watched yet?_".

## 📋 Prerequisites

- **Google Account** with access to:
  - Google Calendar
  - Google Tasks
- **Google Apps Script** project (free)

## 🚀 Setup Instructions

### Step 1: Create a Google Apps Script Project

1. Go to [script.google.com](https://script.google.com).
2. Click **New Project**.
3. Delete the default code.
4. Copy and paste the entire contents of [`calendar_to_task.js`](calendar_to_task.js).
5. Name your project (e.g., "Calendar Task Sync").

### Step 2: Enable Google Tasks API

1. In your Apps Script project, click **Services** (⊕ icon in the left sidebar).
2. Find **Google Tasks API** in the list.
3. Click **Add**.

### Step 3: Configure the Script

At the top of the script, update these configuration constants to match your setup:

```javascript
const CALENDAR_NAME = 'Entertainment';     // Your calendar name
const TASK_LIST_NAME = 'Media Backlog';    // Your task list name
const UNWATCHED_COLOR_ID = '7';            // Color for unwatched items
const DEFAULT_COLOR_ID = '11';             // Default color of the calendar
```

#### Finding Calendar Color IDs

Google Calendar uses numeric color IDs:
- `'1'` = Lavender
- `'2'` = Sage
- `'3'` = Grape
- `'4'` = Flamingo
- `'5'` = Banana
- `'6'` = Tangerine
- `'7'` = Peacock
- `'8'` = Graphite
- `'9'` = Blueberry
- `'10'` = Basil
- `'11'` = Tomato

### Step 4: Run the Script Manually (First Time)

1. Select the `syncCalendarAndTasks` function from the dropdown.
2. Click **Run** (▶️).
3. You'll be prompted to authorize the script:
   - Click **Review Permissions**.
   - Select your Google account.
   - Click **Advanced** → **Go to [Your Project Name] (unsafe)**.
   - Click **Allow**.

### Step 5: Set Up Automated Triggers (Optional but Recommended)

To run the sync automatically:

1. In Apps Script, click **Triggers** (⏰ icon in the left sidebar).
2. Click **Add Trigger**.
3. Configure:
   - **Choose which function to run**: `syncCalendarAndTasks`
   - **Choose which deployment**: `Head`
   - **Select event source**: `Time-driven`
   - **Select type of time based trigger**: `Hour timer`
   - **Select hour interval**: `Every hour` (or your preference)
4. Click **Save**.

The script will now run automatically at your chosen interval.

### Step 6: Deploy as a Web App (Recommended)

Transform your script into a powerful, browser-based dashboard! The web app delivers a sleek interface with real-time visual reports, on-demand execution from any device, customizable date ranges, and a stunning UI that adapts to your preferences.

**Deployment Steps:**

1. In Apps Script, click **Deploy** button (upper right).
2. Select **New deployment**.
3. Choose **Web app** as the type.
4. Set **Execute as:** `Me` and **Who has access:** `Only myself` (for personal use) or change as needed.
5. Click **Deploy**.
6. **📋 Copy the Web app URL** (looks like `https://script.google.com/macros/s/...`)

**🌐 IMPORTANT: Save this URL!**
- Bookmark it for quick access
- Add it to your home screen on mobile
- This is your personal sync dashboard

**The web interface includes:**
- 🎨 **Theme Customization** - Choose from 5 color themes (Ocean Blue, Forest Green, Sunset Orange, Purple Dream, Rose Pink).
- 🌓 **Light/Dark Mode** - System, Light, or Dark mode options.
- 📅 **Date Range Picker** - Customize which date range to sync (default: last 6 months).
- 📊 **Visual Reports** - Collapsible phase tables with detailed status indicators.
- 🔄 **One-Click Re-run** - Change dates and re-run without redeploying.

## 🔧 How It Works

The script first fetches: 
- All events from a specified date range (default: last 6 months, customizable via web interface)
- All tasks from your specified task list

It then operates in two phases:

### Phase 1: Create Tasks for Unwatched Events
- Finds events with the "unwatched" color that aren't recurring.
- Creates corresponding tasks in your task list (if they don't already exist).
- Each task includes the event title, date, and location (e.g. streaming platform).

### Phase 2: Task Cleanup and Calendar Event Reset
This phase checks every task and event to ensure the task list is accurate and that statuses are synced:
- **Manual Task Retention:** Incomplete tasks that do not have a matching calendar event (manually added or very old tasks) are **preserved** in your task list.
- **Sync Completion (Mark as Watched):** If a task is marked as `completed`, it is deleted, and the corresponding calendar event's color is reset to the default (`watched`) color.
- **Cleanup:** Incomplete tasks corresponding to events that are already marked as `watched` (default color), or completed tasks without a matching event, are deleted from the task list.
- This ensures both Calendar and Tasks are kept in sync with clear visibility into what happened.


## 🎨 Using the Web Interface

### Theme Customization
The web app includes 5 beautiful color themes, each with light and dark variants: Ocean Blue, Forest Green, Sunset Orange, Purple Dream, Rose Pink.

**To customize:**
1. Use the theme selector in the top-right corner
2. Choose **Mode**: System (auto), Light, or Dark
3. Choose **Color**: Your preferred theme
4. Your selections are saved automatically

### Custom Date Ranges
By default, the script syncs the last 6 months, but you can customize this:

1. Open the web app
2. At the bottom, adjust the date pickers:
   - **From**: Start date
   - **To**: End date
3. Click **🔄 Run Again**
4. The sync runs with your custom date range
5. The report shows which dates were used

**Tip:** Use this to do a full historical sync (e.g., last 2 years) or focus on a specific time period.

### Interactive Reports
The reports show detailed information about what happened during the sync:

- **Phase 1 Table**: Shows all unwatched events and their corresponding tasks.
   - `📌 Exists` - Task already present in task list
   - `➕ Created` - Task newly created in this run
- **Phase 2 Table**: Shows all tasks and their actions (kept, deleted, etc.)
   - `✅ Done → 🗑️ Deleted` - Completed task is deleted.
   - `⏳ Tracking` - Incomplete task with unwatched event (kept)
   - `📂 Kept (No Event)` - Orphaned task without matching event (preserved for manual review)
   - `✓ Watched → 🗑️ Deleted` - Incomplete task but event already watched (deleted)
   - `🔁 Reset to Watched` - Event color changed from unwatched to default
   - `🔴 Unwatched` - Event still marked as unwatched
   - `✓ Watched` - Event already has default/watched color
- Click phase headers to collapse/expand sections
- Hover over table rows for better readability

## 🐞 Troubleshooting

### No tasks are being created
- Verify the `CALENDAR_NAME` exactly matches your calendar name (case-sensitive).
- Confirm the `TASK_LIST_NAME` matches an existing task list.
- Check that your events have the correct color ID.
- Run the script manually and check **Execution log** for errors.

### Tasks aren't deleting
- Make sure the script has permission to both read and write tasks.

### Color isn't updating
- Verify you have edit permissions on the calendar events.
- Ensure the `DEFAULT_COLOR_ID` is a valid color (1-11).

### Date range issues
- The web interface uses local timezone dates (not UTC)
- If dates seem off by one day, check your timezone settings
- The displayed date range in the report shows exactly what was synced

### Web interface not loading
- Ensure you deployed as a **Web app** (not API executable)
- Check that **Who has access** is set correctly
- Try opening the URL in an incognito window
- Clear browser cache and cookies

### View execution logs
**Web Interface:**
- Open the web app to see a visual report of the sync
- The report shows detailed phase-by-phase results with status indicators

**Apps Script Console:**
1. In Apps Script, click **Executions** in the left sidebar
2. Click on a recent execution to see detailed logs
3. Look for `Created:`, `Deleted:`, and `Reset:` counts in the log output

## 📜 License

Free to use and modify for personal use.

---

**Happy syncing!** 📅✅
