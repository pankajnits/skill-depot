/**
 * skill-parser.ts — Parse and validate SKILL.md and command files for the principal plugin
 */

import { readFileSync, readdirSync, statSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
export const PLUGIN_ROOT = join(__dirname, "..", "..");

// --- Types ---

export interface SkillFrontmatter {
  name: string;
  description: string;
  "allowed-tools": string[];
  [key: string]: unknown;
}

export interface ParsedSkill {
  path: string;
  dirName: string;
  frontmatter: SkillFrontmatter;
  content: string;
  rawYaml: string;
}

export interface ParsedCommand {
  path: string;
  fileName: string;
  description: string;
  content: string;
  hasArguments: boolean;
}

export interface ValidationResult {
  valid: boolean;
  errors: string[];
  warnings: string[];
}

// --- Valid values ---

export const VALID_TOOLS = [
  "Bash",
  "Read",
  "Write",
  "Edit",
  "Grep",
  "Glob",
  "AskUserQuestion",
];

// Dangerous commands that should not appear in skills (outside of explicitly gated sections)
export const DANGEROUS_PATTERNS = [
  /rm\s+-rf\s/,
  /DROP\s+(TABLE|DATABASE|INDEX)/i,
  /DELETE\s+FROM/i,
  /kubectl\s+delete/,
  /git\s+reset\s+--hard/,
  /git\s+push\s+--force/,
  /truncate\s+table/i,
];

// --- Parsers ---

export function parseSkillFrontmatter(content: string): {
  frontmatter: SkillFrontmatter;
  body: string;
  rawYaml: string;
} {
  const match = content.match(/^---\n([\s\S]*?)\n---\n([\s\S]*)$/);
  if (!match) {
    throw new Error("No YAML frontmatter found");
  }

  const rawYaml = match[1];
  const body = match[2];

  // Simple YAML parser for our known structure
  const frontmatter: Record<string, unknown> = {};
  let currentKey = "";
  let multilineValue = "";
  let inMultiline = false;
  let inArray = false;
  const arrayValues: string[] = [];

  for (const line of rawYaml.split("\n")) {
    if (inMultiline) {
      if (line.match(/^\S/) && !line.startsWith("  ")) {
        frontmatter[currentKey] = multilineValue.trim();
        inMultiline = false;
      } else {
        multilineValue += line.replace(/^  /, "") + "\n";
        continue;
      }
    }

    if (inArray) {
      if (line.match(/^\s+-\s+/)) {
        arrayValues.push(line.replace(/^\s+-\s+/, "").trim());
        continue;
      } else {
        frontmatter[currentKey] = [...arrayValues];
        inArray = false;
        arrayValues.length = 0;
      }
    }

    const kvMatch = line.match(/^(\S+):\s*(.*)$/);
    if (kvMatch) {
      currentKey = kvMatch[1];
      const value = kvMatch[2].trim();

      if (value === "|") {
        inMultiline = true;
        multilineValue = "";
      } else if (value === "") {
        // Could be start of array
        inArray = true;
      } else {
        frontmatter[currentKey] = value;
      }
    }
  }

  // Flush any remaining multiline or array
  if (inMultiline) {
    frontmatter[currentKey] = multilineValue.trim();
  }
  if (inArray && arrayValues.length > 0) {
    frontmatter[currentKey] = [...arrayValues];
  }

  return {
    frontmatter: frontmatter as SkillFrontmatter,
    body,
    rawYaml,
  };
}

export function parseCommandFile(content: string): {
  description: string;
  body: string;
} {
  // Commands have double --- opener: ---\n---\ndescription: ...\n---
  const match = content.match(
    /^---\n---\ndescription:\s*(.*)\n---\n([\s\S]*)$/
  );
  if (!match) {
    throw new Error("Invalid command format (expected ---\\n---\\ndescription: ...\\n---)");
  }

  return {
    description: match[1].trim(),
    body: match[2],
  };
}

// --- Discovery ---

export function discoverSkills(): ParsedSkill[] {
  const skillsDir = join(PLUGIN_ROOT, "skills");
  if (!existsSync(skillsDir)) return [];

  const dirs = readdirSync(skillsDir).filter((d) => {
    const fullPath = join(skillsDir, d);
    return statSync(fullPath).isDirectory();
  });

  return dirs.map((dir) => {
    const skillPath = join(skillsDir, dir, "SKILL.md");
    if (!existsSync(skillPath)) {
      throw new Error(`Skill directory ${dir}/ has no SKILL.md`);
    }

    const content = readFileSync(skillPath, "utf-8");
    const { frontmatter, body, rawYaml } = parseSkillFrontmatter(content);

    return {
      path: skillPath,
      dirName: dir,
      frontmatter,
      content: body,
      rawYaml,
    };
  });
}

export function discoverCommands(): ParsedCommand[] {
  const commandsDir = join(PLUGIN_ROOT, "commands");
  if (!existsSync(commandsDir)) return [];

  const files = readdirSync(commandsDir).filter((f) => f.endsWith(".md"));

  return files.map((file) => {
    const cmdPath = join(commandsDir, file);
    const content = readFileSync(cmdPath, "utf-8");
    const { description, body } = parseCommandFile(content);

    return {
      path: cmdPath,
      fileName: file.replace(".md", ""),
      description,
      content: body,
      hasArguments: body.includes("$ARGUMENTS"),
    };
  });
}

// --- Validators ---

export function validateSkill(skill: ParsedSkill): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];

  // Name must match directory
  if (skill.frontmatter.name !== skill.dirName) {
    errors.push(
      `name "${skill.frontmatter.name}" doesn't match directory "${skill.dirName}"`
    );
  }

  // Description must exist and use multiline |
  if (!skill.frontmatter.description) {
    errors.push("missing description");
  }
  if (!skill.rawYaml.includes("description: |")) {
    errors.push("description should use multiline | syntax");
  }

  // allowed-tools must be valid
  const tools = skill.frontmatter["allowed-tools"];
  if (!tools || !Array.isArray(tools)) {
    errors.push("missing or invalid allowed-tools");
  } else {
    for (const tool of tools) {
      if (!VALID_TOOLS.includes(tool)) {
        errors.push(`invalid tool: "${tool}"`);
      }
    }
  }

  // No stale /arch: references
  const fullText = skill.rawYaml + "\n" + skill.content;
  if (fullText.includes("/arch:")) {
    errors.push('contains stale "/arch:" reference');
  }

  // Check for unsafe commands outside gated sections
  const bashBlocks = fullText.match(/```bash\n([\s\S]*?)```/g) || [];
  for (const block of bashBlocks) {
    // Skip blocks that have explicit safety warnings
    if (block.includes("DESTRUCTIVE") || block.includes("STOP") || block.includes("confirm with user")) {
      continue;
    }
    for (const pattern of DANGEROUS_PATTERNS) {
      if (pattern.test(block)) {
        warnings.push(
          `potentially unsafe command pattern: ${pattern.source} (consider adding safety warning)`
        );
      }
    }
  }

  return { valid: errors.length === 0, errors, warnings };
}

export function validateCommand(cmd: ParsedCommand): ValidationResult {
  const errors: string[] = [];
  const warnings: string[] = [];

  // Must have description
  if (!cmd.description) {
    errors.push("missing description");
  }

  // Must reference $ARGUMENTS
  if (!cmd.hasArguments) {
    errors.push("does not reference $ARGUMENTS");
  }

  // Must end with ---
  if (!cmd.content.trimEnd().endsWith("---")) {
    errors.push("does not end with ---");
  }

  return { valid: errors.length === 0, errors, warnings };
}

// --- Plugin manifest ---

export function readPluginJson(): Record<string, unknown> {
  const path = join(PLUGIN_ROOT, ".claude-plugin", "plugin.json");
  return JSON.parse(readFileSync(path, "utf-8"));
}

export function readMarketplaceJson(): Record<string, unknown> {
  const path = join(PLUGIN_ROOT, "..", ".claude-plugin", "marketplace.json");
  return JSON.parse(readFileSync(path, "utf-8"));
}
