// Reads an import_stories payload from an absolute file path.
//
// Security: `payload_path` is read with the MCP process's filesystem privileges and an
// agent can set it via prompt injection, so a hostile path must learn NOTHING about a file
// that is not an import payload, and such a file must never be uploaded:
//   * require an absolute path ending in .json, checked on the path AND on its realpath,
//     so a symlink named x.json cannot point at /etc/passwd or /proc
//   * reject /proc, /dev, /sys (pseudo-filesystems that could DoS or leak)
//   * stat first and cap at 5 MiB (server also enforces a body size limit)
//   * never echo a JSON.parse or fs error message: V8's SyntaxError quotes the file's
//     content ("root:x:0:0"... is not valid JSON), so only err.code is reported
//   * require the Epic 12 import shape (an object with an `epics` array) before returning,
//     so a valid JSON file that is not a payload (a credentials file) is never POSTed
//
// Returns the parsed payload on success, or an { error, status, body } shape on failure.

import nodePath from "node:path";
import defaultFs from "node:fs/promises";

export const MAX_PAYLOAD_BYTES = 5 * 1024 * 1024;

const BLOCKED_ROOTS = ["/proc", "/dev", "/sys"];

function refuse(body) {
  return { error: true, status: 0, body };
}

function isBlocked(p) {
  return BLOCKED_ROOTS.some((root) => p === root || p.startsWith(root + "/"));
}

function hasJsonExtension(p) {
  return nodePath.extname(p).toLowerCase() === ".json";
}

export async function readPayloadFile(payloadPath, { fs = defaultFs } = {}) {
  if (typeof payloadPath !== "string" || !nodePath.isAbsolute(payloadPath)) {
    return refuse(`payload_path must be absolute (got '${payloadPath}').`);
  }

  if (isBlocked(nodePath.resolve(payloadPath))) {
    return refuse(`payload_path refused: '${payloadPath}' targets a pseudo-filesystem path.`);
  }

  if (!hasJsonExtension(payloadPath)) {
    return refuse(`payload_path refused: '${payloadPath}' must be a .json file.`);
  }

  let realPath;
  try {
    realPath = await fs.realpath(payloadPath);
  } catch (err) {
    return refuse(`Could not read payload_path '${payloadPath}' (${err.code || "error"}).`);
  }

  if (isBlocked(realPath)) {
    return refuse(`payload_path refused: '${payloadPath}' targets a pseudo-filesystem path.`);
  }

  if (!hasJsonExtension(realPath)) {
    return refuse(`payload_path refused: '${payloadPath}' must be a .json file.`);
  }

  let raw;
  try {
    const stat = await fs.stat(realPath);
    if (!stat.isFile()) {
      return refuse(`payload_path '${payloadPath}' is not a regular file.`);
    }
    if (stat.size > MAX_PAYLOAD_BYTES) {
      return refuse(
        `payload_path '${payloadPath}' is ${stat.size} bytes, exceeds max ${MAX_PAYLOAD_BYTES}.`,
      );
    }
    raw = await fs.readFile(realPath, "utf8");
  } catch (err) {
    return refuse(`Could not read payload_path '${payloadPath}' (${err.code || "error"}).`);
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    return refuse(`payload_path '${payloadPath}' is not valid JSON.`);
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || !Array.isArray(parsed.epics)) {
    return refuse(
      `payload_path '${payloadPath}' is not an import payload (expected an object with an "epics" array).`,
    );
  }

  return parsed;
}
