import { readFileSync } from "node:fs";

// Read from disk, not imported: no module graph sees rates.txt.
export function rate(): number {
  return Number(readFileSync(new URL("./rates.txt", import.meta.url), "utf8"));
}
