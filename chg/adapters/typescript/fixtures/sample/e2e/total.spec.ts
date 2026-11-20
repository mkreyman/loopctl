import { expect, test } from "@playwright/test";
import { total } from "../apps/app/src/total.ts";

test("total is reachable from an e2e spec", () => {
  expect(total([1])).toBe(100);
});
