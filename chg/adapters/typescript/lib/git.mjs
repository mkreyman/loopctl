// The git questions the adapter asks, all from the repo root.
import { execFileSync } from "node:child_process";

function git(args) {
  return execFileSync("git", ["-c", "core.quotepath=off", ...args], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "pipe"],
    maxBuffer: 256 * 1024 * 1024,
  });
}

const zsplit = (out) => out.split("\0").filter(Boolean);

// The commit `rev` names, or throws "`rev` is not a commit".
export function resolve(rev) {
  try {
    return git(["rev-parse", "--verify", "--quiet", `${rev}^{commit}`]).trim();
  } catch {
    throw new Error(`\`${rev}\` is not a commit`);
  }
}

export function head() {
  return resolve("HEAD");
}

// Paths that differ between `base` and the working tree, tracked or untracked, with
// renames split into the deleted and the added path: the set `chg` checks against
// `always_all`. Paths are relative to the cwd (the adapter root) and limited to it, also
// below the git toplevel. `deleted` is the subset no longer in the working tree.
export function changed(base) {
  const sha = resolve(base);
  const diff = zsplit(git(["diff", "--relative", "--no-renames", "--name-only", "-z", sha]));
  const gone = new Set(zsplit(git(["diff", "--relative", "--no-renames", "--name-only", "--diff-filter=D", "-z", sha])));
  const untracked = zsplit(git(["ls-files", "--others", "--exclude-standard", "-z"]));
  const paths = [...new Set([...diff, ...untracked])];
  return { sha, paths, deleted: paths.filter((p) => gone.has(p)) };
}
