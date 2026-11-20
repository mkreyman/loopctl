// Sorting the changed paths for `affected`. Pure, so the rules are testable without a
// workspace.
import { extname } from "node:path";
import { any } from "./glob.mjs";
import { owner } from "./workspace.mjs";

// Extensions Vitest's and Playwright's module graphs follow through imports.
export const CODE = new Set([".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"]);

// Splits the changed paths:
//   ignored  - match an --ignore glob, select nothing;
//   code     - present source files in a package or the e2e directory, left to the
//              module graphs (`vitest list --changed`, `playwright --only-changed`);
//   seeds    - packages owning a path the graph cannot see (a deleted file, or one that
//              is not a module: SQL, JSON, CSS, a fixture read from disk), whose tests
//              and dependents' tests all run;
//   outside  - any other path, which selects the whole suite. Code outside the packages
//              (repo scripts) is often run as a subprocess by its tests, not imported.
export function classify({ paths, deleted, ignore, pkgs, e2eDir = "e2e" }) {
  const gone = new Set(deleted);
  const e2e = e2eDir.replace(/\/$/, "") + "/";
  const out = { ignored: [], code: [], seeds: [], blind: [], outside: [] };
  for (const path of paths) {
    const pkg = owner(pkgs, path);
    if (any(ignore, path)) out.ignored.push(path);
    else if (CODE.has(extname(path)) && !gone.has(path) && (pkg || path.startsWith(e2e))) out.code.push(path);
    else {
      if (pkg) {
        out.blind.push(path);
        if (!out.seeds.includes(pkg)) out.seeds.push(pkg);
      } else out.outside.push(path);
    }
  }
  return out;
}

// Test files (repo-relative) that belong to one of `pkgs`.
export function inPackages(files, pkgs) {
  return files.filter((f) => pkgs.some((p) => f.startsWith(p.dir + "/")));
}
