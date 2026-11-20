// The pnpm workspace: its packages, which depends on which, and which owns a path.
import { readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { capture } from "./proc.mjs";

// Workspace packages other than the root, as `{name, dir, deps}` with `dir` repo-relative
// and `deps` the names of the workspace packages it depends on.
export async function packages(root) {
  const { status, out } = await capture("pnpm", ["ls", "-r", "--depth", "-1", "--json"], { cwd: root, echo: false });
  if (status !== 0) throw new Error(`pnpm ls exited ${status}`);
  return fromListing(root, JSON.parse(out));
}

export function fromListing(root, listing) {
  const found = listing
    .map((p) => ({ name: p.name, dir: relative(root, p.path) }))
    .filter((p) => p.dir !== "");
  const names = new Set(found.map((p) => p.name));
  return found.map((p) => {
    const manifest = JSON.parse(readFileSync(join(root, p.dir, "package.json"), "utf8"));
    const declared = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"].flatMap((k) =>
      Object.keys(manifest[k] ?? {}),
    );
    return { ...p, deps: [...new Set(declared.filter((d) => names.has(d)))] };
  });
}

// The package whose directory holds `path` (the deepest one), or undefined.
export function owner(pkgs, path) {
  return pkgs
    .filter((p) => path === p.dir || path.startsWith(p.dir + "/"))
    .sort((a, b) => b.dir.length - a.dir.length)[0];
}

// `seeds` plus every package that depends on one of them, transitively: what
// `pnpm --filter "...<pkg>"` selects.
export function withDependents(pkgs, seeds) {
  const out = new Set(seeds.map((p) => p.name));
  let grew = true;
  while (grew) {
    grew = false;
    for (const p of pkgs) {
      if (!out.has(p.name) && p.deps.some((d) => out.has(d))) {
        out.add(p.name);
        grew = true;
      }
    }
  }
  return pkgs.filter((p) => out.has(p.name));
}
