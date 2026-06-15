import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import path from 'path';

const buildId = process.env.VITE_BUILD_ID || `${Date.now()}`;

export default defineConfig({
  plugins: [react()],
  define: {
    __APP_BUILD_ID__: JSON.stringify(buildId),
  },
  resolve: {
    alias: { '@': path.resolve(__dirname, './src') },
  },
  base: './',
  build: {
    outDir: '../priv/admin',
    emptyOutDir: true,
  },
  server: {
    host: '127.0.0.1',
    port: 5173,
    proxy: {
      '/api': {
        target: process.env.API_PROXY_TARGET ?? 'http://127.0.0.1:9080',
        changeOrigin: true,
      },
    },
  },
});
