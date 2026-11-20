import { expect, test } from "vitest";
import { shout } from "./strings.ts";

test("shout upper-cases", () => {
  expect(shout("a")).toBe("A");
});

test.skip("a skipped test", () => {});
