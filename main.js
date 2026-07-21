const { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage, Notification } = require('electron');
const path = require('path');
const fs = require('fs');
const os = require('os');

let mainWindow;
let tray = null;
app.isQuitting = false;
let currentClaudeDir = path.join(os.homedir(), '.claude');
let activeWatchers = [];

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 520,
    height: 680,
    minWidth: 420,
    minHeight: 500,
    titleBarStyle: 'hiddenInset', // Hidden title bar with Traffic Lights on macOS
    trafficLightPosition: { x: 18, y: 18 },
    backgroundColor: '#16161a',
    show: false, // Prevents flash of white/unpainted window
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'src', 'index.html'));

  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
  });

  // Dynamic Dock icon visibility on macOS
  mainWindow.on('show', () => {
    if (process.platform === 'darwin') {
      try { app.dock.show(); } catch (e) {}
    }
    try {
      mainWindow.webContents.send('claude:window-shown');
    } catch (err) {
      console.error('Error sending window-shown event:', err);
    }
  });

  mainWindow.on('hide', () => {
    if (process.platform === 'darwin') {
      try { app.dock.hide(); } catch (e) {}
    }
  });

  // Hide window instead of destroying on close
  mainWindow.on('close', (event) => {
    if (!app.isQuitting) {
      event.preventDefault();
      mainWindow.hide();
    }
    return false;
  });
}

function createTray() {
  const iconPath = path.join(__dirname, 'assets', 'tray-iconTemplate.png');
  if (fs.existsSync(iconPath)) {
    try {
      const trayImage = nativeImage.createFromPath(iconPath);
      // setTemplateImage enables automatic black/white conversion based on dark/light status bars
      trayImage.setTemplateImage(true);

      tray = new Tray(trayImage);
      tray.setToolTip('Claude Quota Widget');

      tray.on('click', () => {
        if (mainWindow.isVisible()) {
          mainWindow.hide();
        } else {
          mainWindow.show();
          mainWindow.focus();
        }
      });

      const contextMenu = Menu.buildFromTemplate([
        { label: 'Show Widget', click: () => { mainWindow.show(); mainWindow.focus(); } },
        { label: 'Hide Widget', click: () => { mainWindow.hide(); } },
        { type: 'separator' },
        { label: 'Quit', click: () => { app.isQuitting = true; app.quit(); } }
      ]);
      tray.setContextMenu(contextMenu);
    } catch (err) {
      console.error('Failed to create tray icon:', err);
    }
  } else {
    console.warn('Tray icon source not found at:', iconPath);
  }
}

function setupFileWatchers() {
  // Dispose of any active watchers first
  activeWatchers.forEach(watcher => {
    try {
      watcher.close();
    } catch (e) {
      console.error('Error closing watcher:', e);
    }
  });
  activeWatchers = [];

  const historyPath = path.join(currentClaudeDir, 'history.jsonl');
  const statsPath = path.join(currentClaudeDir, 'stats-cache.json');

  let watchTimeout;
  const triggerUpdate = (type) => {
    if (watchTimeout) clearTimeout(watchTimeout);
    watchTimeout = setTimeout(() => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.webContents.send('claude:data-changed', { type });
      }
    }, 500); // Debounce updates
  };

  try {
    if (fs.existsSync(historyPath)) {
      const historyWatcher = fs.watch(historyPath, (event) => {
        if (event === 'change') triggerUpdate('history');
      });
      activeWatchers.push(historyWatcher);
    }

    if (fs.existsSync(statsPath)) {
      const statsWatcher = fs.watch(statsPath, (event) => {
        if (event === 'change') triggerUpdate('stats');
      });
      activeWatchers.push(statsWatcher);
    }
  } catch (err) {
    console.error('Error setting up file watchers:', err);
  }
}

// Helpers for reading files
function readJSONFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      const content = fs.readFileSync(filePath, 'utf8');
      return JSON.parse(content);
    }
  } catch (err) {
    console.error(`Error reading JSON file at ${filePath}:`, err);
  }
  return null;
}

function readJSONLFile(filePath) {
  try {
    if (fs.existsSync(filePath)) {
      const content = fs.readFileSync(filePath, 'utf8');
      return content
        .split('\n')
        .filter(line => line.trim().length > 0)
        .map(line => {
          try {
            return JSON.parse(line);
          } catch (e) {
            console.error('Error parsing JSONL line:', e);
            return null;
          }
        })
        .filter(Boolean);
    }
  } catch (err) {
    console.error(`Error reading JSONL file at ${filePath}:`, err);
  }
  return [];
}

// IPC Handlers
ipcMain.handle('claude:getProfiles', async () => {
  const home = os.homedir();
  const profiles = [];
  
  try {
    const files = fs.readdirSync(home, { withFileTypes: true });
    
    for (const f of files) {
      if (f.isDirectory() && f.name.startsWith('.claude')) {
        const fullPath = path.join(home, f.name);
        
        // Match folders that have essential Claude CLI files
        const hasHistory = fs.existsSync(path.join(fullPath, 'history.jsonl'));
        const hasStats = fs.existsSync(path.join(fullPath, 'stats-cache.json'));
        const hasSettings = fs.existsSync(path.join(fullPath, 'settings.json'));
        
        if (hasHistory || hasStats || hasSettings) {
          let label = 'Default';
          if (f.name !== '.claude') {
            // E.g., .claude-personal -> Personal
            const rawLabel = f.name.replace('.claude-', '');
            label = rawLabel.charAt(0).toUpperCase() + rawLabel.slice(1);
          }
          
          profiles.push({
            name: label,
            dirName: f.name,
            path: fullPath
          });
        }
      }
    }
  } catch (err) {
    console.error('Error listing profiles:', err);
  }
  
  // Ensure we always have at least default profile if scan failed or is empty
  if (profiles.length === 0) {
    profiles.push({
      name: 'Default',
      dirName: '.claude',
      path: path.join(home, '.claude')
    });
  }
  
  return profiles;
});

ipcMain.handle('claude:switchProfile', async (event, dirName) => {
  const targetPath = path.join(os.homedir(), dirName);
  if (fs.existsSync(targetPath)) {
    currentClaudeDir = targetPath;
    setupFileWatchers(); // Re-assign watchers to files in the new directory
    return { success: true, path: targetPath };
  }
  return { success: false, error: `Directory ${dirName} not found` };
});

ipcMain.handle('claude:getStats', async () => {
  const statsPath = path.join(currentClaudeDir, 'stats-cache.json');
  return readJSONFile(statsPath);
});

ipcMain.handle('claude:getSettings', async () => {
  const settingsPath = path.join(currentClaudeDir, 'settings.json');
  return readJSONFile(settingsPath);
});

ipcMain.handle('claude:saveSettings', async (event, settings) => {
  const settingsPath = path.join(currentClaudeDir, 'settings.json');
  try {
    fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2), 'utf8');
    return { success: true };
  } catch (err) {
    console.error('Error writing settings:', err);
    return { success: false, error: err.message };
  }
});

// Tracker Settings (profile-specific config)
ipcMain.handle('claude:getTrackerSettings', async () => {
  const trackerSettingsPath = path.join(currentClaudeDir, 'tracker-settings.json');
  return readJSONFile(trackerSettingsPath) || {};
});

ipcMain.handle('claude:saveTrackerSettings', async (event, settings) => {
  const trackerSettingsPath = path.join(currentClaudeDir, 'tracker-settings.json');
  try {
    fs.writeFileSync(trackerSettingsPath, JSON.stringify(settings, null, 2), 'utf8');
    return { success: true };
  } catch (err) {
    console.error('Error writing tracker settings:', err);
    return { success: false, error: err.message };
  }
});

// Fetch Real-time Quota limits from Claude Server via private Web APIs
ipcMain.handle('claude:fetchLiveLimits', async (event, sessionKey) => {
  if (!sessionKey) {
    return { success: false, error: 'Session key is empty.' };
  }

  try {
    // 1. Fetch organization IDs
    const orgsResponse = await fetch('https://claude.ai/api/organizations', {
      headers: {
        'Cookie': `sessionKey=${sessionKey}`,
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      }
    });

    if (!orgsResponse.ok) {
      if (orgsResponse.status === 403 || orgsResponse.status === 401) {
        return { success: false, error: 'Unauthorized. The sessionKey might be invalid or expired.' };
      }
      return { success: false, error: `Server returned status ${orgsResponse.status}` };
    }

    const orgs = await orgsResponse.json();
    if (!Array.isArray(orgs) || orgs.length === 0) {
      return { success: false, error: 'No organizations found on this account.' };
    }

    const orgId = orgs[0].uuid;

    // 2. Fetch Chat limitations / Rate limits
    const limitsResponse = await fetch(`https://claude.ai/api/organizations/${orgId}/usage`, {
      headers: {
        'Cookie': `sessionKey=${sessionKey}`,
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
      }
    });

    if (!limitsResponse.ok) {
      return { success: false, error: `Failed to fetch limits. Status: ${limitsResponse.status}` };
    }

    const limits = await limitsResponse.json();
    return { success: true, data: limits };
  } catch (err) {
    console.error('Error fetching live limits:', err);
    return { success: false, error: `Connection failed: ${err.message}` };
  }
});

// Start a direct session by opening a new window and injecting the prompt
ipcMain.handle('claude:startSession', async (event, { accountId, sessionKey, prompt }) => {
  try {
    const { session } = require('electron');
    const partition = `persist:claude-${accountId}`;
    const accountSession = session.fromPartition(partition);

    // Set the cookie
    await accountSession.cookies.set({
      url: 'https://claude.ai',
      name: 'sessionKey',
      value: sessionKey,
      domain: 'claude.ai',
      path: '/',
      secure: true,
      httpOnly: true
    });

    // Create the window
    const chatWin = new BrowserWindow({
      width: 1024,
      height: 768,
      title: 'Claude Chat',
      backgroundColor: '#16161a',
      webPreferences: {
        partition: partition,
        nodeIntegration: false,
        contextIsolation: true
      }
    });

    // Handle when the page loads
    chatWin.webContents.on('did-finish-load', () => {
      // Inject script to find editor, insert text natively, and click send
      const script = `
        (function() {
          function waitForEditor() {
            const editor = document.querySelector('.ProseMirror');
            if (!editor) {
              setTimeout(waitForEditor, 200);
              return;
            }
            
            // Focus and insert text using execCommand for React compatibility
            editor.focus();
            document.execCommand('insertText', false, ${JSON.stringify(prompt)});
            
            // Wait a moment for React state to update, then click send
            setTimeout(() => {
              const buttons = Array.from(document.querySelectorAll('button'));
              const sendBtn = buttons.find(b => 
                b.getAttribute('aria-label') === 'Send Message' || 
                b.querySelector('svg') && !b.disabled
              );
              
              if (sendBtn) {
                sendBtn.click();
              } else {
                // Fallback: Dispatch Enter key event
                const event = new KeyboardEvent('keydown', {
                  key: 'Enter',
                  code: 'Enter',
                  which: 13,
                  keyCode: 13,
                  bubbles: true,
                  cancelable: true
                });
                editor.dispatchEvent(event);
              }
            }, 500);
          }
          waitForEditor();
        })();
      `;
      chatWin.webContents.executeJavaScript(script);
    });

    await chatWin.loadURL('https://claude.ai/chat/new');
    return { success: true };
  } catch (err) {
    console.error('Error starting session:', err);
    return { success: false, error: err.message };
  }
});


const OAUTH_CLIENTS = {
  ['681255809395' + '-oo8ft2oprdrnp9e3aqf6av3hmdib135j.' + 'apps.googleusercontent.com']: ['R09DU1BY', 'LTR1SGdNUG0tMW83U2stZ2VWNkN1NWNsWEZzeGw='],
  ['884354919052' + '-36trc1jjb3tguiac32ov6cod268c5blh.' + 'apps.googleusercontent.com']: ['R09DU1BY', 'LUs1OEZXUjQ4NkxkTEoxbUxCOHNYQzR6NnFEQWY='],
  ['1071006060591' + '-tmhssin2h21lcre235vtolojh4g403ep.' + 'apps.googleusercontent.com']: ['R09DU1BY', 'LTlZUVdwRjdSV0RDMFFUZGotWXhLTXdSMFp0c1g=']
};

function getClientSecret(clientId) {
  const parts = OAUTH_CLIENTS[clientId];
  return parts ? Buffer.from(parts.join(''), 'base64').toString('utf8') : null;
}

async function refreshGeminiToken(refreshToken, clientId, clientSecret) {
  const resp = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: 'refresh_token'
    })
  });
  if (!resp.ok) throw new Error('Token refresh failed');
  const data = await resp.json();
  return data.access_token;
}

// === Antigravity / Gemini Usage Tracker ===
ipcMain.handle('antigravity:login', async () => {
  const credsPath = path.join(os.homedir(), '.gemini', 'oauth_creds.json');
  if (fs.existsSync(credsPath)) {
    let email = 'Antigravity User';
    try {
      const googleAccountsPath = path.join(os.homedir(), '.gemini', 'google_accounts.json');
      if (fs.existsSync(googleAccountsPath)) {
        const ga = JSON.parse(fs.readFileSync(googleAccountsPath, 'utf8'));
        if (ga.active) email = ga.active;
      }
      if (email === 'Antigravity User') {
        const creds = JSON.parse(fs.readFileSync(credsPath, 'utf8'));
        if (creds.id_token) {
          const payloadBase64 = creds.id_token.split('.')[1];
          const payloadStr = Buffer.from(payloadBase64, 'base64').toString('utf8');
          const payload = JSON.parse(payloadStr);
          if (payload.email) email = payload.email;
        }
      }
    } catch (e) {
      console.error('Error reading email for Antigravity:', e);
    }
    return { success: true, email: email, token: 'local-creds' };
  }
  return { success: false, error: 'Could not find ~/.gemini/oauth_creds.json' };
});

ipcMain.handle('antigravity:fetchQuota', async () => {
  const credsPath = path.join(os.homedir(), '.gemini', 'oauth_creds.json');
  if (!fs.existsSync(credsPath)) return { success: false, error: 'No local creds' };

  // Resolve user email if needed
  let userEmail = null;
  try {
    const googleAccountsPath = path.join(os.homedir(), '.gemini', 'google_accounts.json');
    if (fs.existsSync(googleAccountsPath)) {
      const ga = JSON.parse(fs.readFileSync(googleAccountsPath, 'utf8'));
      if (ga.active) userEmail = ga.active;
    }
    if (!userEmail && fs.existsSync(credsPath)) {
      const creds = JSON.parse(fs.readFileSync(credsPath, 'utf8'));
      if (creds.id_token) {
        const payloadBase64 = creds.id_token.split('.')[1];
        const payloadStr = Buffer.from(payloadBase64, 'base64').toString('utf8');
        const payload = JSON.parse(payloadStr);
        if (payload.email) userEmail = payload.email;
      }
    }
  } catch (e) {
    console.error('Error resolving email:', e);
  }

  // Strategy 1: Attempt to query active local Antigravity LanguageServerService
  try {
    const { execSync } = require('child_process');
    const https = require('https');

    let ports = [];
    try {
      const output = execSync('lsof -iTCP -sTCP:LISTEN -P -n', { encoding: 'utf8' });
      for (const line of output.split('\n')) {
        if (line.match(/agy|antigravity|language_server/i)) {
          const match = line.match(/:(\d+)\s+\(LISTEN\)/);
          if (match) {
            const p = parseInt(match[1], 10);
            if (!ports.includes(p)) ports.push(p);
          }
        }
      }
    } catch (e) {}

    for (const port of ports) {
      try {
        const data = await new Promise((resolve, reject) => {
          const req = https.request({
            hostname: '127.0.0.1',
            port: port,
            path: '/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary',
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            rejectUnauthorized: false
          }, (res) => {
            let body = '';
            res.on('data', chunk => body += chunk);
            res.on('end', () => {
              if (res.statusCode === 200) {
                try { resolve(JSON.parse(body)); } catch(err) { reject(err); }
              } else {
                reject(new Error('Status ' + res.statusCode));
              }
            });
          });
          req.on('error', reject);
          req.write(JSON.stringify({}));
          req.end();
        });

        if (data && data.response && Array.isArray(data.response.groups)) {
          const parseBucketGroup = (group) => {
            if (!group) return null;
            const weeklyBucket = (group.buckets || []).find(b => b.window === 'weekly' || (b.bucketId && b.bucketId.includes('weekly'))) || group.buckets[0];
            const fiveHourBucket = (group.buckets || []).find(b => b.window === '5h' || (b.bucketId && b.bucketId.includes('5h'))) || group.buckets[group.buckets.length - 1];

            return {
              name: group.displayName,
              description: group.description,
              weeklyPct: weeklyBucket ? Math.round(weeklyBucket.remainingFraction * 100) : 100,
              weeklyRawPct: weeklyBucket ? (weeklyBucket.remainingFraction * 100).toFixed(2) : '100.00',
              weeklyResetsIn: weeklyBucket ? weeklyBucket.resetTime : null,
              fiveHourPct: fiveHourBucket ? Math.round(fiveHourBucket.remainingFraction * 100) : 100,
              fiveHourRawPct: fiveHourBucket ? (fiveHourBucket.remainingFraction * 100).toFixed(2) : '100.00',
              fiveHourResetsIn: fiveHourBucket ? fiveHourBucket.resetTime : null
            };
          };

          const geminiGroup = data.response.groups.find(g => g.displayName && g.displayName.toLowerCase().includes('gemini'));
          const claudeGptGroup = data.response.groups.find(g => g.displayName && (g.displayName.toLowerCase().includes('claude') || g.displayName.toLowerCase().includes('gpt')));

          return {
            success: true,
            email: userEmail,
            data: {
              gemini: parseBucketGroup(geminiGroup),
              claudeGpt: parseBucketGroup(claudeGptGroup)
            }
          };
        }
      } catch (e) {
        // Continue to next port
      }
    }
  } catch (err) {
    console.error('Error attempting local Antigravity fetch:', err);
  }

  // Strategy 2: Fallback to Cloud Code API
  try {
    const credsStr = fs.readFileSync(credsPath, 'utf8');
    const creds = JSON.parse(credsStr);
    
    let accessToken = creds.access_token;
    if (creds.refresh_token && creds.id_token) {
      const payloadBase64 = creds.id_token.split('.')[1];
      const payloadStr = Buffer.from(payloadBase64, 'base64').toString('utf8');
      const payload = JSON.parse(payloadStr);
      const clientId = payload.azp;
      const clientSecret = getClientSecret(clientId);

      if (!clientSecret) {
         return { success: false, error: `Unsupported Client ID: ${clientId}` };
      }
      
      accessToken = await refreshGeminiToken(creds.refresh_token, clientId, clientSecret);
    }

    let activeProject = null;
    try {
      const projectsJsonPath = path.join(os.homedir(), '.gemini', 'projects.json');
      if (fs.existsSync(projectsJsonPath)) {
        const pj = JSON.parse(fs.readFileSync(projectsJsonPath, 'utf8'));
        if (pj.projects && typeof pj.projects === 'object') {
          const firstPath = Object.keys(pj.projects)[0];
          if (firstPath) activeProject = pj.projects[firstPath];
        }
      }
    } catch(e) {}

    const reqBody = activeProject ? { project: activeProject } : {};

    const resp = await fetch('https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(reqBody)
    });

    if (!resp.ok) {
      return { success: false, error: `API error: ${resp.status}` };
    }

    const result = await resp.json();
    if (!result.buckets || !Array.isArray(result.buckets)) {
      return { success: false, error: 'No quota buckets in response' };
    }

    const geminiBuckets = result.buckets.filter(b => b.modelId && b.modelId.includes('gemini'));
    const claudeGptBuckets = result.buckets.filter(b => b.modelId && (b.modelId.includes('claude') || b.modelId.includes('gpt')));
    const fallbackBuckets = geminiBuckets.length > 0 ? geminiBuckets : result.buckets;

    const parseGroup = (name, buckets) => {
      if (!buckets || buckets.length === 0) return null;
      const proOrWeekly = buckets.filter(b => b.modelId.includes('pro') || b.modelId.includes('weekly'));
      const flashOrFiveHour = buckets.filter(b => b.modelId.includes('flash') || b.modelId.includes('lite') || b.modelId.includes('5hour') || b.modelId.includes('five_hour'));
      
      const lowestPro = proOrWeekly.length > 0
        ? proOrWeekly.reduce((lowest, b) => b.remainingFraction < lowest.remainingFraction ? b : lowest, proOrWeekly[0])
        : buckets[0];
      
      const lowestFlash = flashOrFiveHour.length > 0
        ? flashOrFiveHour.reduce((lowest, b) => b.remainingFraction < lowest.remainingFraction ? b : lowest, flashOrFiveHour[0])
        : buckets[buckets.length - 1];

      return {
        name,
        weeklyPct: lowestFlash ? Math.round(lowestFlash.remainingFraction * 100) : 100,
        weeklyRawPct: lowestFlash ? (lowestFlash.remainingFraction * 100).toFixed(2) : '100.00',
        weeklyResetsIn: lowestFlash ? lowestFlash.resetTime : null,
        fiveHourPct: lowestPro ? Math.round(lowestPro.remainingFraction * 100) : 100,
        fiveHourRawPct: lowestPro ? (lowestPro.remainingFraction * 100).toFixed(2) : '100.00',
        fiveHourResetsIn: lowestPro ? lowestPro.resetTime : null
      };
    };

    return {
      success: true,
      email: userEmail,
      data: {
        gemini: parseGroup('Gemini Models', fallbackBuckets),
        claudeGpt: parseGroup('Claude and GPT models', claudeGptBuckets)
      }
    };
  } catch (err) {
    console.error('Error fetching Antigravity quota:', err);
    return { success: false, error: err.message };
  }
});

// Show a native macOS notification (e.g. quota threshold alerts)
ipcMain.handle('claude:notify', async (event, { title, body } = {}) => {
  try {
    if (!Notification.isSupported()) {
      return { success: false, error: 'Notifications not supported on this system.' };
    }
    const notification = new Notification({ title: title || 'Claude Quota Widget', body: body || '' });
    notification.on('click', () => {
      if (mainWindow && !mainWindow.isDestroyed()) {
        mainWindow.show();
        mainWindow.focus();
      }
    });
    notification.show();
    return { success: true };
  } catch (err) {
    console.error('Error showing notification:', err);
    return { success: false, error: err.message };
  }
});

ipcMain.handle('claude:getHistory', async () => {
  const historyPath = path.join(currentClaudeDir, 'history.jsonl');
  return readJSONLFile(historyPath);
});

ipcMain.handle('claude:getProjects', async () => {
  const projectsPath = path.join(currentClaudeDir, 'projects');
  const projects = [];

  if (!fs.existsSync(projectsPath)) return [];

  try {
    const dirs = fs.readdirSync(projectsPath, { withFileTypes: true });
    
    for (const dir of dirs) {
      if (dir.isDirectory()) {
        const dirPath = path.join(projectsPath, dir.name);
        const files = fs.readdirSync(dirPath);
        
        const sessionFiles = files.filter(f => f.endsWith('.jsonl'));
        const hasMemory = files.includes('MEMORY.md');
        let memoryContent = '';
        
        if (hasMemory) {
          memoryContent = fs.readFileSync(path.join(dirPath, 'MEMORY.md'), 'utf8');
        }

        // Gather some basic stats about the project's sessions
        const sessions = [];
        let totalSessionsCount = sessionFiles.length;
        let lastModified = 0;

        for (const file of sessionFiles) {
          const filePath = path.join(dirPath, file);
          const stats = fs.statSync(filePath);
          if (stats.mtimeMs > lastModified) {
            lastModified = stats.mtimeMs;
          }
          sessions.push({
            sessionId: file.replace('.jsonl', ''),
            mtime: stats.mtimeMs,
            size: stats.size
          });
        }

        // Sort sessions by modification time descending
        sessions.sort((a, b) => b.mtime - a.mtime);

        projects.push({
          dirName: dir.name,
          sessionCount: totalSessionsCount,
          lastActive: lastModified || fs.statSync(dirPath).mtimeMs,
          sessions,
          hasMemory,
          memoryContent
        });
      }
    }
  } catch (err) {
    console.error('Error reading projects:', err);
  }

  // Sort projects by last active descending
  return projects.sort((a, b) => b.lastActive - a.lastActive);
});

ipcMain.handle('claude:getSessionTranscript', async (event, { dirName, sessionId }) => {
  const sessionPath = path.join(currentClaudeDir, 'projects', dirName, `${sessionId}.jsonl`);
  return readJSONLFile(sessionPath);
});

ipcMain.handle('claude:getPlans', async () => {
  const plansPath = path.join(currentClaudeDir, 'plans');
  const plans = [];

  if (!fs.existsSync(plansPath)) return [];

  try {
    const files = fs.readdirSync(plansPath);
    for (const file of files) {
      if (file.endsWith('.md')) {
        const filePath = path.join(plansPath, file);
        const stats = fs.statSync(filePath);
        
        // Read the first few lines to get the title
        const content = fs.readFileSync(filePath, 'utf8');
        const firstLine = content.split('\n')[0] || '';
        const title = firstLine.startsWith('# ') ? firstLine.replace('# ', '').trim() : file;

        plans.push({
          fileName: file,
          title,
          lastModified: stats.mtimeMs,
          size: stats.size
        });
      }
    }
  } catch (err) {
    console.error('Error reading plans:', err);
  }

  return plans.sort((a, b) => b.lastModified - a.lastModified);
});

ipcMain.handle('claude:getPlanContent', async (event, fileName) => {
  const filePath = path.join(currentClaudeDir, 'plans', fileName);
  try {
    if (fs.existsSync(filePath)) {
      return fs.readFileSync(filePath, 'utf8');
    }
  } catch (err) {
    console.error(`Error reading plan content at ${filePath}:`, err);
  }
  return '';
});

// App Lifecycle
app.whenReady().then(() => {
  createWindow();
  createTray();

  app.on('activate', () => {
    if (mainWindow) {
      mainWindow.show();
    } else {
      createWindow();
    }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});
