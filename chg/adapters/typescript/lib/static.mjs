// Parsers for the static checks' output, as contract failures {check, file?, line?, message}.
import { relative } from "node:path";
import { tail } from "./proc.mjs";

// `eslint --format json`: errors (severity 2) fail, warnings do not, matching `eslint .`
// without --max-warnings. Output that is not the report becomes one failure.
export function eslintFailures(out, status, root) {
  if (status === 0) return [];
  let report;
  try {
    report = JSON.parse(out);
  } catch {
    return [{ check: "eslint", message: tail(out) || `eslint exited ${status}` }];
  }
  const found = report.flatMap((f) =>
    (f.messages ?? [])
      .filter((m) => m.severity === 2 || m.fatal)
      .map((m) => ({
        check: "eslint",
        file: relative(root, f.filePath),
        ...(m.line ? { line: m.line } : {}),
        message: m.ruleId ? `${m.ruleId}: ${m.message}` : m.message,
      })),
  );
  return found.length ? found : [{ check: "eslint", message: `eslint exited ${status}` }];
}

// `tsc --pretty false`: `file(line,col): error TSnnnn: message`, continuation lines
// indented beneath it. Paths are relative to the cwd tsc ran in, the repo root.
export function tscFailures(out, status, project) {
  if (status === 0) return [];
  const found = [];
  for (const line of out.split("\n")) {
    const m = line.match(/^(.+?)\((\d+),\d+\): error (TS\d+: .*)$/);
    if (m) found.push({ check: "tsc", file: m[1], line: Number(m[2]), message: m[3] });
    else if (found.length && /^\s+\S/.test(line)) found.at(-1).message += "\n" + line.trim();
    else {
      const g = line.match(/^error (TS\d+: .*)$/);
      if (g) found.push({ check: "tsc", message: `${project}: ${g[1]}` });
    }
  }
  return found.length ? found : [{ check: "tsc", message: `${project}: ${tail(out) || `tsc exited ${status}`}` }];
}

// A tsconfig directory as a file name for its .tsbuildinfo.
export const slug = (dir) => (dir === "." || dir === "" ? "root" : dir.replace(/[^A-Za-z0-9._-]+/g, "_"));
