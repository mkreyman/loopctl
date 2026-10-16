import { expect, test } from "vitest";
import { cents } from "./money.ts";

test("cents rounds to the nearest cent", () => {
  expect(cents(2.5)).toBe(250);
});
