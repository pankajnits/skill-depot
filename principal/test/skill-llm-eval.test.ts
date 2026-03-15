/**
 * Tier 3: LLM-as-Judge Evaluation for the principal plugin
 *
 * Run with: ANTHROPIC_API_KEY=... node --experimental-strip-types --test test/skill-llm-eval.test.ts
 *
 * Uses Claude Haiku to score each skill on:
 * - Clarity (1-5): Can an AI agent understand instructions without ambiguity?
 * - Completeness (1-5): Are all necessary steps, tools, and patterns documented?
 * - Actionability (1-5): Can the agent execute tasks using only the skill's info?
 *
 * Threshold: >= 4 on all dimensions
 * Cost: ~$0.03 per full run (13 skills × ~1K tokens each)
 *
 * Requires: ANTHROPIC_API_KEY environment variable
 */

import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { discoverSkills } from "./helpers/skill-parser.ts";

const ANTHROPIC_API_KEY = process.env.ANTHROPIC_API_KEY;
const MODEL = "claude-haiku-4-5-20251001";
const THRESHOLD = 4;

interface EvalScores {
  clarity: number;
  completeness: number;
  actionability: number;
  reasoning: string;
}

async function evaluateSkill(skillContent: string, skillName: string): Promise<EvalScores> {
  const response = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-api-key": ANTHROPIC_API_KEY!,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: MODEL,
      max_tokens: 500,
      messages: [
        {
          role: "user",
          content: `You are evaluating a Claude Cowork plugin skill document for quality. Score it on three dimensions (1-5 scale).

SKILL NAME: ${skillName}

SKILL CONTENT:
${skillContent.slice(0, 4000)}

Score each dimension:

1. **Clarity** (1-5): Can an AI agent follow these instructions without ambiguity? Are steps ordered logically? Is terminology consistent?

2. **Completeness** (1-5): Does it cover all necessary steps for the workflow? Are edge cases addressed? Are tools/commands specified?

3. **Actionability** (1-5): Can the agent produce useful output using ONLY the information in this skill? Are there concrete templates, commands, and examples?

Respond in EXACTLY this JSON format (no other text):
{"clarity": N, "completeness": N, "actionability": N, "reasoning": "One sentence summary of overall quality."}`,
        },
      ],
    }),
  });

  if (!response.ok) {
    throw new Error(`Anthropic API error: ${response.status} ${await response.text()}`);
  }

  const data = (await response.json()) as { content: Array<{ text: string }> };
  const text = data.content[0].text;

  const jsonMatch = text.match(/\{[\s\S]*\}/);
  if (!jsonMatch) {
    throw new Error(`Could not parse eval response: ${text}`);
  }

  return JSON.parse(jsonMatch[0]) as EvalScores;
}

// Only run if API key is present
if (ANTHROPIC_API_KEY) {
  describe("LLM-as-Judge evaluation", () => {
    const skills = discoverSkills();

    for (const skill of skills) {
      it(`skill: ${skill.dirName} scores >= ${THRESHOLD} on all dimensions`, { timeout: 30000 }, async () => {
        const fullContent = skill.rawYaml + "\n" + skill.content;
        const scores = await evaluateSkill(fullContent, skill.dirName);

        console.log(
          `  ${skill.dirName}: clarity=${scores.clarity} completeness=${scores.completeness} actionability=${scores.actionability} — ${scores.reasoning}`
        );

        assert.ok(scores.clarity >= THRESHOLD, `Clarity ${scores.clarity} < ${THRESHOLD}`);
        assert.ok(scores.completeness >= THRESHOLD, `Completeness ${scores.completeness} < ${THRESHOLD}`);
        assert.ok(scores.actionability >= THRESHOLD, `Actionability ${scores.actionability} < ${THRESHOLD}`);
      });
    }
  });
} else {
  describe("LLM-as-Judge evaluation (SKIPPED — no ANTHROPIC_API_KEY)", () => {
    it("skipped", () => {
      console.log("Set ANTHROPIC_API_KEY to run LLM eval tests");
    });
  });
}
