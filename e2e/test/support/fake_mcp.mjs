// A stand-in MCP stdio server for LoopctlE2e.McpTest: newline-delimited JSON-RPC 2.0.
// `initialize` answers; `tools/call` echoes its arguments and the env it was started with,
// except tool "fail" (isError) and tool "hang" (never answers). A non-JSON line and a
// notification are written first, which the client must skip.
import readline from "node:readline";

process.stdout.write("not json at all\n");
process.stdout.write(JSON.stringify({ jsonrpc: "2.0", method: "notifications/message" }) + "\n");

const rl = readline.createInterface({ input: process.stdin });

rl.on("line", (line) => {
  const msg = JSON.parse(line);
  if (msg.id === undefined) return;

  const reply = (result) =>
    process.stdout.write(JSON.stringify({ jsonrpc: "2.0", id: msg.id, result }) + "\n");

  if (msg.method === "initialize") return reply({ protocolVersion: "2025-06-18", capabilities: {} });

  const { name, arguments: args } = msg.params;
  if (name === "hang") return;

  const body = {
    args,
    cwd: process.cwd(),
    session: process.env.CLAUDE_SESSION_ID ?? null,
    home: process.env.HOME ?? null,
  };

  reply({
    content: [{ type: "text", text: JSON.stringify(name === "fail" ? { error: true, body } : body) }],
    ...(name === "fail" && { isError: true }),
  });
});

rl.on("close", () => process.exit(0));
