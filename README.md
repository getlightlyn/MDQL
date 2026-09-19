<p align="center">
  <img src="docs/icon.png" width="128" alt="MDQL">
</p>

<h1 align="center">MDQL</h1>

<p align="center">Markdown in Quick Look. Select a file, press Space, read it.</p>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

## Features

Headings, lists, tables, syntax highlighting, math, images, inline HTML, footnotes and emoji. Remote images and mermaid aren't supported yet.

Built on system APIs and TextKit, with as few outside dependencies as possible. That buys you:

-   **Fast**: **99.97%** of Markdown files render in under 100ms (measured on an M4 across 83,284 Markdown files found on one machine)
-   **Small**: **< 3 MB** on disk, and **86%** less memory than an HTML-based previewer
-   Dark mode that actually looks right

## Install

1. Grab the build for your chip from [Releases](https://github.com/getlightlyn/MDQL/releases)
   (`arm64` for Apple silicon, `x86_64` for Intel — the Apple menu → “About This Mac” tells you which), unzip it and drop it in Applications
2. **Open it once** — macOS only registers the preview extension after it has seen the app launch
3. Select any `.md` file in Finder and press Space

### macOS will block it the first time

The app isn't notarized yet, so double-clicking gets you "cannot be opened because the developer cannot be verified". You only have to allow it once:

1. Double-click MDQL.app and let it get blocked
2. Open **System Settings → Privacy & Security**, scroll down to "MDQL was blocked"
3. Click **Open Anyway**

Same thing from the command line:

```sh
xattr -d com.apple.quarantine /Applications/MDQL.app
```

### Nothing changed in Quick Look?

Another extension is probably claiming `.md` — macOS only ever picks one. Open **System Settings → General → Login Items & Extensions → Quick Look** and make sure MDQL is the only Markdown preview checked.

To confirm it registered:

```sh
pluginkit -m -i com.lightlyn.MDQL.QLExtension
```

## Build it yourself

```sh
./build.sh release                    # your own architecture, lands in dist/MDQL.app
./build.sh release --arch x86_64      # a specific one
./build.sh release --universal        # both in one bundle
```

## License

MIT, see [LICENSE](LICENSE). Third-party assets and dependencies are listed in [NOTICE](NOTICE).

Issues about rendering are welcome. Pull requests are welcome for the extension itself, the build scripts and the docs — the renderer under `Sources/MDQLPreview/Render/` is a read-only copy synced from upstream, so please open an issue for those instead.
