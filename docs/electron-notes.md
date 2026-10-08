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

## PixiJS draws nothing under the renderer's Content Security Policy

PixiJS v8 generates shader and uniform code with `new Function`. The electron-vite skeleton's
`index.html` carries `script-src 'self'` without `'unsafe-eval'`, so `Application.init()`
rejects with:

```
Error: Current environment does not allow unsafe-eval, please use pixi.js/unsafe-eval module to enable support.
```

The symptom is a blank stage with the app otherwise working; the error is only in the
renderer console. The fix keeps the CSP and loads PixiJS's eval-free code paths once, before
any other `pixi.js` import:

```ts
import 'pixi.js/unsafe-eval';
import { Application } from 'pixi.js';
```

The import path contains the word "eval", so a source scan for `eval(` or `new Function`
must not match bare words; and a comment must not spell out "new Function" either.

**For specs:** when the stack is PixiJS inside Electron, name this import in the Constraints
section next to the dependency list.

## Reading the renderer console from a terminal

Running the built app as `node_modules\electron\dist\electron.exe . --enable-logging=stderr`
prints renderer `console.*` output on stderr as `CONSOLE` lines, so a headless check can catch
renderer-side errors without DevTools. Remove `ELECTRON_RUN_AS_NODE` from the environment
first (see below) or the binary runs as plain Node.

## `npx electron --version` prints a Node version inside VS Code

VS Code sets `ELECTRON_RUN_AS_NODE=1` for its extension host, and Claude Code running in
the VS Code extension inherits it. Under that variable `electron.exe` behaves as plain Node,
so `electron --version` prints the bundled Node version (for example `v24.21.0`) instead of
`v44.7.0`. It still proves the binary runs. A normal terminal does not have the variable.
