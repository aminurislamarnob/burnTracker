# BurnTracker 📊

A beautiful, lightweight, and modern macOS utility status bar widget built with Electron. It resides in your macOS menu bar, allowing you to monitor rolling 5-hour session limits and weekly utilization quotas across multiple Anthropic **Claude.ai** accounts simultaneously.

![macOS Status Bar Integration](https://img.shields.io/badge/Platform-macOS-orange?style=flat-square&logo=apple)
![Electron](https://img.shields.io/badge/Electron-v31.0-blue?style=flat-square&logo=electron)
![Vanilla JS/CSS](https://img.shields.io/badge/Frontend-HTML/CSS/JS-green?style=flat-square)

---

## Key Features 🚀

- **Mac Menu Bar Widget:** Resides directly in the top status bar. Left-clicking the icon instantly toggles the compact window; right-clicking opens a context menu.
- **Minimal macOS Aesthetic:** Designed using modern glassmorphism, responsive status pulsing, and Outfit/Inter typefaces matching native Apple utility tools.
- **Multi-Account Quota Tracking:** Add and track multiple Claude accounts (e.g., *Personal*, *Work*, *Enterprise*) with custom labels.
- **Inline Account Editing:** Update an account's label or rotate its expired `sessionKey` directly from the settings list — no need to remove and re-add. Changing the key automatically re-validates the account against Anthropic.
- **Configurable Auto-Refresh:** Choose how often quotas sync in the background (every 5, 10, 15, 30, or 60 minutes) from the settings panel. Quotas also refresh instantly whenever you open the widget.
- **Usage Alerts:** Get a native macOS notification the first time an account's 5-hour session crosses a threshold you pick (50%–95%), or switch alerts **Off** entirely. Each account alerts once per session window and re-arms automatically after the session resets.
- **Live Syncing & Isolation:** Connects directly to Anthropic's private web endpoints. Accounts are updated concurrently; if a key expires or fails, the widget isolates the warning to that card without affecting other active accounts.
- **Privacy First:** Your Claude session cookies are stored purely locally in your home directory profile under `~/.claude/tracker-settings.json` and are transmitted directly to Anthropic's endpoints.
- **Retina-ready Tray Templates:** Employs pre-scaled monochrome status bar icons (`tray-iconTemplate.png` and `tray-iconTemplate@2x.png`) that automatically adapt to light and dark macOS menu bars.

---

## App Interface Preview 📱

![BurnTracker Preview](assets/preview.png)

---

## How to Get Your `sessionKey` 🔑

To sync live usage metrics, you'll need the `sessionKey` cookie value for each account:

1. Open your browser and log into [claude.ai](https://claude.ai).
2. Right-click on the page and select **Inspect** to open Developer Tools.
3. Head to the **Application** tab (Chrome/Safari) or the **Storage** tab (Firefox).
4. Expand **Cookies** in the left sidebar menu and click `https://claude.ai`.
5. Find the row named `sessionKey` and copy its entire value (starting with `sk-ant-sid02-...`).
6. Click the gear icon `[⚙]` in the widget header, type a label (e.g. *Personal*), paste the key, and click **Add Account**.

> **Key expired?** `sessionKey` cookies are rotated periodically by Anthropic. When an account shows a *Sync Failed* warning, open the settings panel, click **Edit** on that account, and paste a fresh key — there's no need to remove and re-add it.

---

## Installation & Setup 🛠️

### Prerequisites
- Node.js (v18 or higher)
- npm

### 1. Install Dependencies
Clone this repository to your local machine, open your terminal in the directory, and run:
```bash
npm install
```

### 2. Start the App Locally
To launch the widget instantly in development mode:
```bash
npm start
```
The app will initialize and mount the monochrome burst icon in your status bar. You can close the window, and it will run in the background (the Dock icon automatically hides when minimized to status bar).

---

## Compiling Distribution Packages 📦

You can build standalone, optimized native binaries (`.app` and `.dmg`) that run natively on Apple Silicon and Intel-based Macs using `electron-builder`:

Run the compiler:
```bash
npm run dist
```

Upon successful compilation, check your local `dist/` directory for:
- **`dist/BurnTracker-1.0.0-arm64.dmg`**: Drag-and-drop installer window.
- **`dist/BurnTracker-1.0.0-arm64-mac.zip`**: Standard compressed macOS application bundle.

*Note: Since the bundle is built locally without an official paid Apple Developer certificate, macOS Gatekeeper might show a verification warning. To bypass this on first run, Right-Click the `.app` bundle, select **Open**, and click **Open anyway** in the dialog.*

---

## File Structure 📂

```
claude-tracker/
├── assets/
│   ├── app-icon.svg             # Cropped high-res master vector icon
│   ├── icon.icns                # Multi-resolution macOS bundle icon
│   ├── icon.png                 # Standard 1024x1024 application image
│   ├── tray-iconTemplate.svg    # Vector template icon for status bar
│   ├── tray-iconTemplate.png    # Pre-rasterized 18x18 template image
│   └── tray-iconTemplate@2x.png # Pre-rasterized 36x36 Retina template image
├── src/
│   ├── index.html               # Main dashboard & settings HTML pane
│   ├── styles.css               # Premium macOS Glassmorphism styles
│   └── renderer.js              # Account states, API requests, & card rendering
├── main.js                      # Electron main background process & Tray handlers
├── preload.js                   # Secure IPC renderer bridge
├── package.json                 # Project dependencies & build metadata
└── README.md                    # Project documentation
```

---

## Security & Privacy 🔒

- All requests are initiated **directly** from your local machine to `claude.ai` endpoints.
- No central server, tracking services, or intermediate proxy servers are used.
- Keys are saved locally using standard JSON formatting in your home directory profile under `~/.claude/tracker-settings.json`.
