import { expect, test } from "vitest";
import { total } from "./total.ts";

test("total sums in cents", () => {
  expect(total([1, 2.5])).toBe(350);
});
