# gstack — Claude Cowork Plugin

Eight opinionated workflow skills that transform Claude Code from a generic assistant into a team of specialists you can summon on demand.

## About

These skills were authored by [Garry Tan](https://github.com/garrytan) (President & CEO, Y Combinator) and published in his [garrytan/gstack](https://github.com/garrytan/gstack) repository. The original repo includes build tooling, template generators, and eval harnesses for those who want to develop or extend the skills themselves.

This plugin is that work repackaged into the Claude Cowork plugin format — skill content is unchanged, only the directory layout has been adapted to use Cowork conventions so you can install everything in one step without cloning, building, or symlinking anything manually.

## Skills

| Skill | Role | What it does |
|-------|------|-------------|
| `/gstack:plan-ceo-review` | Founder/CEO | Rethink problems; find the 10-star product inside requests. Three modes: SCOPE EXPANSION, HOLD SCOPE, SCOPE REDUCTION |
| `/gstack:plan-eng-review` | Engineering Manager | Lock architecture, data flow, diagrams, edge cases, test coverage |
| `/gstack:review` | Staff Engineer | Find production-breaking bugs in diffs; triage Greptile review comments |
| `/gstack:ship` | Release Engineer | Sync main, run tests, review diff, bump version, push, open PR — fully automated |
| `/gstack:browse` | QA Engineer | Fast headless Chromium (~100ms/command). Navigate, interact, screenshot, assert |
| `/gstack:qa` | QA Lead | Systematic testing with diff-aware, full, quick, and regression modes |
| `/gstack:setup-browser-cookies` | Session Manager | Import real browser cookies for authenticated testing |
| `/gstack:retro` | Engineering Manager | Team-aware retrospectives with per-person praise and growth feedback |

## Installation

This plugin is part of the [pankajnits/skill-depot](https://github.com/pankajnits/skill-depot) marketplace.

### Via the Cowork UI (recommended)

1. Open **Claude Desktop** → click **"Cowork"** in the top bar
2. Click **"+"** → **"Plugins"** → **"Add plugin"** → choose **GitHub**
3. Enter the marketplace: `pankajnits/skill-depot`
4. From the catalog, find **gstack** and click **"Install"**

### Via slash commands (inside Claude)

```
/plugin marketplace add pankajnits/skill-depot
/plugin install gstack
```

### For local development

Point Claude at the plugin subdirectory directly:

```bash
claude --plugin-dir /path/to/skill-depot/exec/gstack
```

### Team distribution (project scope)

After adding the marketplace, install at project scope so all teammates get the skills automatically:

```
/plugin install gstack --scope project
```

This writes the reference into `.claude/settings.json`, which you commit with your repo.

### Organization-wide (admin)

1. Go to **Organization settings → Plugins** in Claude Desktop
2. Click **"Add plugin"** → select **"GitHub"** → enter: `pankajnits/skill-depot`
3. Members will see gstack in their **Browse plugins** catalog

---

## Requirements

- **Claude Code** v1.0.33+
- **Git** — required by `/gstack:ship`, `/gstack:review`, `/gstack:retro`
- **`gh` CLI** — required by `/gstack:ship` (PR creation) and `/gstack:review` (Greptile integration)

### Browser skills only

`/gstack:browse`, `/gstack:qa`, and `/gstack:setup-browser-cookies` additionally require a one-time binary build:

- **Bun** v1.0+
- **macOS or Linux** (x64 or arm64)

The other five skills (`/gstack:plan-ceo-review`, `/gstack:plan-eng-review`, `/gstack:review`, `/gstack:ship`, `/gstack:retro`) have no extra requirements.

## Browser setup

Run once after installing:

```bash
cd <plugin-dir> && ./scripts/setup
```

This compiles the Playwright-based Chromium binary. The skill will remind you automatically if this step hasn't been done yet.

---

## License

MIT — original copyright Garry Tan. See [LICENSE](LICENSE).

Original source: [garrytan/gstack](https://github.com/garrytan/gstack)
