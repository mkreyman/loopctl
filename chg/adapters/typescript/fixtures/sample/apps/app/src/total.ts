import { cents } from "@s/core/money";

export function total(amounts: number[]): number {
  return amounts.reduce((sum, a) => sum + cents(a), 0);
}
