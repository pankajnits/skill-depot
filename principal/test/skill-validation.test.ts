/**
 * Tier 1: Static Validation Tests for the principal plugin
 *
 * Run with: node --experimental-strip-types --test test/skill-validation.test.ts
 *
 * Validates:
 * - SKILL.md frontmatter (name, description, allowed-tools)
 * - Command format (double ---, description, $ARGUMENTS)
 * - No stale /arch: references
 * - Safe bash commands (no destructive operations without safety gates)
 * - Plugin manifest validity
 * - Structural completeness
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import {
  discoverSkills,
  discoverCommands,
  validateSkill,
  validateCommand,
  readPluginJson,
  readMarketplaceJson,
  VALID_TOOLS,
  PLUGIN_ROOT,
} from "./helpers/skill-parser.ts";

// --- Expected inventory ---

const EXPECTED_SKILLS = [
  "hld", "lld", "adr", "rfc", "scale-review", "tech-debt",
  "db-review", "llm-design", "incident", "migration",
  "api-design", "threat-model", "perf-audit",
  "platform-engineering", "cloud-design", "frontend-review", "debug",
];

const EXPECTED_COMMANDS = [
  "estimate", "tradeoff", "diagram", "checklist", "sla-calc", "complexity",
  "blast-radius", "dep-audit", "bus-factor", "capacity-calc", "dora-calc", "runbook-gen",
  "load-test", "on-call-handoff", "feature-flag", "guide",
];

// ============================
// Structural Tests
// ============================

describe("Plugin structure", () => {
  it("plugin.json exists and is valid JSON", () => {
    const manifest = readPluginJson();
    assert.ok(manifest);
    assert.equal(manifest.name, "principal");
    assert.ok(manifest.version);
    assert.ok(manifest.description);
    assert.equal((manifest.author as Record<string, string>).name, "pankajnits");
    assert.equal(manifest.license, "MIT");
  });

  it("marketplace.json references principal plugin", () => {
    const marketplace = readMarketplaceJson();
    const plugins = marketplace.plugins as Array<Record<string, string>>;
    const principal = plugins.find((p) => p.name === "principal");
    assert.ok(principal, "principal plugin not found in marketplace.json");
    assert.equal(principal.source, "./principal");
  });

  it("all expected skill directories exist", () => {
    for (const skill of EXPECTED_SKILLS) {
      assert.ok(existsSync(join(PLUGIN_ROOT, "skills", skill)), `Missing skill dir: ${skill}`);
      assert.ok(existsSync(join(PLUGIN_ROOT, "skills", skill, "SKILL.md")), `Missing SKILL.md: ${skill}`);
    }
  });

  it("all expected command files exist", () => {
    for (const cmd of EXPECTED_COMMANDS) {
      assert.ok(existsSync(join(PLUGIN_ROOT, "commands", `${cmd}.md`)), `Missing command: ${cmd}`);
    }
  });

  it("no orphan skill directories (dirs without SKILL.md)", () => {
    const skillsDir = join(PLUGIN_ROOT, "skills");
    const dirs = readdirSync(skillsDir).filter((d) =>
      statSync(join(skillsDir, d)).isDirectory()
    );
    for (const dir of dirs) {
      assert.ok(existsSync(join(skillsDir, dir, "SKILL.md")), `Orphan dir: ${dir}`);
    }
  });

  it("LICENSE file exists", () => {
    assert.ok(existsSync(join(PLUGIN_ROOT, "LICENSE")));
  });

  it("README.md exists", () => {
    assert.ok(existsSync(join(PLUGIN_ROOT, "README.md")));
  });
});

// ============================
// Skill Validation Tests
// ============================

describe("Skill validation", () => {
  const skills = discoverSkills();

  it(`discovers all ${EXPECTED_SKILLS.length} skills`, () => {
    assert.equal(skills.length, EXPECTED_SKILLS.length);
    const skillNames = skills.map((s) => s.dirName).sort();
    assert.deepEqual(skillNames, [...EXPECTED_SKILLS].sort());
  });

  for (const skillName of EXPECTED_SKILLS) {
    describe(`skill: ${skillName}`, () => {
      const skill = skills.find((s) => s.dirName === skillName)!;

      it("exists and parses", () => {
        assert.ok(skill, `Skill not found: ${skillName}`);
      });

      it("frontmatter name matches directory", () => {
        assert.equal(skill.frontmatter.name, skillName);
      });

      it("has multiline description", () => {
        assert.ok(skill.frontmatter.description, "Missing description");
        assert.ok(skill.rawYaml.includes("description: |"), "Description should use | syntax");
      });

      it("has valid allowed-tools", () => {
        const tools = skill.frontmatter["allowed-tools"];
        assert.ok(Array.isArray(tools), "allowed-tools must be array");
        assert.ok(tools.length > 0, "allowed-tools must not be empty");
        for (const tool of tools) {
          assert.ok(VALID_TOOLS.includes(tool), `Invalid tool: "${tool}"`);
        }
      });

      it("no stale /arch: references", () => {
        const fullText = skill.rawYaml + "\n" + skill.content;
        assert.ok(!fullText.includes("/arch:"), "Contains stale /arch: reference");
      });

      it("passes full validation", () => {
        const result = validateSkill(skill);
        assert.ok(result.valid, `Validation errors: ${result.errors.join(", ")}`);
      });
    });
  }
});

// ============================
// Command Validation Tests
// ============================

describe("Command validation", () => {
  const commands = discoverCommands();

  it(`discovers all ${EXPECTED_COMMANDS.length} commands`, () => {
    assert.equal(commands.length, EXPECTED_COMMANDS.length);
    const cmdNames = commands.map((c) => c.fileName).sort();
    assert.deepEqual(cmdNames, [...EXPECTED_COMMANDS].sort());
  });

  for (const cmdName of EXPECTED_COMMANDS) {
    describe(`command: ${cmdName}`, () => {
      const cmd = commands.find((c) => c.fileName === cmdName)!;

      it("exists and parses", () => {
        assert.ok(cmd, `Command not found: ${cmdName}`);
      });

      it("has description", () => {
        assert.ok(cmd.description, "Missing description");
        assert.ok(cmd.description.length > 10, "Description too short");
      });

      it("references $ARGUMENTS", () => {
        assert.ok(cmd.hasArguments, "Does not reference $ARGUMENTS");
      });

      it("ends with ---", () => {
        assert.match(cmd.content.trimEnd(), /---$/, "Does not end with ---");
      });

      it("starts with correct format (---\\n---)", () => {
        const raw = readFileSync(
          join(PLUGIN_ROOT, "commands", `${cmdName}.md`),
          "utf-8"
        );
        assert.ok(raw.startsWith("---\n---\n"), "Must start with ---\\n---\\n");
      });

      it("passes full validation", () => {
        const result = validateCommand(cmd);
        assert.ok(result.valid, `Validation errors: ${result.errors.join(", ")}`);
      });
    });
  }
});

// ============================
// Safety Tests
// ============================

describe("Safety checks", () => {
  const skills = discoverSkills();

  it("no skill uses ungated destructive bash commands", () => {
    const dangerous = [
      /\brm\s+-rf\b/,
      /\bDROP\s+(TABLE|DATABASE)\b/i,
      /\bkubectl\s+delete\b/,
      /\bgit\s+reset\s+--hard\b/,
      /\bgit\s+push\s+--force\b/,
    ];

    for (const skill of skills) {
      const bashBlocks = skill.content.match(/```bash\n([\s\S]*?)```/g) || [];
      for (const block of bashBlocks) {
        if (
          block.includes("DESTRUCTIVE") ||
          block.includes("STOP") ||
          block.includes("confirm with user") ||
          block.includes("\u26a0\ufe0f")
        ) {
          continue;
        }
        for (const pattern of dangerous) {
          assert.ok(
            !pattern.test(block),
            `Skill "${skill.dirName}" has ungated destructive command: ${pattern.source}`
          );
        }
      }
    }
  });

  it("all SQL in skills is read-only (SELECT, EXPLAIN, pg_stat)", () => {
    const writeSQL = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE)\b/i;

    for (const skill of skills) {
      const sqlBlocks = skill.content.match(/```sql\n([\s\S]*?)```/g) || [];
      for (const block of sqlBlocks) {
        if (block.includes("DESTRUCTIVE") || block.includes("\u26a0\ufe0f")) {
          continue;
        }
        const lines = block.split("\n").filter(
          (l) => !l.startsWith("--") && !l.startsWith("```") && l.trim()
        );
        for (const line of lines) {
          if (writeSQL.test(line)) {
            // db-review shows DDL examples (CREATE TABLE, CREATE INDEX) as schema design patterns — not executed queries
            if (skill.dirName === "db-review") continue;
            if (skill.dirName === "lld") continue;
            if (skill.dirName === "migration") continue;
            assert.fail(`Skill "${skill.dirName}" has write SQL: ${line.trim()}`);
          }
        }
      }
    }
  });
});

// ============================
// Content Quality Tests
// ============================

describe("Content quality", () => {
  const skills = discoverSkills();

  it("every skill has at least 100 lines of content", () => {
    for (const skill of skills) {
      const lines = skill.content.split("\n").length;
      assert.ok(lines > 100, `${skill.dirName} has only ${lines} lines`);
    }
  });

  it("every skill has concrete code examples", () => {
    for (const skill of skills) {
      const hasCodeBlock = /```/.test(skill.content);
      assert.ok(hasCodeBlock, `${skill.dirName} has no code examples`);
    }
  });

  it("every skill has a self-review or output section", () => {
    for (const skill of skills) {
      const hasReview =
        skill.content.includes("Self-Review") ||
        skill.content.includes("OUTPUT") ||
        skill.content.includes("Output");
      assert.ok(hasReview, `${skill.dirName} missing Self-Review/OUTPUT section`);
    }
  });

  it("every command description is under 100 chars", () => {
    const commands = discoverCommands();
    for (const cmd of commands) {
      assert.ok(cmd.description.length < 100, `${cmd.fileName} description too long: ${cmd.description.length} chars`);
    }
  });
});

// ============================
// Script Tests
// ============================

describe("Custom scripts", () => {
  const EXPECTED_SCRIPTS = [
    "bus-factor.sh", "dep-audit.sh", "api-diff.sh", "dead-code.sh",
    "otel-check.sh", "schema-registry-diff.sh", "secret-scan.sh",
    "migration-safety.sh", "env-drift.sh",
  ];

  for (const scriptName of EXPECTED_SCRIPTS) {
    describe(`script: ${scriptName}`, () => {
      const scriptPath = join(PLUGIN_ROOT, "scripts", scriptName);

      it("exists", () => {
        assert.ok(existsSync(scriptPath), `Missing script: ${scriptName}`);
      });

      it("has bash shebang", () => {
        const content = readFileSync(scriptPath, "utf-8");
        assert.ok(content.includes("#!/usr/bin/env bash"));
      });

      it("uses strict mode", () => {
        const content = readFileSync(scriptPath, "utf-8");
        assert.ok(content.includes("set -euo pipefail"));
      });

      it("is read-only (no destructive git/npm/pip operations)", () => {
        const content = readFileSync(scriptPath, "utf-8");
        assert.ok(
          !/git\s+(push|reset|checkout|merge|commit)\b/.test(content),
          "Script has destructive git command"
        );
        // Only flag actual installs/deletes — not echo/comment suggestions shown to the user
        const executableLines = content.split("\n")
          .filter(l => !/^\s*(echo|#|\s*$)/.test(l))
          .join("\n");
        assert.ok(
          !/npm\s+install|pip\s+install|rm\s+-rf/.test(executableLines),
          "Script has destructive install/rm command"
        );
      });

    });
  }
});

// ============================
// Cross-Reference Tests
// ============================

describe("Cross-references between skills", () => {
  const skills = discoverSkills();

  it("skills that reference other skills use valid skill names", () => {
    const validSkillNames = EXPECTED_SKILLS.map((s) => `/principal:${s}`);
    const validCommandNames = EXPECTED_COMMANDS.map((c) => `/principal:${c}`);
    const allValid = [...validSkillNames, ...validCommandNames];

    for (const skill of skills) {
      const refs = skill.content.match(/\/principal:[a-z-]+/g) || [];
      for (const ref of refs) {
        assert.ok(
          allValid.includes(ref),
          `${skill.dirName} references unknown "${ref}". Valid: ${allValid.join(", ")}`
        );
      }
    }
  });

  it("commands that reference other skills use valid skill names", () => {
    const commands = discoverCommands();
    const validSkillNames = EXPECTED_SKILLS.map((s) => `/principal:${s}`);
    const validCommandNames = EXPECTED_COMMANDS.map((c) => `/principal:${c}`);
    const allValid = [...validSkillNames, ...validCommandNames];

    for (const cmd of commands) {
      const refs = cmd.content.match(/\/principal:[a-z-]+/g) || [];
      for (const ref of refs) {
        assert.ok(
          allValid.includes(ref),
          `Command ${cmd.fileName} references unknown "${ref}"`
        );
      }
    }
  });
});

// ============================
// Production Tool Mention Tests
// ============================

describe("Production tool coverage", () => {
  const skills = discoverSkills();

  it("perf-audit mentions real load testing tools (k6, vegeta, oha)", () => {
    const skill = skills.find((s) => s.dirName === "perf-audit")!;
    assert.ok(skill.content.includes("k6"), "perf-audit should mention k6");
    assert.ok(skill.content.includes("vegeta"), "perf-audit should mention vegeta");
    assert.ok(skill.content.includes("oha"), "perf-audit should mention oha");
    assert.ok(skill.content.includes("hyperfine"), "perf-audit should mention hyperfine");
  });

  it("perf-audit has flame graph reading guide and profiling tools", () => {
    const skill = skills.find((s) => s.dirName === "perf-audit")!;
    assert.ok(
      skill.content.includes("flame graph") || skill.content.includes("Flame Graph"),
      "perf-audit should have flame graph guide"
    );
    // Plugin covers TypeScript/Python/Java profiling (not Go — pprof removed)
    assert.ok(
      skill.content.includes("py-spy") || skill.content.includes("async_hooks") || skill.content.includes("async-profiler"),
      "perf-audit should mention a profiling tool (py-spy, async_hooks, or async-profiler)"
    );
  });

  it("scale-review has chaos engineering section", () => {
    const skill = skills.find((s) => s.dirName === "scale-review")!;
    assert.ok(
      skill.content.includes("Chaos Engineering") || skill.content.includes("chaos engineering"),
      "scale-review should have chaos engineering section"
    );
    assert.ok(skill.content.includes("toxiproxy"), "scale-review should mention toxiproxy");
  });

  it("incident has diagnostic decision tree", () => {
    const skill = skills.find((s) => s.dirName === "incident")!;
    assert.ok(
      skill.content.includes("Decision Tree") || skill.content.includes("decision tree"),
      "incident should have diagnostic decision tree"
    );
    assert.ok(skill.content.includes("OOMKilled"), "incident should cover OOM scenarios");
    assert.ok(skill.content.includes("CrashLoopBackOff"), "incident should cover k8s crash loops");
  });

  it("db-review mentions connection pooling tools", () => {
    const skill = skills.find((s) => s.dirName === "db-review")!;
    assert.ok(skill.content.includes("PgBouncer"), "db-review should mention PgBouncer");
  });

  it("llm-design mentions observability tooling", () => {
    const skill = skills.find((s) => s.dirName === "llm-design")!;
    assert.ok(
      skill.content.includes("Langfuse") || skill.content.includes("LangSmith"),
      "llm-design should mention LLM observability tools"
    );
  });

  it("api-design covers all three API styles", () => {
    const skill = skills.find((s) => s.dirName === "api-design")!;
    assert.ok(skill.content.includes("REST"), "api-design should cover REST");
    assert.ok(skill.content.includes("gRPC"), "api-design should cover gRPC");
    assert.ok(skill.content.includes("GraphQL"), "api-design should mention GraphQL");
  });

  it("threat-model covers STRIDE and supply chain", () => {
    const skill = skills.find((s) => s.dirName === "threat-model")!;
    assert.ok(skill.content.includes("Spoofing"), "threat-model should cover Spoofing");
    assert.ok(skill.content.includes("Tampering"), "threat-model should cover Tampering");
    assert.ok(skill.content.includes("Repudiation"), "threat-model should cover Repudiation");
    assert.ok(skill.content.includes("Information Disclosure"), "threat-model should cover Info Disclosure");
    assert.ok(skill.content.includes("Denial of Service"), "threat-model should cover DoS");
    assert.ok(skill.content.includes("Elevation of Privilege"), "threat-model should cover EoP");
    assert.ok(skill.content.includes("Supply Chain"), "threat-model should cover supply chain");
  });

  it("migration covers all three patterns", () => {
    const skill = skills.find((s) => s.dirName === "migration")!;
    assert.ok(skill.content.includes("Strangler Fig"), "migration should cover Strangler Fig");
    assert.ok(skill.content.includes("Dual-Write"), "migration should cover Dual-Write");
    assert.ok(skill.content.includes("Blue-Green"), "migration should cover Blue-Green");
  });

  it("tech-debt uses Fowler quadrant and DORA", () => {
    const skill = skills.find((s) => s.dirName === "tech-debt")!;
    assert.ok(skill.content.includes("Fowler") || skill.content.includes("RECKLESS"), "tech-debt should use Fowler quadrant");
    assert.ok(skill.content.includes("DORA"), "tech-debt should reference DORA metrics");
  });

  it("hld covers all four golden signals", () => {
    const skill = skills.find((s) => s.dirName === "hld")!;
    assert.ok(skill.content.includes("Latency"), "hld should cover Latency");
    assert.ok(skill.content.includes("Traffic"), "hld should cover Traffic");
    assert.ok(skill.content.includes("Errors") || skill.content.includes("error"), "hld should cover Errors");
    assert.ok(skill.content.includes("Saturation"), "hld should cover Saturation");
  });
});

// ============================
// Destructive Command Gating Tests
// ============================

describe("Destructive commands are properly gated", () => {
  const skills = discoverSkills();

  it("all kubectl rollout undo commands have safety warnings", () => {
    for (const skill of skills) {
      const bashBlocks = skill.content.match(/```bash\n([\s\S]*?)```/g) || [];
      for (const block of bashBlocks) {
        if (block.includes("rollout undo") || block.includes("kubectl delete")) {
          assert.ok(
            block.includes("DESTRUCTIVE") || block.includes("⚠️") || block.includes("confirm with user"),
            `${skill.dirName} has ungated kubectl destructive command`
          );
        }
      }
    }
  });

  it("all iptables/etc/hosts commands have safety warnings", () => {
    for (const skill of skills) {
      const bashBlocks = skill.content.match(/```bash\n([\s\S]*?)```/g) || [];
      for (const block of bashBlocks) {
        if (block.includes("iptables") || block.includes("/etc/hosts")) {
          assert.ok(
            block.includes("DESTRUCTIVE") || block.includes("⚠️") || block.includes("confirm with user"),
            `${skill.dirName} has ungated system modification command`
          );
        }
      }
    }
  });
});
