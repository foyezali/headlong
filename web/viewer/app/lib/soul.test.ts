import { describe, expect, it } from "vitest";

import { buildSoul, soulAge, soulBreakdown, SOUL_WIDTH } from "~/lib/soul";
import type { MemoryInfo } from "~/lib/types";

function memory(type: string, id: string): MemoryInfo {
  return { name: `m-${id}.md`, mtime: 0, id, summary: id, type, created: null, slug: id };
}

const base = {
  name: "ada",
  stepCount: 6022,
  createdAt: "2026-11-22T01:04:49",
  memories: [memory("fact", "a"), memory("fact", "b"), memory("goal", "c")],
};

describe("buildSoul", () => {
  it("never lets a row run past the portrait width", () => {
    for (const row of buildSoul({ ...base, live: true })) {
      expect([...row].length).toBeLessThanOrEqual(SOUL_WIDTH);
    }
  });

  it("opens its eyes only while the mind is live", () => {
    const awake = buildSoul({ ...base, live: true }).join("\n");
    const asleep = buildSoul({ ...base, live: false }).join("\n");
    expect(awake).toContain("\u25c9");
    expect(asleep).not.toContain("\u25c9");
  });

  it("says what it is made of", () => {
    const rows = buildSoul({ ...base, live: true }).join("\n");
    expect(rows).toContain("6,022 steps");
    expect(rows).toContain("held in 3 memories");
    expect(rows).toContain("fact 2");
  });

  it("handles a mind with nothing stored yet", () => {
    const rows = buildSoul({ ...base, live: true, memories: [] }).join("\n");
    expect(rows).toContain("no memories yet");
  });
});

describe("soulAge", () => {
  const now = Date.parse("2026-11-23T00:00:00Z");
  it("counts hours under a day", () => {
    expect(soulAge("2026-11-22T01:00:00Z", now)).toBe("23 hours old");
  });
  it("switches to days", () => {
    expect(soulAge("2026-11-21T00:00:00Z", now)).toBe("2 days old");
  });
  it("admits when it cannot tell", () => {
    expect(soulAge(null, now)).toBe("age unknown");
  });
});

describe("soulBreakdown", () => {
  it("orders types by count", () => {
    const out = soulBreakdown(base.memories);
    expect(out[0]).toEqual({ type: "fact", count: 2 });
    expect(out[1]).toEqual({ type: "goal", count: 1 });
  });
});
