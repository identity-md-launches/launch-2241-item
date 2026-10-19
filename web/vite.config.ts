import { defineConfig } from "vite";

// The logo files in ../assets/logo are copied into dist/logo byte for byte (Vite's public dir is never
// transformed). The export goes to the repository root's dist/ with relative URLs for static hosting.
export default defineConfig({
  base: "./",
  publicDir: "../assets",
  build: {
    outDir: "../dist",
    emptyOutDir: true,
    assetsInlineLimit: 0,
  },
  server: {
    fs: { allow: [".."] },
  },
});
