//! The manifest's path globs (`inputs`, `always_all`), matched against repo-relative paths.
//!
//! A pattern is anchored at the repo root and split on `/`. A `**` segment matches zero or
//! more whole segments; within a segment `*` matches any run of characters and `?` one
//! character, neither crossing a `/`. Everything else is literal. So `mix.exs` is only the
//! root file, `config/**` is everything under `config/`, and `**/vitest*.config.ts` is a
//! Vitest config at any depth.

pub fn matches(pattern: &str, path: &str) -> bool {
    let p: Vec<&str> = pattern.split('/').collect();
    let s: Vec<&str> = path.split('/').collect();
    segments(&p, &s)
}

fn segments(p: &[&str], s: &[&str]) -> bool {
    match p.split_first() {
        None => s.is_empty(),
        Some((&"**", rest)) => (0..=s.len()).any(|k| segments(rest, &s[k..])),
        Some((first, rest)) => {
            matches!(s.split_first(), Some((name, tail)) if segment(first, name) && segments(rest, tail))
        }
    }
}

/// One segment against a pattern of `*` and `?`, backtracking on the last `*`.
pub fn segment(pattern: &str, name: &str) -> bool {
    let p: Vec<char> = pattern.chars().collect();
    let s: Vec<char> = name.chars().collect();
    let (mut pi, mut si) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while si < s.len() {
        // A `*` is a wildcard even facing a literal `*` in the name, so it is tried first.
        if pi < p.len() && p[pi] == '*' {
            star = Some((pi, si));
            pi += 1;
        } else if pi < p.len() && (p[pi] == '?' || p[pi] == s[si]) {
            pi += 1;
            si += 1;
        } else if let Some((sp, ss)) = star {
            pi = sp + 1;
            si = ss + 1;
            star = Some((sp, ss + 1));
        } else {
            return false;
        }
    }
    p[pi..].iter().all(|&c| c == '*')
}

/// The first `(path, pattern)` where a path matches a pattern.
pub fn first_hit<'a>(patterns: &'a [String], paths: &'a [String]) -> Option<(&'a str, &'a str)> {
    paths.iter().find_map(|path| {
        patterns
            .iter()
            .find(|g| matches(g, path))
            .map(|g| (path.as_str(), g.as_str()))
    })
}

#[cfg(test)]
mod tests {
    use super::matches;

    #[test]
    fn literal_patterns_are_anchored_at_the_root() {
        assert!(matches("mix.exs", "mix.exs"));
        assert!(!matches("mix.exs", "apps/a/mix.exs"));
        assert!(!matches("mix.exs", "mix.exs.bak"));
    }

    #[test]
    fn double_star_spans_zero_or_more_segments() {
        assert!(matches("config/**", "config/runtime.exs"));
        assert!(matches("config/**", "config/a/b/c.exs"));
        assert!(!matches("config/**", "lib/config/x.ex"));
        assert!(matches("**/vitest*.config.ts", "vitest.config.ts"));
        assert!(matches(
            "**/vitest*.config.ts",
            "apps/web/vitest.remote.config.ts"
        ));
        assert!(matches("test/**/x_test.exs", "test/x_test.exs"));
        assert!(matches("test/**/x_test.exs", "test/a/b/x_test.exs"));
    }

    #[test]
    fn single_star_and_question_mark_stay_within_a_segment() {
        assert!(matches("packages/*/dist", "packages/domain/dist"));
        assert!(!matches("packages/*/dist", "packages/a/b/dist"));
        assert!(matches("vitest*.config.ts", "vitest.image.config.ts"));
        assert!(!matches("vitest*.config.ts", "e2e/vitest.config.ts"));
        assert!(matches("a?c", "abc"));
        assert!(!matches("a?c", "a/c"));
        assert!(matches("*a*b", "xxaxxb"));
        assert!(!matches("*a*b", "xxaxxbx"));
    }

    #[test]
    fn a_star_facing_a_literal_star_is_still_a_wildcard() {
        assert!(matches("*.ex", "*x.ex"));
        assert!(matches("a*", "a*b"));
    }
}
