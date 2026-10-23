// @ts-check
import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';

export default defineConfig({
  site: 'https://cormorant.baldyeagle.dev',
  trailingSlash: 'never',
  build: {
    // Emit /privacy.html etc. so URLs stay slash-free on Workers static assets.
    format: 'file',
  },
  vite: {
    plugins: [tailwindcss()],
  },
});
