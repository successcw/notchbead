# NotchBead bridge

An Orca plugin that tells NotchBead when to look at Orca, so NotchBead doesn't start the Orca CLI
every 3 seconds to find out. See "Orca bridge" in `../README.md`.

`src/worker.ts` listens for `agent.status.changed` and `workspace.changed` (only moves to another
workspace count, not terminals opening, closing or being renamed). On each it posts the Darwin
notification `com.notchbead.orca.changed` with `/usr/bin/notifyutil` and touches
`~/Library/Application Support/NotchBead/orca-bridge-seen`. It sends nothing about the agents.

```sh
orca plugin validate .
orca plugin test .
npx -p typescript tsc -p . --noEmit
orca plugin dev load .     # then again with --approve <fingerprint>
```
