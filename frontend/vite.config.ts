import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// https://vite.dev/config/
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: Object.fromEntries(['/auth', '/api'].map((path) => [path, {
      target: process.env.MAGNUM_API_UPSTREAM ?? 'http://127.0.0.1:4000',
      changeOrigin: false,
    }])),
  },
})
