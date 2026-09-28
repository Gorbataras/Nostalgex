import { resolve } from 'path'
import { readdirSync, mkdirSync, copyFileSync } from 'fs'
import { defineConfig } from 'vite'

// The browser-loaded helper scripts (scripts/nostalgex-*.js|.cjs) are referenced
// by plex-tuner.html with a plain <script src>. Vite can't bundle non-module scripts,
// and they live outside public/, so the default build leaves them out of dist and
// production 404s them — which breaks the entire library load. Copy them into dist/scripts.
function copyBrowserScripts() {
  return {
    name: 'copy-browser-scripts',
    closeBundle() {
      const srcDir = resolve(__dirname, 'scripts')
      const outDir = resolve(__dirname, 'dist', 'scripts')
      mkdirSync(outDir, { recursive: true })
      for (const file of readdirSync(srcDir)) {
        if (/^(nostalgex-.*\.(js|cjs)|newsletter\.js)$/.test(file)) {
          copyFileSync(resolve(srcDir, file), resolve(outDir, file))
        }
      }
    },
  }
}

export default defineConfig({
  plugins: [copyBrowserScripts()],
  build: {
    rollupOptions: {
      input: {
        main: resolve(__dirname, 'index.html'),
        'web-tuner': resolve(__dirname, 'web-tuner.html'),
        'apple-tv': resolve(__dirname, 'apple-tv.html'),
        'plex-tuner': resolve(__dirname, 'plex-tuner.html'),
        privacy: resolve(__dirname, 'privacy.html'),
        support: resolve(__dirname, 'support.html'),
        plex: resolve(__dirname, 'plex.html'),
        jellyfin: resolve(__dirname, 'jellyfin.html'),
        emby: resolve(__dirname, 'emby.html'),
        '404': resolve(__dirname, '404.html'),
      },
    },
  },
})
