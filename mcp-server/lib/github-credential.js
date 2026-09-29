/**
 * `github_credential`, `set_github_credential`, `clear_github_credential` — the tenant's own
 * GitHub token (#936), `GET|PUT|DELETE /api/v1/tenants/me/github-credential`.
 *
 * loopctl calls GitHub for a tenant in the merge gate, story and post-deploy verification,
 * thread checkpoint reads and issue closing. Each call authenticates with the tenant's own
 * token when one is set, else with the operator's token for the (tenant, repository) pairs
 * the operator named in VERIFICATION_OPERATOR_TOKEN_TENANTS, else not at all
 * (`credential_unavailable`). The tenant's token is what lets loopctl serve a repository
 * the operator's token cannot, without ever reading one the tenant cannot.
 *
 * All three need the `:user` key: the endpoint manages a stored credential. The token is
 * never returned — reads show `has_token`, a last-4 `token_hint` and the repositories the
 * operator's token is lent for.
 */

export const GITHUB_CREDENTIAL_PATH = "/api/v1/tenants/me/github-credential";

function refuse(body) {
  return { error: true, status: 0, body };
}

export async function githubCredential(_args = {}, { apiCall } = {}) {
  return apiCall("GET", GITHUB_CREDENTIAL_PATH, null);
}

/**
 * A missing or non-string token is refused HERE, before any call, and the refusal never
 * repeats the value: a tool result lands in the transcript.
 */
export async function setGithubCredential({ token } = {}, { apiCall } = {}) {
  if (typeof token !== "string" || token.trim() === "") {
    return refuse(
      "`token` is required: a GitHub token (a fine-grained token limited to your own " +
        "repositories is the intended shape) with read access to contents, pull requests, " +
        "actions and commit statuses, plus issues: write for issue closing.",
    );
  }

  return apiCall("PUT", GITHUB_CREDENTIAL_PATH, { token });
}

export async function clearGithubCredential(_args = {}, { apiCall } = {}) {
  return apiCall("DELETE", GITHUB_CREDENTIAL_PATH, null);
}
