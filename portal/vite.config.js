import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "./",
  server: {
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8080",
        changeOrigin: true,
      },
      "/auth": {
        target: "http://127.0.0.1:8080",
        changeOrigin: true,
      },
      "/logout": {
        target: "http://127.0.0.1:8080",
        changeOrigin: true,
      },
    },
  },
});
