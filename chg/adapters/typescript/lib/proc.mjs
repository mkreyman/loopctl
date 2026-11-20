// Child processes for the adapter. Only the contract document may reach stdout, so a
// child's stdout goes to our stderr (`stream`) or is captured and echoed there (`capture`).
import { spawn } from "node:child_process";

// Runs `cmd args` from `cwd`; resolves to its exit status. Output goes to stderr.
export function stream(cmd, args, { cwd = process.cwd(), env = {} } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", 2, 2],
    });
    child.on("error", reject);
    child.on("close", (code, signal) => resolve(code ?? (signal ? 128 : 1)));
  });
}

// Runs `cmd args` and captures stdout, echoing it to stderr so a slow step still shows
// progress. The child's stderr goes straight to ours, or with `stderr: true` into the
// capture as well, interleaved as it arrives.
export function capture(cmd, args, { cwd = process.cwd(), env = {}, echo = true, stderr = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {
      cwd,
      env: { ...process.env, ...env },
      stdio: ["ignore", "pipe", stderr ? "pipe" : 2],
    });
    const chunks = [];
    const take = (d) => {
      chunks.push(d);
      if (echo) process.stderr.write(d);
    };
    child.stdout.on("data", take);
    if (stderr) child.stderr.on("data", take);
    child.on("error", reject);
    child.on("close", (code, signal) =>
      resolve({ status: code ?? (signal ? 128 : 1), out: Buffer.concat(chunks).toString("utf8") }),
    );
  });
}

// A shell command line, run under `sh -c` with `env` added; `out` holds its stdout and
// stderr, so a failure message carries whichever the command wrote its reason to.
export function shell(line, opts = {}) {
  return capture("sh", ["-c", line], { ...opts, stderr: true });
}

// The last `n` lines of `text`, for a failure message.
export function tail(text, n = 40) {
  return text.split("\n").slice(-n).join("\n").trim();
}
