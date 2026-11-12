// Route `rm` in agent shells through rm-guard (rm.sh): recursive removal of
// repositories, the working directory, $HOME or top-level paths is refused
// on the expanded target. A PATH entry covers exec'd rm (xargs, find -exec);
// the exported function also survives PATH resets in child bash. User `!`
// commands are not changed. Not a sandbox: an absolute rm path bypasses it.
// Only the tools named below are patched: add any new shell-carrying tool here.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const bin = "@rmGuardBin@";
const pathEntry = `export PATH='${bin}':"$PATH"`;
// `export -f` is bash-only, so the function form is limited to bash tools.
const bashPrelude = [
  pathEntry,
  `rm() { '${bin}/rm' "$@"; }`,
  "export -f rm",
].join("\n");
const commandTools = new Set(["bash", "bash_bg", "monitor"]);
// `until` runs a shell condition under $SHELL, so only the PATH entry is safe.
const conditionTools = new Set(["until"]);

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", (event) => {
    const tool = event.toolName.toLowerCase();
    const input = event.input as { command?: unknown; condition?: unknown };
    if (
      commandTools.has(tool) &&
      typeof input.command === "string" &&
      !input.command.startsWith(bashPrelude)
    ) {
      input.command = `${bashPrelude}\n${input.command}`;
    }
    if (
      conditionTools.has(tool) &&
      typeof input.condition === "string" &&
      !input.condition.startsWith(pathEntry)
    ) {
      input.condition = `${pathEntry}\n${input.condition}`;
    }
  });
}
