// Vitest and Playwright JSON reports as contract results: {id, status, ms}. An id is
// `<repo-relative file> > <test's full name>`, stable when lines move; a repeated name in
// one file gets ` #2`, ` #3`.
import { isAbsolute, join, relative } from "node:path";

const VITEST = { passed: "pass", failed: "fail", skipped: "skip", pending: "skip", todo: "skip", disabled: "skip" };

export function fromVitest(report, root) {
  const out = [];
  for (const file of report.testResults ?? []) {
    const rel = relative(root, file.name);
    if ((file.assertionResults ?? []).length === 0) {
      // A file that failed to load or collect reports no tests, only its own status.
      if (file.status === "failed") out.push({ id: rel, status: "error", ms: duration(file) });
      continue;
    }
    for (const t of file.assertionResults) {
      out.push({ id: `${rel} > ${t.fullName}`, status: VITEST[t.status] ?? "error", ms: Math.round(t.duration ?? 0) });
    }
  }
  return unique(out);
}

const duration = (f) => (f.endTime && f.startTime ? Math.max(0, Math.round(f.endTime - f.startTime)) : 0);

export function fromPlaywright(report, root) {
  const base = report.config?.rootDir ?? root;
  const out = [];
  const walk = (suite, titles) => {
    for (const spec of suite.specs ?? []) {
      const rel = relative(root, isAbsolute(spec.file) ? spec.file : join(base, spec.file));
      for (const t of spec.tests ?? []) {
        const project = t.projectName ? `[${t.projectName}] ` : "";
        const ms = (t.results ?? []).reduce((a, r) => a + (r.duration ?? 0), 0);
        out.push({ id: `${rel} > ${project}${[...titles, spec.title].join(" ")}`, status: playwrightStatus(t), ms });
      }
    }
    for (const child of suite.suites ?? []) walk(child, child.title ? [...titles, child.title] : titles);
  };
  // The top-level suites are the files; their titles are the file names, not test titles.
  for (const file of report.suites ?? []) walk(file, []);
  for (const e of report.errors ?? []) {
    const file = e.location?.file;
    out.push({ id: file ? relative(root, file) : "playwright", status: "error", ms: 0 });
  }
  return unique(out);
}

function playwrightStatus(t) {
  const last = (t.results ?? []).at(-1)?.status;
  if (t.status === "skipped" || last === "skipped") return "skip";
  if (t.status === "expected" || t.status === "flaky") return "pass";
  return "fail";
}

function unique(results) {
  const seen = new Map();
  return results.map((r) => {
    const n = (seen.get(r.id) ?? 0) + 1;
    seen.set(r.id, n);
    return n === 1 ? r : { ...r, id: `${r.id} #${n}` };
  });
}

// Every listed path gets at least one result: a path no runner reported is an error when
// its runner failed (it may not have run at all), and a skip when it simply holds no tests.
export function cover(results, paths, failedRunners) {
  const extra = [];
  for (const { path, runner } of paths) {
    const file = path.replace(/:\d+$/, "");
    const hit = results.some((r) => r.id === file || r.id.startsWith(file + " > "));
    if (!hit) extra.push({ id: path, status: failedRunners.has(runner) ? "error" : "skip", ms: 0 });
  }
  return [...results, ...extra];
}

// The JSON document a tool printed last: the latest line opening a JSON value at
// column 0 from which the rest of the output parses. Log lines before it, bracketed
// ones included, are skipped.
export function lastJson(out) {
  const starts = [...out.matchAll(/^[[{]/gm)].map((m) => m.index).reverse();
  for (const at of starts) {
    try {
      return JSON.parse(out.slice(at));
    } catch {
      // a log line that happens to open with a bracket; try an earlier start
    }
  }
  throw new Error(`no JSON in: ${out.split("\n").slice(-5).join("\n").trim()}`);
}
