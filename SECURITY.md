# Security policy

Tandem is early software. It runs a small root helper and a local control socket, so security reports are welcome.

## Reporting a vulnerability

Please **do not open a public issue**. Use GitHub's private reporting: on the repository page choose
**Security > Report a vulnerability**. Include what you found, how to reproduce it, and the Tandem version
(Tandem > About). You should get an answer within about a week. Reports are credited unless you prefer otherwise.

## What is in scope

- The privileged helper (`TandemNetHelper`, runs as root): connection checks, the tools it launches, disk and USB handling.
- The control socket and the command-line/MCP server (`tandem`, `tandem mcp`).
- The file-sharing server between a VM and the Mac, and file drag and drop.
- The guest agent and the host–guest protocol (`protocol/PROTOCOL.md`).
- The update mechanism (signature checks, installation).

## Threat model and known limits

- **A VM is untrusted.** A guest should not be able to read or change Mac files that were not shared with it, or crash
  or control the host.
- **The AI-tools switch is a policy, not a sandbox.** "Allow AI tools (MCP) to control Tandem" (Settings > Advanced) controls
  what `tandem mcp` may do. Any program running as the same Mac user can still talk to the control socket and name itself
  `cli`; Tandem does not authenticate which program is calling. Do not treat the switch as protection against malicious
  software already running as you.
- **Shared folders follow links inside the share.** A link inside a shared folder that points elsewhere inside the share
  works; links that lead outside the share are refused.
- The Linux guest agent's self-update checks an FNV-1a checksum of the agent copy shipped inside the app, which guards
  against corruption, not against someone who can change the app.
- Early releases may not be notarised. Download releases only from this repository's releases page.

Only the latest release is supported.
