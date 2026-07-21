let appState = {
  activeView: 'dashboard', // 'dashboard' or 'settings'
  accounts: [],            // List of { id, label, sessionKey, quotaData: null, lastFetchTime: 0, status: 'offline' }
  agAccount: null,         // Antigravity account { token, email, quotaData, status }
  globalStatus: 'offline', // 'offline', 'syncing', 'online', 'warning', 'error'
  refreshMinutes: 15,      // Background auto-refresh interval in minutes
  alertThreshold: 80       // Session usage % that triggers a notification (0 = off)
};

const DEFAULT_REFRESH_MINUTES = 15;
const DEFAULT_ALERT_THRESHOLD = 80;

let autoRefreshIntervalId = null;

// Initialize app when DOM is fully loaded
document.addEventListener('DOMContentLoaded', () => {
  setupNavigation();
  setupFormHandlers();
  loadAllData();
  setupIPCListeners();
});

// Setup automatic background refresh on the configured interval
function startAutoRefresh() {
  if (autoRefreshIntervalId) {
    clearInterval(autoRefreshIntervalId);
  }
  const minutes = appState.refreshMinutes || DEFAULT_REFRESH_MINUTES;
  autoRefreshIntervalId = setInterval(() => {
    refreshAllAccounts();
  }, minutes * 60 * 1000);
}

// Setup real-time CLI and window visibility listeners
function setupIPCListeners() {
  if (window.claudeAPI) {
    if (typeof window.claudeAPI.onDataChanged === 'function') {
      window.claudeAPI.onDataChanged(() => {
        console.log('Local Claude Code data changed. Triggering sync...');
        refreshAllAccounts();
      });
    }
    if (typeof window.claudeAPI.onWindowShown === 'function') {
      window.claudeAPI.onWindowShown(() => {
        console.log('Widget window shown. Triggering foreground sync...');
        refreshAllAccounts();
      });
    }
  }
}

// Setup Navigation & Actions
function setupNavigation() {
  const toggleBtn = document.getElementById('btn-toggle-settings');
  const homeBtn = document.getElementById('btn-go-home');
  const dashEmptyBtn = document.getElementById('btn-go-to-settings');
  const refreshAllBtn = document.getElementById('btn-refresh-all');
  
  const showView = (view) => {
    appState.activeView = view;
    if (view === 'settings') {
      toggleBtn.classList.add('active');
      document.getElementById('dashboard-view').classList.add('hidden');
      document.getElementById('settings-view').classList.remove('hidden');
      renderSettingsAccountsList();
    } else {
      toggleBtn.classList.remove('active');
      document.getElementById('settings-view').classList.add('hidden');
      document.getElementById('dashboard-view').classList.remove('hidden');
      renderAccountsGrid();
    }
  };

  toggleBtn.addEventListener('click', () => {
    if (appState.activeView === 'dashboard') {
      showView('settings');
    } else {
      showView('dashboard');
    }
  });

  if (homeBtn) {
    homeBtn.addEventListener('click', () => {
      showView('dashboard');
    });
  }

  if (dashEmptyBtn) {
    dashEmptyBtn.addEventListener('click', () => {
      showView('settings');
    });
  }

  // Refresh All button
  if (refreshAllBtn) {
    refreshAllBtn.addEventListener('click', () => {
      refreshAllAccounts();
    });
  }
}

// Load accounts list from tracker-settings.json on startup
async function loadAllData() {
  try {
    const trackerSettings = await window.claudeAPI.getTrackerSettings();
    appState.accounts = trackerSettings.accounts || [];

    if (!Array.isArray(appState.accounts)) {
      appState.accounts = [];
    }

    if (trackerSettings.agAccount) {
      appState.agAccount = trackerSettings.agAccount;
    }

    if (trackerSettings.refreshMinutes) {
      appState.refreshMinutes = trackerSettings.refreshMinutes;
    }
    if (trackerSettings.alertThreshold !== undefined) {
      appState.alertThreshold = trackerSettings.alertThreshold;
    }
    syncRefreshIntervalSelect();
    syncAlertThresholdSelect();

    renderAccountsGrid();
    renderSettingsAccountsList();
    renderAgAccountSettings();
    renderAntigravityGrid();

    // Trigger parallel quota fetch if accounts exist
    let hasWork = false;
    if (appState.accounts.length > 0) hasWork = true;
    if (appState.agAccount) hasWork = true;
    
    if (hasWork) {
      refreshAllAccounts();
    } else {
      updateGlobalStatus();
    }
  } catch (err) {
    console.error('Error loading account settings:', err);
    updateGlobalStatus();
  }
}

// Refresh all accounts in parallel
async function refreshAllAccounts() {
  if (appState.accounts.length === 0 && !appState.agAccount) return;

  // Restart auto-refresh interval timer to avoid double updates
  startAutoRefresh();

  appState.globalStatus = 'syncing';
  updateGlobalStatus();

  // Set individual status to syncing
  appState.accounts.forEach(acc => {
    acc.status = 'syncing';
    updateAccountCardUI(acc);
  });
  
  if (appState.agAccount) {
    appState.agAccount.status = 'syncing';
    renderAntigravityGrid();
  }

  const fetchPromises = appState.accounts.map(acc => fetchAccountQuota(acc));
  if (appState.agAccount) {
    fetchPromises.push(fetchAntigravityQuota());
  }
  
  await Promise.all(fetchPromises);

  // Update global status based on aggregate results
  let allSuccess = true;
  let anySuccess = false;
  
  appState.accounts.forEach(acc => {
    if (acc.status === 'online') {
      anySuccess = true;
    } else {
      allSuccess = false;
    }
  });
  
  if (appState.agAccount) {
    if (appState.agAccount.status === 'online') {
      anySuccess = true;
    } else {
      allSuccess = false;
    }
  }

  if (allSuccess) {
    appState.globalStatus = 'online';
  } else if (anySuccess) {
    appState.globalStatus = 'warning';
  } else {
    appState.globalStatus = 'error';
  }

  updateGlobalStatus();
  renderAccountsGrid();
}

// Extract the current 5-hour session utilization (%) from a quota payload
function getSessionUtilization(quotaData) {
  const q = quotaData || {};
  const fh = q.five_hour || q.fiveHour;
  if (fh && fh.utilization !== undefined) {
    return Math.round(fh.utilization);
  }
  return 0;
}

// Fire a native macOS notification the first time session usage crosses the
// threshold, and arm it again only after usage drops back below the threshold.
function checkSessionUsageAlert(account) {
  const threshold = appState.alertThreshold;
  if (!threshold || threshold <= 0) return; // Notifications disabled

  const sessionPct = getSessionUtilization(account.quotaData);

  if (sessionPct >= threshold) {
    if (!account.alertedHighUsage) {
      account.alertedHighUsage = true;
      if (window.claudeAPI && typeof window.claudeAPI.notify === 'function') {
        window.claudeAPI.notify({
          title: `${account.label} — ${sessionPct}% of session used`,
          body: `Your current 5-hour session has crossed ${threshold}% usage.`
        });
      }
    }
  } else {
    // Reset once the session window resets / usage falls back down
    account.alertedHighUsage = false;
  }
}

// Fetch live limits for a single account
async function fetchAccountQuota(account) {
  try {
    const result = await window.claudeAPI.fetchLiveLimits(account.sessionKey);
    if (result && result.success && result.data) {
      account.quotaData = result.data;
      account.lastFetchTime = Date.now();
      account.status = 'online';
      checkSessionUsageAlert(account);
    } else {
      account.quotaData = null;
      account.status = 'error';
      account.errorMsg = result ? result.error : 'Connection error';
    }
  } catch (e) {
    account.quotaData = null;
    account.status = 'error';
    account.errorMsg = e.message;
  }
  updateAccountCardUI(account);
}

// Fetch Antigravity Quota
async function fetchAntigravityQuota() {
  if (!appState.agAccount || !appState.agAccount.token) return;
  try {
    const result = await window.claudeAPI.antigravityFetchQuota(appState.agAccount.token);
    if (result && result.success && result.data) {
      appState.agAccount.quotaData = result.data;
      appState.agAccount.status = 'online';
    } else {
      appState.agAccount.status = 'error';
    }
  } catch(e) {
    appState.agAccount.status = 'error';
  }
  renderAntigravityGrid();
}

// Setup Account Form submission & Key management
function setupFormHandlers() {
  const refreshSelect = document.getElementById('refresh-interval');
  if (refreshSelect) {
    refreshSelect.addEventListener('change', async (e) => {
      const minutes = parseInt(e.target.value, 10);
      if (!minutes || minutes <= 0) return;
      appState.refreshMinutes = minutes;
      await saveAccountsToDisk();
      startAutoRefresh(); // Restart the timer with the new interval
    });
  }

  const alertSelect = document.getElementById('alert-threshold');
  if (alertSelect) {
    alertSelect.addEventListener('change', async (e) => {
      const threshold = parseInt(e.target.value, 10);
      appState.alertThreshold = isNaN(threshold) ? 0 : threshold;
      // Re-arm alerts so a new threshold can fire against current usage
      appState.accounts.forEach(acc => { acc.alertedHighUsage = false; });
      await saveAccountsToDisk();
      // Evaluate immediately against the latest known usage
      appState.accounts.forEach(acc => {
        if (acc.status === 'online') checkSessionUsageAlert(acc);
      });
    });
  }

  const form = document.getElementById('add-account-form');
  if (form) {
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      
      const labelInput = document.getElementById('account-label');
      const keyInput = document.getElementById('account-session-key');
      const label = labelInput.value.trim();
      const keyVal = keyInput.value.trim();
      
      if (!label || !keyVal) return;

      const newAccount = {
        id: 'acc_' + Math.random().toString(36).substr(2, 9),
        label: label,
        sessionKey: keyVal,
        quotaData: null,
        lastFetchTime: 0,
        status: 'syncing'
      };

      appState.accounts.push(newAccount);
      
      // Save list to disk
      const success = await saveAccountsToDisk();
      if (success) {
        // Clear form
        form.reset();
        
        // Return to dashboard
        document.getElementById('btn-toggle-settings').click();
        
        // Fetch new account limits
        await fetchAccountQuota(newAccount);
        renderAccountsGrid();
        updateGlobalStatus();
      } else {
        alert('Failed to save account.');
      }
    });
  }
}

// Save accounts array to local profile tracker-settings.json
async function saveAccountsToDisk() {
  // Strip transient status values before writing config file
  const accountsToSave = appState.accounts.map(acc => ({
    id: acc.id,
    label: acc.label,
    sessionKey: acc.sessionKey
  }));
  
  let agAccountToSave = null;
  if (appState.agAccount) {
    agAccountToSave = { token: appState.agAccount.token, email: appState.agAccount.email };
  }
  
  const result = await window.claudeAPI.saveTrackerSettings({
    accounts: accountsToSave,
    agAccount: agAccountToSave,
    refreshMinutes: appState.refreshMinutes,
    alertThreshold: appState.alertThreshold
  });
  return result && result.success;
}

// Reflect the current interval in the settings dropdown
function syncRefreshIntervalSelect() {
  const select = document.getElementById('refresh-interval');
  if (select) select.value = String(appState.refreshMinutes);
}

// Reflect the current alert threshold in the settings dropdown
function syncAlertThresholdSelect() {
  const select = document.getElementById('alert-threshold');
  if (select) select.value = String(appState.alertThreshold);
}

// Render quota cards on dashboard
function renderAccountsGrid() {
  const container = document.getElementById('accounts-container');
  const emptyState = document.getElementById('dashboard-empty-state');
  
  if (!container || !emptyState) return;

  if (appState.accounts.length === 0) {
    container.innerHTML = '';
    emptyState.classList.remove('hidden');
    return;
  }

  emptyState.classList.add('hidden');
  container.innerHTML = '';

  appState.accounts.forEach(acc => {
    const card = document.createElement('div');
    card.className = 'account-card';
    card.id = `card-${acc.id}`;
    
    // Card Header
    const header = document.createElement('div');
    header.className = 'account-card-header';
    
    const info = document.createElement('div');
    info.className = 'account-info';
    
    const dot = document.createElement('span');
    dot.className = `pulse-dot ${acc.status === 'error' ? 'error' : acc.status === 'syncing' ? 'warning' : 'online'}`;
    
    const name = document.createElement('span');
    name.className = 'account-name';
    name.textContent = acc.label;

    info.appendChild(dot);
    info.appendChild(name);
    
    const refreshBtn = document.createElement('button');
    refreshBtn.className = 'btn-icon';
    refreshBtn.title = 'Refresh Account';
    refreshBtn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>`;
    refreshBtn.addEventListener('click', async (e) => {
      e.stopPropagation();
      acc.status = 'syncing';
      updateAccountCardUI(acc);
      await fetchAccountQuota(acc);
      renderAccountsGrid();
      updateGlobalStatus();
    });

    header.appendChild(info);
    header.appendChild(refreshBtn);
    card.appendChild(header);

    // Card Body
    const body = document.createElement('div');
    body.className = 'account-card-body';

    if (acc.status === 'error') {
      body.innerHTML = `
        <div style="color: var(--error-color); font-size: 12px; text-align: center; padding: 10px 0; line-height: 1.4;">
          <strong>Sync Failed:</strong><br>${acc.errorMsg || 'Unauthorized / Invalid Key'}
        </div>
      `;
    } else if (acc.status === 'syncing' && !acc.quotaData) {
      body.innerHTML = `
        <div style="color: var(--text-dimmed); font-size: 12px; text-align: center; padding: 10px 0;">
          Syncing quotas...
        </div>
      `;
    } else {
      const q = acc.quotaData || {};
      
      let sessionPct = getSessionUtilization(q);
      let weeklyPct = 0;
      let sessionResetsAt = null;
      let weeklyResetsAt = null;

      if (q.five_hour || q.fiveHour) {
        const fh = q.five_hour || q.fiveHour;
        sessionResetsAt = fh.resets_at || fh.resetsAt;
      }
      if (q.seven_day || q.sevenDay) {
        const sd = q.seven_day || q.sevenDay;
        weeklyPct = sd.utilization !== undefined ? Math.round(sd.utilization) : 0;
        weeklyResetsAt = sd.resets_at || sd.resetsAt;
      }

      const sessionBarClass = sessionPct >= 95 ? 'danger' : sessionPct >= 80 ? 'warning' : '';
      const weeklyBarClass = weeklyPct >= 95 ? 'danger' : weeklyPct >= 80 ? 'warning' : 'weekly';

      body.innerHTML = `
        <!-- Session Limits -->
        <div class="quota-item">
          <div class="quota-header-row">
            <span class="quota-title">Current Session (5h Window)</span>
            <span class="quota-desc">${sessionPct}% used</span>
          </div>
          <div class="progress-bar-container">
            <div class="progress-bar-fill ${sessionBarClass}" style="width: ${sessionPct}%;"></div>
          </div>
          <div class="quota-footer-row">${sessionResetsAt ? 'Resets ' + formatTimeUntil(sessionResetsAt) : 'Resets periodically'}</div>
        </div>

        <!-- Weekly Limits -->
        <div class="quota-item">
          <div class="quota-header-row">
            <span class="quota-title">Weekly Account Limits</span>
            <span class="quota-desc">${weeklyPct}% used</span>
          </div>
          <div class="progress-bar-container">
            <div class="progress-bar-fill ${weeklyBarClass}" style="width: ${weeklyPct}%;"></div>
          </div>
          <div class="quota-footer-row">${weeklyResetsAt ? 'Resets ' + formatTimeUntil(weeklyResetsAt) : 'Resets weekly'}</div>
        </div>
      `;

      // Messaging UI: Only show if no session is currently running (sessionPct === 0)
      if (sessionPct === 0) {
        const messagingContainer = document.createElement('div');
        messagingContainer.className = 'messaging-container';
        
        const input = document.createElement('textarea');
        input.className = 'messaging-input';
        input.placeholder = 'Message Claude...';
        input.rows = 1;
        
        const btn = document.createElement('button');
        btn.className = 'btn btn-primary btn-start-session';
        btn.textContent = 'Start session now';
        
        btn.addEventListener('click', () => {
          const prompt = input.value.trim();
          if (!prompt) return;
          btn.textContent = 'Starting...';
          btn.disabled = true;
          
          if (window.claudeAPI && typeof window.claudeAPI.startSession === 'function') {
            window.claudeAPI.startSession(acc.id, acc.sessionKey, prompt)
              .then(res => {
                btn.textContent = 'Start session now';
                btn.disabled = false;
                input.value = '';
              })
              .catch(err => {
                console.error('Failed to start session', err);
                btn.textContent = 'Start session now';
                btn.disabled = false;
              });
          }
        });
        
        messagingContainer.appendChild(input);
        messagingContainer.appendChild(btn);
        body.appendChild(messagingContainer);
      }
    }

    card.appendChild(body);
    container.appendChild(card);
  });
}

// ID of the account currently being edited inline, or null
let editingAccountId = null;

// Render accounts in settings list
function renderSettingsAccountsList() {
  const container = document.getElementById('accounts-settings-list');
  if (!container) return;

  if (appState.accounts.length === 0) {
    editingAccountId = null;
    container.innerHTML = `<div style="color: var(--text-dimmed); font-size: 12px; text-align: center; padding: 15px 0;">No accounts added yet.</div>`;
    return;
  }

  container.innerHTML = '';
  appState.accounts.forEach(acc => {
    const row = document.createElement('div');
    row.className = 'account-settings-row';

    if (editingAccountId === acc.id) {
      row.classList.add('editing');
      buildAccountEditRow(row, acc);
    } else {
      buildAccountViewRow(row, acc);
    }

    container.appendChild(row);
  });
}

// Display mode: label + masked key, with Edit and Remove actions
function buildAccountViewRow(row, acc) {
  const info = document.createElement('div');
  info.className = 'account-settings-info';

  const name = document.createElement('span');
  name.className = 'account-settings-label';
  name.textContent = acc.label;

  const mask = document.createElement('span');
  mask.className = 'account-settings-mask';
  const key = acc.sessionKey || '';
  mask.textContent = key.length > 20
    ? key.substring(0, 12) + '...' + key.substring(key.length - 6)
    : '••••••••••••';

  info.appendChild(name);
  info.appendChild(mask);

  const actions = document.createElement('div');
  actions.className = 'account-settings-actions';

  const editBtn = document.createElement('button');
  editBtn.className = 'btn btn-secondary btn-action';
  editBtn.textContent = 'Edit';
  editBtn.addEventListener('click', () => {
    editingAccountId = acc.id;
    renderSettingsAccountsList();
  });

  const deleteBtn = document.createElement('button');
  deleteBtn.className = 'btn btn-danger btn-action';
  deleteBtn.textContent = 'Remove';
  deleteBtn.addEventListener('click', async () => {
    if (confirm(`Remove account "${acc.label}"?`)) {
      appState.accounts = appState.accounts.filter(a => a.id !== acc.id);
      const success = await saveAccountsToDisk();
      if (success) {
        if (editingAccountId === acc.id) editingAccountId = null;
        renderSettingsAccountsList();
        renderAccountsGrid();
        updateGlobalStatus();
      } else {
        alert('Failed to remove account.');
      }
    }
  });

  actions.appendChild(editBtn);
  actions.appendChild(deleteBtn);

  row.appendChild(info);
  row.appendChild(actions);
}

// Edit mode: editable label + session key inputs, with Save and Cancel
function buildAccountEditRow(row, acc) {
  const form = document.createElement('div');
  form.className = 'account-settings-edit';

  const labelGroup = document.createElement('div');
  labelGroup.className = 'form-group';
  const labelLabel = document.createElement('label');
  labelLabel.textContent = 'Account Label';
  const labelInput = document.createElement('input');
  labelInput.type = 'text';
  labelInput.value = acc.label || '';
  labelInput.placeholder = 'e.g. Personal, Work, Client A';
  labelGroup.appendChild(labelLabel);
  labelGroup.appendChild(labelInput);

  const keyGroup = document.createElement('div');
  keyGroup.className = 'form-group';
  const keyLabel = document.createElement('label');
  keyLabel.textContent = 'Session Key (sessionKey)';
  const keyInput = document.createElement('input');
  keyInput.type = 'password';
  keyInput.value = acc.sessionKey || '';
  keyInput.placeholder = 'Paste sk-ant-sid02-...';
  const keyHelp = document.createElement('span');
  keyHelp.className = 'field-help';
  keyHelp.textContent = 'Leave unchanged to keep the existing key.';
  keyGroup.appendChild(keyLabel);
  keyGroup.appendChild(keyInput);
  keyGroup.appendChild(keyHelp);

  const actions = document.createElement('div');
  actions.className = 'account-settings-actions';

  const saveBtn = document.createElement('button');
  saveBtn.className = 'btn btn-primary btn-action';
  saveBtn.textContent = 'Save';

  const cancelBtn = document.createElement('button');
  cancelBtn.className = 'btn btn-secondary btn-action';
  cancelBtn.textContent = 'Cancel';
  cancelBtn.addEventListener('click', () => {
    editingAccountId = null;
    renderSettingsAccountsList();
  });

  const commitEdit = async () => {
    const newLabel = labelInput.value.trim();
    const newKey = keyInput.value.trim();
    if (!newLabel || !newKey) {
      alert('Both label and session key are required.');
      return;
    }

    const keyChanged = newKey !== acc.sessionKey;
    acc.label = newLabel;
    acc.sessionKey = newKey;

    const success = await saveAccountsToDisk();
    if (!success) {
      alert('Failed to save account.');
      return;
    }

    editingAccountId = null;

    // Re-validate against the server if the key changed
    if (keyChanged) {
      acc.status = 'syncing';
    }
    renderSettingsAccountsList();
    renderAccountsGrid();

    if (keyChanged) {
      await fetchAccountQuota(acc);
      renderAccountsGrid();
    }
    updateGlobalStatus();
  };

  saveBtn.addEventListener('click', commitEdit);
  labelInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') commitEdit(); });
  keyInput.addEventListener('keydown', (e) => { if (e.key === 'Enter') commitEdit(); });

  actions.appendChild(saveBtn);
  actions.appendChild(cancelBtn);

  form.appendChild(labelGroup);
  form.appendChild(keyGroup);
  form.appendChild(actions);

  row.appendChild(form);
}

// Update card status dot instantly
function updateAccountCardUI(acc) {
  const card = document.getElementById(`card-${acc.id}`);
  if (!card) return;
  const dot = card.querySelector('.pulse-dot');
  if (dot) {
    dot.className = `pulse-dot ${acc.status === 'error' ? 'error' : acc.status === 'syncing' ? 'warning' : 'online'}`;
  }
}

// Update global status bar & sync indicator
function updateGlobalStatus() {
  const dot = document.getElementById('global-sync-dot');
  const text = document.getElementById('global-sync-text');
  const time = document.getElementById('last-sync-time');

  if (!dot || !text) return;

  if (appState.accounts.length === 0) {
    dot.className = 'pulse-dot error';
    text.textContent = 'No Accounts Connected';
    if (time) time.textContent = 'Last Sync: --';
    return;
  }

  dot.className = `pulse-dot ${
    appState.globalStatus === 'syncing' ? 'warning' :
    appState.globalStatus === 'online' ? 'online' :
    appState.globalStatus === 'warning' ? 'warning' : 'error'
  }`;

  text.textContent = 
    appState.globalStatus === 'syncing' ? 'Syncing...' :
    appState.globalStatus === 'online' ? 'Synced' :
    appState.globalStatus === 'warning' ? 'Sync issues' : 'Offline / Error';

  const latestFetch = Math.max(...appState.accounts.map(a => a.lastFetchTime || 0));
  if (latestFetch > 0 && time) {
    time.textContent = `Last Sync: ${new Date(latestFetch).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })}`;
  }
}

// Format reset target ISO date string to remaining time countdown
function formatTimeUntil(isoString) {
  if (!isoString) return '--';
  try {
    const targetDate = new Date(isoString);
    const diffMs = targetDate - new Date();
    if (diffMs <= 0) return 'any moment';

    const totalMin = Math.floor(diffMs / 60000);
    const hrs = Math.floor(totalMin / 60);
    const mins = totalMin % 60;

    if (hrs >= 24) {
      const dayName = targetDate.toLocaleDateString('en-US', { weekday: 'short' });
      const timeStr = targetDate.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit', hour12: true });
      return `${dayName} ${timeStr}`;
    }
    if (hrs > 0) {
      return `in ${hrs}h ${mins}m`;
    }
    return `in ${mins}m`;
  } catch (e) {
    return 'soon';
  }
}

// Fetch Antigravity Quota
async function fetchAntigravityQuota() {
  if (!appState.agAccount || !appState.agAccount.token) return;
  try {
    const result = await window.claudeAPI.antigravityFetchQuota(appState.agAccount.token);
    if (result && result.success && result.data) {
      appState.agAccount.quotaData = result.data;
      if (result.email) {
        appState.agAccount.email = result.email;
      }
      appState.agAccount.status = 'online';
    } else {
      appState.agAccount.status = 'error';
    }
  } catch(e) {
    appState.agAccount.status = 'error';
  }
  renderAgAccountSettings();
  renderAntigravityGrid();
}

// Setup Account Form submission & Key management
function setupFormHandlers() {
  const refreshSelect = document.getElementById('refresh-interval');
  if (refreshSelect) {
    refreshSelect.addEventListener('change', async (e) => {
      const minutes = parseInt(e.target.value, 10);
      if (!minutes || minutes <= 0) return;
      appState.refreshMinutes = minutes;
      await saveAccountsToDisk();
      startAutoRefresh();
    });
  }

  const alertSelect = document.getElementById('alert-threshold');
  if (alertSelect) {
    alertSelect.addEventListener('change', async (e) => {
      appState.alertThreshold = parseInt(e.target.value, 10) || 0;
      await saveAccountsToDisk();
    });
  }

  const addAccountForm = document.getElementById('add-account-form');
  if (addAccountForm) {
    addAccountForm.addEventListener('submit', async (e) => {
      e.preventDefault();
      const labelInput = document.getElementById('account-label');
      const keyInput = document.getElementById('account-session-key');

      const label = labelInput.value.trim();
      const sessionKey = keyInput.value.trim();

      if (!label || !sessionKey) return;

      const newAccount = {
        id: 'acc_' + Date.now(),
        label,
        sessionKey,
        quotaData: null,
        lastFetchTime: 0,
        status: 'offline'
      };

      appState.accounts.push(newAccount);
      await saveAccountsToDisk();

      labelInput.value = '';
      keyInput.value = '';

      renderAccountsGrid();
      renderSettingsAccountsList();
      fetchAccountQuota(newAccount);
    });
  }
}

function renderAgAccountSettings() {
  const infoDiv = document.getElementById('ag-account-info');
  const loginBtn = document.getElementById('btn-ag-login');
  const logoutBtn = document.getElementById('btn-ag-logout');
  
  if (!infoDiv || !loginBtn || !logoutBtn) return;

  if (appState.agAccount) {
    infoDiv.textContent = `CLI Linked (${appState.agAccount.email || 'eng.aminurislam@gmail.com'})`;
    loginBtn.classList.add('hidden');
    logoutBtn.classList.remove('hidden');
  } else {
    infoDiv.textContent = 'Not linked.';
    loginBtn.classList.remove('hidden');
    logoutBtn.classList.add('hidden');
  }

  // Setup listeners if not already
  if (!loginBtn.dataset.initialized) {
    loginBtn.dataset.initialized = 'true';
    
    loginBtn.addEventListener('click', async () => {
      loginBtn.textContent = 'Syncing...';
      loginBtn.disabled = true;
      try {
        const res = await window.claudeAPI.antigravityLogin();
        if (res.success) {
          appState.agAccount = { token: res.token, email: res.email, status: 'syncing' };
          await saveAccountsToDisk();
          renderAgAccountSettings();
          await fetchAntigravityQuota();
          updateGlobalStatus();
        } else {
          alert('Sync failed: ' + res.error);
        }
      } catch (e) {
        console.error(e);
        alert('Sync error.');
      }
      loginBtn.textContent = 'Sync with Antigravity / Gemini CLI';
      loginBtn.disabled = false;
    });

    logoutBtn.addEventListener('click', async () => {
      appState.agAccount = null;
      await saveAccountsToDisk();
      renderAgAccountSettings();
      renderAntigravityGrid();
      updateGlobalStatus();
    });
  }
}

function renderAntigravityGrid() {
  const container = document.getElementById('antigravity-container');
  if (!container) return;

  if (!appState.agAccount) {
    container.innerHTML = '';
    return;
  }

  const ag = appState.agAccount;
  const isSyncing = ag.status === 'syncing';
  const isError = ag.status === 'error';

  const card = document.createElement('div');
  card.className = 'account-card';
  card.id = 'card-antigravity';

  // Header
  const header = document.createElement('div');
  header.className = 'account-card-header';

  const info = document.createElement('div');
  info.className = 'account-info';

  const dot = document.createElement('span');
  dot.className = `pulse-dot ${isError ? 'error' : isSyncing ? 'warning' : 'online'}`;

  const name = document.createElement('span');
  name.className = 'account-name';
  name.textContent = 'Antigravity / Gemini CLI';

  const emailSpan = document.createElement('span');
  emailSpan.className = 'account-email';
  emailSpan.style.cssText = 'font-size: 11px; color: var(--text-muted); margin-left: 6px;';
  emailSpan.textContent = ag.email || 'eng.aminurislam@gmail.com';

  info.appendChild(dot);
  info.appendChild(name);
  info.appendChild(emailSpan);

  const refreshBtn = document.createElement('button');
  refreshBtn.className = 'btn-icon';
  refreshBtn.title = 'Refresh Antigravity Quota';
  refreshBtn.innerHTML = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"/><polyline points="1 20 1 14 7 14"/><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"/></svg>`;
  refreshBtn.addEventListener('click', async (e) => {
    e.stopPropagation();
    ag.status = 'syncing';
    renderAntigravityGrid();
    await fetchAntigravityQuota();
    updateGlobalStatus();
  });

  header.appendChild(info);
  header.appendChild(refreshBtn);
  card.appendChild(header);

  // Body
  const body = document.createElement('div');
  body.className = 'account-card-body';

  if (isError) {
    body.innerHTML = `
      <div style="color: var(--error-color); font-size: 12px; text-align: center; padding: 10px 0;">
        Sync Failed: Could not fetch local Antigravity CLI quota
      </div>
    `;
  } else if (isSyncing && !ag.quotaData) {
    body.innerHTML = `
      <div style="color: var(--text-dimmed); font-size: 12px; text-align: center; padding: 10px 0;">
        Syncing Antigravity quotas...
      </div>
    `;
  } else if (ag.quotaData) {
    const d = ag.quotaData;
    let itemsHtml = '';

    const getBarClass = (pct) => {
      if (pct <= 20) return 'danger';
      if (pct <= 50) return 'warning';
      return 'green';
    };

    const renderQuotaItem = (groupTitle, limitTitle, pct, rawPct, resetsIn) => {
      const barClass = getBarClass(pct);
      const resetText = resetsIn ? 'Refreshes ' + formatTimeUntil(resetsIn) : 'Quota available';
      const descText = pct === 100 ? '100% remaining' : `${rawPct || pct}% remaining`;

      return `
        <div class="quota-item" style="margin-bottom: 12px;">
          <div class="quota-header-row">
            <span class="quota-title">${groupTitle} — ${limitTitle}</span>
            <span class="quota-desc">${descText}</span>
          </div>
          <div class="progress-bar-container">
            <div class="progress-bar-fill ${barClass}" style="width: ${pct}%;"></div>
          </div>
          <div class="quota-footer-row">${resetText}</div>
        </div>
      `;
    };

    if (d.gemini) {
      const descLine = d.gemini.description ? `<div style="font-size: 11px; font-weight: 600; color: var(--accent-hover); margin-bottom: 8px;">${d.gemini.name || 'Gemini Models'} <span style="font-weight: normal; color: var(--text-dimmed);">(${d.gemini.description})</span></div>` : `<div style="font-size: 11px; font-weight: 600; color: var(--accent-hover); margin-bottom: 8px;">${d.gemini.name || 'Gemini Models'}</div>`;
      itemsHtml += descLine;
      itemsHtml += renderQuotaItem('Gemini', 'Weekly Limit', d.gemini.weeklyPct, d.gemini.weeklyRawPct, d.gemini.weeklyResetsIn);
      itemsHtml += renderQuotaItem('Gemini', 'Five Hour Limit', d.gemini.fiveHourPct, d.gemini.fiveHourRawPct, d.gemini.fiveHourResetsIn);
    }

    if (d.claudeGpt) {
      if (itemsHtml) itemsHtml += `<div style="height: 1px; background: var(--border-color); margin: 12px 0;"></div>`;
      const descLine = d.claudeGpt.description ? `<div style="font-size: 11px; font-weight: 600; color: var(--accent-hover); margin-bottom: 8px;">${d.claudeGpt.name || 'Claude & GPT Models'} <span style="font-weight: normal; color: var(--text-dimmed);">(${d.claudeGpt.description})</span></div>` : `<div style="font-size: 11px; font-weight: 600; color: var(--accent-hover); margin-bottom: 8px;">${d.claudeGpt.name || 'Claude & GPT Models'}</div>`;
      itemsHtml += descLine;
      itemsHtml += renderQuotaItem('Claude & GPT', 'Weekly Limit', d.claudeGpt.weeklyPct, d.claudeGpt.weeklyRawPct, d.claudeGpt.weeklyResetsIn);
      itemsHtml += renderQuotaItem('Claude & GPT', 'Five Hour Limit', d.claudeGpt.fiveHourPct, d.claudeGpt.fiveHourRawPct, d.claudeGpt.fiveHourResetsIn);
    }

    body.innerHTML = itemsHtml || '<div style="color: var(--text-dimmed); font-size: 12px; text-align: center; padding: 10px 0;">No quota data available</div>';
  }

  card.appendChild(body);
  container.innerHTML = '';
  container.appendChild(card);
}
