import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import { viteSingleFile } from 'vite-plugin-singlefile'

// Single-file, request-free builds of the Shep pages (same approach as bloub's vite.goop.config.ts). SHEP_ENTRY picks the
// page: shep-dog (the dog, default) or shep-house (the doghouse); tools/shep-dog/build.sh runs both.
const entry = process.env.SHEP_ENTRY === 'shep-house' ? 'shep-house.html' : 'shep-dog.html'

export default defineConfig({
  plugins: [viteSingleFile()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: { input: fileURLToPath(new URL('./' + entry, import.meta.url)) }
  }
})
