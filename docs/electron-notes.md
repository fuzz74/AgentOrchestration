# Electron notes

Reference notes for projects the orchestrator builds with Electron. Found while building
GhostRacer (October 2026, Electron 44.7, npm 11, Node 24).

## The binary is not downloaded by `npm ci`

Since Electron 44 the `electron` package has no `postinstall` hook. It ships a bin called
`install-electron` (its `install.js`) that downloads the binary into
`node_modules/electron/dist` and writes `path.txt`. A plain `npm ci` or `npm install`
therefore leaves the package without a binary, and `electron-vite dev` fails with:

```
error during start dev server and electron app:
Error: Electron uninstall
    at getElectronPath (.../node_modules/electron-vite/dist/chunks/lib-....js)
```

`electron-vite build`, `tsc` and `vitest` do not need the binary, so a skeleton's
whole-project check passes and the gap only shows up on `npm start`.

**Fix for a project:** add a project-level post-install step to `package.json`, which npm
still runs:

```json
"scripts": {
  "postinstall": "install-electron"
}
```

`install-electron` is idempotent: it exits at once when `dist/version` and `path.txt` already
match. One-off repair without the script: `node node_modules/electron/install.js` or
`npx install-electron` in the project folder.

**For specs:** when the stack is Electron, put the `postinstall` line in the Constraints
section next to the dependency list, so the skeleton has it from the start.

## `npx electron --version` prints a Node version inside VS Code

VS Code sets `ELECTRON_RUN_AS_NODE=1` for its extension host, and Claude Code running in
the VS Code extension inherits it. Under that variable `electron.exe` behaves as plain Node,
so `electron --version` prints the bundled Node version (for example `v24.21.0`) instead of
`v44.7.0`. It still proves the binary runs. A normal terminal does not have the variable.
