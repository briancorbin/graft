![Graft](https://raw.githubusercontent.com/briancorbin/graft/main/Assets/header-dark.png)

# Graft for VS Code

Editor support for **`.graft`** image recipes (and `Graftfile`) — the declarative recipes
behind [Graft](https://github.com/briancorbin/graft), which builds golden Tart VM images
for macOS & Linux dev environments and ephemeral CI runners.

- **Syntax highlighting** — graft keywords colored, and the bash inside `run: |` /
  `script: |` blocks highlighted as shell (the pretty part).
- **Completion + hover** — type a field and get the declarative keys (`node`, `ruby`,
  `brew`, `xcode-first-launch`, …) with docs on what each compiles to.
- **Snippets** — `graft`, `graft-rn`, `graft-ios` scaffold a recipe.
- **Commands** — `Graft: Render compiled provisioning script` (an eye icon in the editor
  title bar) and `Graft: Build image from this recipe`. Both shell out to the `graft`
  CLI on your PATH.
- **File icon** — `.graft` files get the Graft mark in icon themes that support language
  icons (e.g. Seti, the default).
- **JSON schema** — bundled at
  [`schemas/graft.schema.json`](https://github.com/briancorbin/graft/blob/main/editors/vscode/schemas/graft.schema.json).

## Install

From the Extensions view (`⇧⌘X`), search **Graft** and click Install — or:

```sh
code --install-extension briancorbin.dotgraft
```

**Build from source:** open `editors/vscode` in VS Code and press **F5** for an Extension
Development Host, or package a `.vsix` yourself:

```sh
cd editors/vscode
npx @vscode/vsce package
code --install-extension dotgraft-0.1.0.vsix
```

## Notes

- The render/build commands run `graft image render|build -f <file>`. Make sure `graft`
  (or a symlink to your dev build) is on the PATH the integrated terminal uses.
- No build step — the extension is plain JS + declarative contributions.
