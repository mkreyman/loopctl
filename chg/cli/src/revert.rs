//! `chg revert <culprit>` (story S8): open a PR that reverts a trunk culprit, arm it to
//! merge itself once its checks pass, and file the story to re-land the change.
//!
//! The idempotency key is the culprit: its branch is `auto-revert/<sha12>`, and the PR,
//! the issue and the comment on the culprit's PR each carry a marker naming its sha. A
//! retried job, or a later red run that names the same culprit, finds what was made and
//! does only what is missing, so a culprit gets one revert however often trunk runs
//! red before it merges. Each attempt holds the repo's revert lock throughout.

use std::path::Path;

use serde::Serialize;

use crate::scratch::Scratch;
use crate::store::Store;
use crate::verify::remote_ref;
use crate::{gh, git};

pub struct Options<'a> {
    pub remote: &'a str,
    /// The trunk branch the revert PR targets.
    pub base: &'a str,
    /// The verifier run that found the culprit, named in what is filed.
    pub run_id: &'a str,
    /// The tests that fail from the culprit on, for the PR and the issue.
    pub failing: Vec<String>,
    pub label: &'a str,
    pub fix_label: &'a str,
}

#[derive(Debug, Clone, Serialize)]
pub struct Opened {
    pub culprit: String,
    pub branch: String,
    /// None when the revert does not apply cleanly on the base: the issue says so.
    pub revert_pr: Option<String>,
    /// Whether this attempt opened the PR (false: an earlier one did).
    pub created: bool,
    /// Whether auto-merge is armed on the revert PR (why not: `warnings`).
    pub auto_merge: bool,
    pub culprit_pr: Option<u64>,
    pub fix_issue: Option<String>,
    pub warnings: Vec<String>,
}

pub fn marker(culprit: &str) -> String {
    format!("<!-- chg-revert:{culprit} -->")
}

pub fn branch_for(culprit: &str) -> String {
    format!("auto-revert/{}", &culprit[..12.min(culprit.len())])
}

/// How many labelled PRs or issues a lookup reads. Past it a duplicate becomes possible;
/// listing by label keeps each list far below it.
const LIST_LIMIT: &str = "1000";

pub fn open(repo: &Path, culprit: &str, o: &Options) -> Result<Opened, String> {
    // The revision as the caller's worktree sees it; shared state by git dir.
    let sha = git::resolve(repo, &format!("{culprit}^{{commit}}"))?;
    let git_dir = git::common_dir(repo)?;
    let slug = slug(&git_dir, o.remote)?;
    let branch = branch_for(&sha);
    let mark = marker(&sha);
    let subject = git::text(&git_dir, &["log", "-1", "--format=%s", &sha])?;
    let store = Store::for_repo(&git_dir)?;
    let _lock = store
        .lock_job("revert")
        .map_err(|e| format!("revert lock: {e}"))?;
    let mut warnings = Vec::new();

    let culprit_pr = gh::json(&[
        "api",
        &format!("repos/{slug}/commits/{sha}/pulls"),
        "--jq",
        "[.[] | .number]",
    ])
    .ok()
    .and_then(|v| v.as_array()?.first()?.as_u64());
    let pr_ref = culprit_pr.map(|n| format!(" (#{n})")).unwrap_or_default();
    let tests = if o.failing.is_empty() {
        "(the failing tests were not given)".to_string()
    } else {
        o.failing
            .iter()
            .map(|t| format!("- `{t}`"))
            .collect::<Vec<_>>()
            .join("\n")
    };

    let mut created = false;
    let revert_pr = match find_marked(&slug, "pr", o.label, &mark)? {
        Some(u) => Some(u),
        None => match push_revert(&git_dir, &store, &sha, &branch, o)? {
            Pushed::Conflict(why) => {
                warnings.push(why);
                None
            }
            Pushed::Ready => {
                ensure_label(&slug, o.label, "B60205", "A trunk commit reverted by chg");
                let body = format!(
                    "Reverts {sha} ({subject}){pr_ref}.\n\n\
                     `chg culprit` found that these tests fail from that commit on, and on every rerun:\n\n\
                     {tests}\n\n\
                     Auto-merge is armed: this merges itself once the required checks pass. \
                     The change is re-landed through the fix story.\n\n\
                     Run: {run}\n{mark}\n",
                    run = o.run_id
                );
                let title = format!("Revert \"{subject}\"");
                let u = gh::text(&[
                    "pr", "create", "--repo", &slug, "--base", o.base, "--head", &branch,
                    "--title", &title, "--body", &body, "--label", o.label,
                ])?;
                created = true;
                Some(u.lines().last().unwrap_or(&u).to_string())
            }
        },
    };

    let auto_merge = match &revert_pr {
        Some(u) => match gh::text(&["pr", "merge", u, "--auto", "--squash"]) {
            Ok(_) => true,
            Err(e) => {
                warnings.push(format!("arming auto-merge: {e}"));
                false
            }
        },
        None => false,
    };

    let fix_issue = match find_marked(&slug, "issue", o.fix_label, &mark)? {
        Some(u) => Some(u),
        None => {
            ensure_label(
                &slug,
                o.fix_label,
                "D93F0B",
                "Re-land a change chg reverted",
            );
            let revert_line = match &revert_pr {
                Some(u) => format!("{u} reverts it."),
                None => "The revert does not apply cleanly on the base, so nothing reverted it: \
                         revert it by hand or fix it forward."
                    .to_string(),
            };
            let body = format!(
                "{sha} ({subject}){pr_ref} broke `{base}`. {revert_line}\n\n\
                 Re-land the change with these tests passing:\n\n{tests}\n\n\
                 Run: {run}\n{mark}\n",
                base = o.base,
                run = o.run_id
            );
            let title = format!("Re-land \"{subject}\" (reverted on {})", o.base);
            match gh::text(&[
                "issue",
                "create",
                "--repo",
                &slug,
                "--title",
                &title,
                "--body",
                &body,
                "--label",
                o.fix_label,
            ]) {
                Ok(u) => Some(u.lines().last().unwrap_or(&u).to_string()),
                Err(e) => {
                    warnings.push(format!("filing the fix story: {e}"));
                    None
                }
            }
        }
    };

    // The culprit's author learns it on the PR they are watching: once, by the marker.
    if let (Some(n), Some(u)) = (culprit_pr, &revert_pr) {
        let told = gh::text(&[
            "pr",
            "view",
            &n.to_string(),
            "--repo",
            &slug,
            "--json",
            "comments",
            "--jq",
            ".comments[].body",
        ])
        .map(|c| c.contains(&mark));
        match told {
            Ok(true) => {}
            Ok(false) => {
                let body = format!(
                    "This change broke `{}`: {u} reverts it, and {} tracks re-landing it.\n{mark}",
                    o.base,
                    fix_issue.as_deref().unwrap_or("a fix story")
                );
                if let Err(e) = gh::text(&[
                    "pr",
                    "comment",
                    &n.to_string(),
                    "--repo",
                    &slug,
                    "--body",
                    &body,
                ]) {
                    warnings.push(format!("commenting on #{n}: {e}"));
                }
            }
            Err(e) => warnings.push(format!("reading #{n}'s comments: {e}")),
        }
    }

    Ok(Opened {
        culprit: sha,
        branch,
        revert_pr,
        created,
        auto_merge,
        culprit_pr,
        fix_issue,
        warnings,
    })
}

enum Pushed {
    Ready,
    Conflict(String),
}

/// Pushes `branch` holding the revert of `sha` on top of the remote's base, unless an
/// earlier attempt already pushed it. Built in a throwaway worktree, never a live tree.
/// The caller holds the revert lock.
fn push_revert(
    git_dir: &Path,
    store: &Store,
    sha: &str,
    branch: &str,
    o: &Options,
) -> Result<Pushed, String> {
    if remote_ref(git_dir, o.remote, branch)?.is_some() {
        return Ok(Pushed::Ready);
    }
    let base_sha = remote_ref(git_dir, o.remote, o.base)?
        .ok_or_else(|| format!("{} has no branch {}", o.remote, o.base))?;
    git::text(
        git_dir,
        &[
            "fetch",
            "-q",
            "--no-tags",
            o.remote,
            &format!("refs/heads/{}", o.base),
        ],
    )?;
    if !git::is_ancestor(git_dir, sha, &base_sha)? {
        return Err(format!("{sha} is not on {}/{}", o.remote, o.base));
    }
    let parents = git::text(git_dir, &["rev-list", "--parents", "-n", "1", sha])?
        .split_whitespace()
        .count()
        - 1;

    let scratch = Scratch::at(git_dir, &store.job_dir("revert").join("ws"), &base_sha)?;
    let mut c = git::cmd(&scratch.path);
    c.args(["-c", "core.hooksPath=/dev/null"]);
    if git::text(&scratch.path, &["config", "user.email"]).is_err() {
        c.args([
            "-c",
            "user.name=chg",
            "-c",
            "user.email=chg@users.noreply.github.com",
        ]);
    }
    c.args(["revert", "--no-edit"]);
    if parents > 1 {
        c.args(["-m", "1"]);
    }
    c.arg(sha);
    if let Err(e) = git::run(c) {
        let _ = git::text(&scratch.path, &["revert", "--abort"]);
        return Ok(Pushed::Conflict(format!(
            "the revert of {sha} does not apply cleanly on {}/{}: {e}",
            o.remote, o.base
        )));
    }
    let mut c = git::cmd(&scratch.path);
    c.args(["-c", "core.hooksPath=/dev/null", "push", "-q", o.remote])
        .arg(format!("HEAD:refs/heads/{branch}"));
    git::run(c).map_err(|e| format!("pushing {branch}: {e}"))?;
    Ok(Pushed::Ready)
}

/// A label that already exists is left as it is.
fn ensure_label(slug: &str, name: &str, color: &str, description: &str) {
    let _ = gh::text(&[
        "label",
        "create",
        name,
        "--repo",
        slug,
        "--color",
        color,
        "--description",
        description,
    ]);
}

/// The PR or issue (`kind`), in any state, labelled `label` whose body carries `mark`.
/// Matched locally, not by search, which lags behind a just-created one. A failed list is
/// an error, never "none": that would file a duplicate.
fn find_marked(slug: &str, kind: &str, label: &str, mark: &str) -> Result<Option<String>, String> {
    let v = gh::json(&[
        kind, "list", "--repo", slug, "--label", label, "--state", "all", "--limit", LIST_LIMIT,
        "--json", "url,body",
    ])?;
    Ok(v.as_array()
        .into_iter()
        .flatten()
        .find(|i| i["body"].as_str().is_some_and(|b| b.contains(mark)))
        .and_then(|i| i["url"].as_str().map(String::from)))
}

/// `owner/name` of `remote`, from its configured URL, before any `insteadOf` rewrite: it
/// names the GitHub repo even when git reaches it through an alias or a mirror.
pub fn slug(git_dir: &Path, remote: &str) -> Result<String, String> {
    let url = git::text(
        git_dir,
        &["config", "--get", &format!("remote.{remote}.url")],
    )?;
    git::slug_of(&url).ok_or_else(|| format!("{url} is not a GitHub remote"))
}

/// Files one open issue per flaky test (a test that failed on trunk and passed on a
/// rerun), or comments on the one already open. Idempotent per run: the issue and each
/// comment carry markers, so a retried job adds nothing. Returns the issue URLs.
pub fn file_flaky(
    repo: &Path,
    remote: &str,
    tests: &[String],
    run_id: &str,
    label: &str,
) -> Result<Vec<String>, String> {
    let slug = slug(&git::common_dir(repo)?, remote)?;
    let open = gh::json(&[
        "issue", "list", "--repo", &slug, "--label", label, "--state", "open", "--limit",
        LIST_LIMIT, "--json", "url,body",
    ])?;
    let open = open.as_array().cloned().unwrap_or_default();
    let mut urls = Vec::new();
    for id in tests {
        let mark = format!("<!-- chg-flaky:{id} -->");
        let seen = format!("<!-- chg-flaky-run:{run_id}:{id} -->");
        let existing = open
            .iter()
            .find(|i| i["body"].as_str().is_some_and(|b| b.contains(&mark)));
        match existing.and_then(|i| Some((i["url"].as_str()?, i["body"].as_str()?))) {
            // The run that filed the issue marked it in the body.
            Some((u, body)) if body.contains(&seen) => urls.push(u.to_string()),
            Some((u, _)) => {
                let comments = gh::text(&[
                    "issue",
                    "view",
                    u,
                    "--json",
                    "comments",
                    "--jq",
                    ".comments[].body",
                ])?;
                if !comments.contains(&seen) {
                    gh::text(&[
                        "issue",
                        "comment",
                        u,
                        "--body",
                        &format!(
                            "Failed and then passed on a rerun again, in run {run_id}.\n{seen}"
                        ),
                    ])?;
                }
                urls.push(u.to_string());
            }
            None => {
                ensure_label(
                    &slug,
                    label,
                    "FBCA04",
                    "A test that fails and passes on the same commit",
                );
                let body = format!(
                    "`{id}` failed on trunk and passed when rerun on the same commit (run {run_id}), \
                     so chg left it out of the culprit search and reverted nothing for it. \
                     Make it deterministic.\n\n{mark}\n{seen}\n"
                );
                let u = gh::text(&[
                    "issue",
                    "create",
                    "--repo",
                    &slug,
                    "--title",
                    &format!("Flaky test: {id}"),
                    "--body",
                    &body,
                    "--label",
                    label,
                ])?;
                urls.push(u.lines().last().unwrap_or(&u).to_string());
            }
        }
    }
    Ok(urls)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_branch_and_marker_name_the_culprit() {
        let sha = "0123456789abcdef0123";
        assert_eq!(branch_for(sha), "auto-revert/0123456789ab");
        assert_eq!(marker(sha), "<!-- chg-revert:0123456789abcdef0123 -->");
    }
}
