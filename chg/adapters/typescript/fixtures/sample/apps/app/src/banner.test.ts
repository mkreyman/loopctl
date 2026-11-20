import { expect, test } from "vitest";

test("a test that imports nothing from core", () => {
  expect("app").toHaveLength(3);
});
