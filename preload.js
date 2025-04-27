// Preload script with optimization
window.addEventListener('DOMContentLoaded', () => {
  // Inject performance optimizations but avoid transform that affects scale
  const style = document.createElement('style');
  style.textContent = `
    /* Optimize rendering without affecting scale */
    * {
      text-rendering: optimizeSpeed;
      image-rendering: optimizeSpeed;
    }
    
    /* Ensure normal scale for body content */
    body {
      zoom: 1 !important;
      transform: none !important;
      -webkit-transform: none !important;
    }
  `;
  document.head.appendChild(style);
  
  // Remove force hardware acceleration that could affect scale
  // document.body.style.transform = 'translateZ(0)';
  
  // Prioritize content loading
  const links = document.querySelectorAll('link[rel="stylesheet"]');
  links.forEach(link => {
    link.setAttribute('media', 'all');
    link.setAttribute('fetchpriority', 'high');
  });
  
  // Prioritize main content images
  const images = document.querySelectorAll('img');
  images.forEach(img => {
    img.setAttribute('loading', 'eager');
    img.setAttribute('fetchpriority', 'high');
  });
}); 