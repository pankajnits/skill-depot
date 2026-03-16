# skill-depot

A curated marketplace of Claude Cowork plugins, organized by category. One repo — add it once, pick and install the plugins you want.

## Add this marketplace

In any Claude session:

```
/plugin marketplace add pankajnits/skill-depot
```

Then browse and install individual plugins:

```
/plugin install principal@skill-depot
/plugin install gstack@skill-depot
```

Or install via the plugin manager UI:

**Via Cowork UI:**
1. Click the **Cowork** tab → click **+** → click **Add plugin**
2. Select the **Personal** tab → click **+** → choose **Add marketplace from GitHub**
3. Enter `pankajnits/skill-depot` → confirm
4. Find the plugin you want → click **Install**

**Via chat `/plugin`:**
1. Type `/plugin` in the chat box → click **Add plugin**
2. Select the **Personal** tab → click **+** → choose **Add marketplace from GitHub**
3. Enter `pankajnits/skill-depot` → confirm
4. Find the plugin you want → click **Install**

---

## Plugins

| Plugin | Skills | Commands | Description |
|--------|--------|----------|-------------|
| [principal](./principal/) | 17 skills | 16 commands | Staff-engineer and technical architect toolkit — HLD, LLD, ADR, RFC, tech debt audit, scalability review, database design, LLM system design, incident response, migration planning, API design, threat modeling, performance auditing, platform engineering, cloud design, frontend review, production debugging |
| [gstack](./exec/gstack/) | 8 skills | — | Garry Tan's engineering workflow skills — plan review (CEO & eng manager modes), PR review, automated ship, headless browser QA, team retrospectives |

### productivity *(coming soon)*

---

## Structure

```
skill-depot/
├── .claude-plugin/
│   └── marketplace.json     ← plugin catalog
├── principal/               ← staff engineer toolkit
│   ├── .claude-plugin/plugin.json
│   ├── skills/              ← 17 skills
│   ├── commands/            ← 16 quick-trigger commands
│   ├── scripts/             ← utility scripts (bus-factor, dep-audit)
│   └── README.md
├── exec/
│   └── gstack/              ← Garry Tan's workflow skills
│       ├── .claude-plugin/plugin.json
│       ├── skills/
│       ├── scripts/
│       └── README.md
├── productivity/            ← future plugins go here
└── README.md
```

Each plugin is self-contained: `skills/`, optional `commands/`, its own `plugin.json`, `LICENSE`, and `README.md`.

## Adding a new plugin

1. Create a directory under the appropriate category (or at root level): `<plugin-name>/`
2. Add `.claude-plugin/plugin.json`, `skills/`, and a `README.md`
3. Register it in `.claude-plugin/marketplace.json` with `"source": "./<path-to-plugin>"`

## License

Each plugin carries its own license. See the `LICENSE` file inside each plugin directory.
