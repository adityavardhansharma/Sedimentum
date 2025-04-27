# T3 Chat Desktop

A lightweight Electron wrapper for the T3 Chat web application.

## Development

### Prerequisites
- Node.js (v14+)
- npm

### Setup
1. Clone this repository
2. Run `npm install` to install dependencies
3. Create the icon file (see instructions below)

### Running
- Run `npm start` to start the application in development mode

### Building
- Run `npm run dist` to build the application for distribution
- The installer will be created in the `dist` folder

## Creating the Icon
You need to create a `t3.jpg` file in the root directory (at least 256x256 pixels) for the app icon. You have two options:

### Option 1: Use the HTML Generator
1. Open the `create-icon.html` file in your browser
2. Either upload your own image or generate the default T3 icon
3. Click "Download as t3.jpg"
4. Move the downloaded file to the app's root directory

### Option 2: Create Manually
1. Create or find an image you want to use as the icon
2. Ensure it's at least 256x256 pixels in size
3. Save it as `t3.jpg` in the app's root directory

## Note
The icon will be used for both the application window and the desktop/Start menu shortcuts. 