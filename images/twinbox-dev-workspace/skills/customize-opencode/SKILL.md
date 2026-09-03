---
name: customize-opencode
description: Customize OpenCode configuration, skills, commands, agents, permissions, and project instructions while keeping changes small and reviewable.
---

# Customize OpenCode

Use this skill when asked to change how OpenCode behaves in a repository or
workspace.

## Workflow

1. Inspect the nearest `AGENTS.md`, `.opencode/`, and `opencode.json` or
   `opencode.jsonc` files before changing behavior.
2. Prefer project-scoped configuration when the behavior belongs to the current
   repository; use global configuration only for personal defaults.
3. For reusable behavior, create a focused skill under `.opencode/skills/` or
   `.agents/skills/` with a lowercase hyphenated name and a concise
   description.
4. For repeated prompts, create an OpenCode command under `.opencode/commands/`.
5. For different tool permissions or modes, create or update an OpenCode agent
   instead of overloading general instructions.
6. Keep secrets out of config files. Reference environment variables or existing
   secret stores instead.
7. Validate JSON/JSONC/YAML/frontmatter syntax and briefly explain how to invoke
   the new behavior.

## Boundaries

- Do not replace existing project instructions wholesale unless the user asked
  for a rewrite.
- Do not grant broader tool permissions than the requested workflow needs.
- Do not install external plugins or connect accounts unless the user explicitly
  asks for that step.
