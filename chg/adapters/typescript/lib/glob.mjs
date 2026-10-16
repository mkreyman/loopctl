// Repo-root-anchored globs with chg's semantics (docs/adapter-contract.md): a `**`
// segment matches zero or more whole segments; within a segment `*` matches any run of
// characters and `?` one character, neither crossing a `/`.

export function matches(pattern, path) {
  return segments(pattern.split("/"), path.split("/"));
}

function segments(pat, parts) {
  if (pat.length === 0) return parts.length === 0;
  const [head, ...rest] = pat;
  if (head === "**") {
    for (let i = 0; i <= parts.length; i++) if (segments(rest, parts.slice(i))) return true;
    return false;
  }
  return parts.length > 0 && segment(head, parts[0]) && segments(rest, parts.slice(1));
}

export function segment(pattern, name) {
  const re = new RegExp(
    "^" +
      [...pattern]
        .map((c) => (c === "*" ? "[^/]*" : c === "?" ? "[^/]" : c.replace(/[.+^${}()|[\]\\]/g, "\\$&")))
        .join("") +
      "$",
    "u",
  );
  return re.test(name);
}

export const any = (patterns, path) => patterns.some((p) => matches(p, path));
