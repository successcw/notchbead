# Logos

Vendored icons used in the Coding Agent table (16×16) — nothing is loaded from
the network at runtime.

| File | Source | Licence |
| --- | --- | --- |
| `claude-code.svg` | [LobeHub icons](https://github.com/lobehub/lobe-icons) — `claudecode-color.svg` | MIT |
| `codex.svg` | [LobeHub icons](https://github.com/lobehub/lobe-icons) — `codex-color.svg` | MIT |
| `workbuddy.svg` | [LobeHub icons](https://github.com/lobehub/lobe-icons) — `workbuddy-color.svg` | MIT |
| `pi.svg` | Official favicon from [pi.dev](https://pi.dev) | per site/favicon usage |

`pi.svg` ships a `prefers-color-scheme` media query in its `<style>` block. The
dashboard is always dark, so that block was replaced with a fixed
`fill: #e6edf3` (the page `--text` colour); the three paths are unchanged.
The other three files are copied verbatim.
