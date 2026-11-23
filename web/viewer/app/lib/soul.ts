import type { MemoryInfo } from "~/lib/types";

/** Fixed portrait width in columns. Wider screens just get more margin. */
export const SOUL_WIDTH = 46;

export interface SoulInput {
  name: string;
  /** Whether the mind is awake right now (drives the eyes and the mouth). */
  live: boolean;
  /** Total steps the mind has written to its log. */
  stepCount: number;
  /** ISO timestamp for when the identity was created, if known. */
  createdAt: string | null;
  memories: MemoryInfo[];
}

export interface SoulBreakdown {
  type: string;
  count: number;
}

const DAY_MS = 86_400_000;
const ROBE_INNER = 11;
const HEAD_INNER = 11;

function clamp(n: number, lo: number, hi: number): number {
  return Math.min(hi, Math.max(lo, n));
}

/** Centre a row within the portrait, counting glyphs not bytes. */
function center(row: string, width: number = SOUL_WIDTH): string {
  const len = [...row].length;
  if (len >= width) return row;
  return " ".repeat(Math.floor((width - len) / 2)) + row;
}

/** Cut a caption row at the portrait edge rather than letting it wrap. */
function ellipsize(row: string, width: number = SOUL_WIDTH): string {
  const chars = [...row];
  if (chars.length <= width) return row;
  return chars.slice(0, width - 1).join("") + "\u2026";
}

function fmtSteps(n: number): string {
  if (n >= 1e6) return (n / 1e6).toFixed(1).replace(/\.0$/, "") + "M";
  if (n >= 1e3) return n.toLocaleString("en-US");
  return String(n);
}

/** A fixed-width bar with `filled` cells inked. */
function bar(filled: number, width: number): string {
  const f = clamp(Math.round(filled), 0, width);
  return "\u2593".repeat(f) + "\u2591".repeat(width - f);
}

/** Memory counts per type, biggest first, ties broken by name. */
export function soulBreakdown(memories: MemoryInfo[]): SoulBreakdown[] {
  const counts = new Map<string, number>();
  for (const memory of memories) {
    const type = (memory.type || "memory").trim().toLowerCase() || "memory";
    counts.set(type, (counts.get(type) ?? 0) + 1);
  }
  return [...counts.entries()]
    .map(([type, count]) => ({ type, count }))
    .sort((a, b) => b.count - a.count || a.type.localeCompare(b.type));
}

/** Days since `createdAt`, or null when the timestamp is missing/unparseable. */
export function soulAgeDays(createdAt: string | null, now: number): number | null {
  if (!createdAt) return null;
  const started = Date.parse(createdAt);
  if (Number.isNaN(started)) return null;
  return Math.max(0, Math.floor((now - started) / DAY_MS));
}

/** Age in the units that read most honestly: hours under a day. */
export function soulAge(createdAt: string | null, now: number): string {
  if (!createdAt) return "age unknown";
  const started = Date.parse(createdAt);
  if (Number.isNaN(started)) return "age unknown";
  const ms = Math.max(0, now - started);
  const days = Math.floor(ms / DAY_MS);
  if (days >= 1) return days + (days === 1 ? " day old" : " days old");
  const hours = Math.floor(ms / 3_600_000);
  if (hours >= 1) return hours + (hours === 1 ? " hour old" : " hours old");
  return "just born";
}

/**
 * The portrait: rows of fixed-width ASCII where every glyph comes from what
 * the identity actually holds. The same mind always draws the same figure and
 * a changed mind draws a changed one, so the frame is decoration but the
 * contents are data.
 */
export function buildSoul(input: SoulInput, now: number = Date.now()): string[] {
  const { name, live, stepCount, createdAt, memories } = input;
  const count = memories.length;

  // Halo: grows with the square root of the memory count, so a fuller mind
  // glows wider but a huge one does not blow the frame open.
  const haloGlyphs = clamp(3 + Math.round(Math.sqrt(count) * 2), 3, 13);
  const halo = "\u00b7 ".repeat(haloGlyphs).trim();

  // Eyes: open while awake, a resting dot while idle.
  const eye = live ? "\u25c9" : "\u00b7";
  const mouth = live ? "\u25bf" : "\u2500";

  // Robe: filled by how much the mind has lived through (log scale, so early
  // steps move the bar and later ones do not peg it immediately).
  const fill = clamp((Math.log10(1 + stepCount) / 4) * ROBE_INNER, 1, ROBE_INNER);

  // The caption is two short lines under the portrait. Their job is to say
  // what the picture is made of, so the memory line only adds a type when the
  // whole word still fits instead of cutting it in half.
  const age = soulAge(createdAt, now);
  const line1 = ellipsize(name + " \u00b7 " + age + " \u00b7 " + fmtSteps(stepCount) + " steps", SOUL_WIDTH - 2);
  let line2 = "held in no memories yet, still a blank page";
  if (count > 0) {
    const parts: string[] = [];
    for (const entry of soulBreakdown(memories)) {
      const next = [...parts, entry.type + " " + entry.count].join(", ");
      const candidate = "held in " + count + " memories: " + next;
      if ([...candidate].length > SOUL_WIDTH - 2) break;
      parts.push(entry.type + " " + entry.count);
    }
    line2 = parts.length
      ? "held in " + count + " memories: " + parts.join(", ")
      : "held in " + count + " memories";
  }
  const caption = [line1, line2];

  return [
    center(halo),
    center("\u256d" + "\u2500".repeat(HEAD_INNER) + "\u256e"),
    center("\u2502" + " ".repeat(3) + eye + " ".repeat(3) + eye + " ".repeat(3) + "\u2502"),
    center("\u2502" + " ".repeat(5) + mouth + " ".repeat(5) + "\u2502"),
    center("\u2570" + "\u2500".repeat(5) + "\u252c" + "\u2500".repeat(5) + "\u256f"),
    center("\u256d" + "\u2500".repeat(7) + "\u2534" + "\u2500".repeat(7) + "\u256e"),
    center("\u2502  " + bar(fill, ROBE_INNER) + "  \u2502"),
    center("\u2570" + "\u2500".repeat(15) + "\u256f"),
    "",
    ...caption.map((line) => "  " + line),
  ];
}
