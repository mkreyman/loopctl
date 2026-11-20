import { expect, test } from "vitest";
import { rate } from "./rates.ts";

test("the rate is read from rates.txt", () => {
  expect(rate()).toBe(2);
});
