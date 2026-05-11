import js from "@eslint/js";
import globals from "globals";
import prettier from "eslint-config-prettier";

export default [
  {
    ignores: [
      "**/node_modules/**",
      "**/dist/**",
      "**/build/**",
      "**/manager-data/**",
      "**/.venv/**",
      "**/.git/**",
      "**/.ruff_cache/**",
    ],
  },
  js.configs.recommended,
  {
    files: ["lib/**/*.{js,mjs}", "scripts/**/*.{js,mjs}"],
    languageOptions: {
      globals: globals.node,
      ecmaVersion: 2024,
      sourceType: "module",
    },
    rules: {
      "no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
    },
  },
  prettier,
];
