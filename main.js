const { app, BrowserWindow, Menu } = require('electron');
const path = require('path');
const url = require('url');

// Keep a global reference of the window object to prevent garbage collection
let mainWindow;

// Disable hardware acceleration for better performance on some systems
app.disableHardwareAcceleration();

// Add optimization switches for faster startup
app.commandLine.appendSwitch('disable-http-cache');
app.commandLine.appendSwitch('disable-gpu');
app.commandLine.appendSwitch('js-flags', '--max-old-space-size=4096');
// Remove the problematic DPI/scale factor settings that caused zooming issues
// app.commandLine.appendSwitch('high-dpi-support', '1');
// app.commandLine.appendSwitch('force-device-scale-factor', '1');
app.commandLine.appendSwitch('ignore-certificate-errors');
app.commandLine.appendSwitch('disable-features', 'OutOfBlinkCors');

// Set application name for title bar
app.name = 'T3 Chat';

function createWindow() {
  // Hide the default menu
  Menu.setApplicationMenu(null);
  
  // Create the browser window
  mainWindow = new BrowserWindow({
    width: 1200,
    height: 800,
    icon: path.join(__dirname, 't3.jpg'), // Use t3.jpg as app icon
    show: false, // Don't show until ready
    fullscreen: false, // Not fullscreen
    maximizable: true, // Allow maximizing
    titleBarStyle: 'default',
    titleBarOverlay: {
      height: 40, // Make title bar bigger
      color: '#000000',
      symbolColor: '#FFFFFF'
    },
    autoHideMenuBar: true, // Hide menu bar
    webPreferences: {
      nodeIntegration: false,
      contextIsolation: true,
      enableRemoteModule: false,
      preload: path.join(__dirname, 'preload.js'),
      backgroundThrottling: false, // Prevent throttling
      spellcheck: false, // Disable spellcheck for performance
      zoomFactor: 1.0 // Set default zoom factor to 1.0 (100%)
    }
  });

  // Load the url immediately
  mainWindow.loadURL('https://t3.chat/chat');

  // Show window when ready to reduce perceived loading time
  mainWindow.once('ready-to-show', () => {
    mainWindow.show();
    mainWindow.maximize();
    mainWindow.focus();
    
    // Reset zoom level to normal
    mainWindow.webContents.setZoomFactor(1.0);
    
    // Prevent accidental zooming
    mainWindow.webContents.on('before-input-event', (event, input) => {
      // Prevent Ctrl+- and Ctrl+= zoom shortcuts
      if (input.control && (input.key === '-' || input.key === '=' || input.key === '+')) {
        event.preventDefault();
      }
    });
  });

  // Optimize page loading
  mainWindow.webContents.on('did-start-loading', () => {
    // You could add a loading indicator here if needed
  });

  // Handle window closing
  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// Create window when app is ready
app.whenReady().then(() => {
  createWindow();

  // For macOS: re-create window when dock icon is clicked
  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      createWindow();
    }
  });
});

// Quit when all windows are closed (except on macOS)
app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') {
    app.quit();
  }
}); 