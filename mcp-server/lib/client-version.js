/**
 * The factory-client header (US-52.8).
 *
 * Every request `apiCall` makes names this package as `x-loopctl-client: mcp/<version>`.
 * loopctl compares that version with the `mcp` component of the release set it was built from
 * and answers `426 incompatible_client_version` (`component`, `sent`, `minimum`) to a package
 * below that component's minimum, before it reads the key. A request without the header is
 * never refused, so a package older than this module is not refused either.
 *
 * This is NOT `x-loopctl-client-context`: that header is analytics-only and never gates
 * anything. This one is judged.
 */

/** The request header a factory client names itself in. */
export const CLIENT_HEADER = "x-loopctl-client";

/** The header value for package version `version`. */
export function clientHeaderValue(version) {
  return `mcp/${version}`;
}

/**
 * The tool-facing error for a 426: the minimum the server accepts and the remedy. The remedy
 * is a reconnect (`/mcp`) or a session restart, and it works only once that version is on
 * npm: the deploy and the npm publish fire independently (see ./mcp-version.js).
 */
export function incompatibleClientError(body, version) {
  const error = (body && typeof body === "object" && body.error) || {};
  const minimum = typeof error.minimum === "string" ? error.minimum : "a newer version";

  return {
    error: true,
    status: 426,
    body: {
      code: "incompatible_client_version",
      component: "mcp",
      sent: version,
      minimum,
      message:
        `loopctl refuses loopctl-mcp-server ${version}: it needs ${minimum} or later. ` +
        "Reconnect the MCP server (/mcp) or restart the session once that version is " +
        "published on npm; mcp_version reports whether it is.",
    },
  };
}
