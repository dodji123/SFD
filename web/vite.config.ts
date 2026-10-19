import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// L'interface appelle /api/* ; en développement, Vite relaie vers l'API FastAPI (port 8100).
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: { '/api': { target: 'http://127.0.0.1:8100', changeOrigin: true } },
  },
})
