const fs = require('fs');
const path = require('path');
const { createCanvas, loadImage } = require('canvas');

// This script creates a 256x256 placeholder icon if the t3.jpg file isn't found
// or if it's too small for electron-builder requirements

async function createPlaceholderIcon() {
  console.log('Creating placeholder icon file...');
  
  // Create a 256x256 canvas
  const canvas = createCanvas(256, 256);
  const ctx = canvas.getContext('2d');
  
  // Fill background
  ctx.fillStyle = '#000000';
  ctx.fillRect(0, 0, 256, 256);
  
  // Draw T3 text
  ctx.fillStyle = '#FFFFFF';
  ctx.font = 'bold 120px Arial';
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.fillText('T3', 128, 128);
  
  // Save to file
  const buffer = canvas.toBuffer('image/jpeg');
  fs.writeFileSync(path.join(__dirname, 't3.jpg'), buffer);
  
  console.log('Created placeholder t3.jpg icon (256x256)');
}

// If you have an existing image you want to resize:
async function resizeExistingIcon(inputPath) {
  try {
    console.log(`Resizing existing icon: ${inputPath}`);
    
    const image = await loadImage(inputPath);
    const canvas = createCanvas(256, 256);
    const ctx = canvas.getContext('2d');
    
    // Draw the image centered and scaled to fit
    ctx.drawImage(image, 0, 0, 256, 256);
    
    // Save to file
    const buffer = canvas.toBuffer('image/jpeg');
    fs.writeFileSync(path.join(__dirname, 't3.jpg'), buffer);
    
    console.log('Resized t3.jpg icon to 256x256');
  } catch (err) {
    console.error('Error resizing icon:', err);
    await createPlaceholderIcon();
  }
}

// Check if t3.jpg exists, if not create a placeholder
async function ensureIconExists() {
  const iconPath = path.join(__dirname, 't3.jpg');
  
  if (fs.existsSync(iconPath)) {
    console.log('Icon file found, checking size...');
    await resizeExistingIcon(iconPath);
  } else {
    console.log('Icon file not found, creating placeholder...');
    await createPlaceholderIcon();
  }
}

// Run the script
ensureIconExists().catch(err => {
  console.error('Error:', err);
});

console.log('Create a t3.jpg file in the main folder that is at least 256x256 pixels in size.');
console.log('Or install canvas package with "npm install canvas" and run this script to generate a placeholder.'); 