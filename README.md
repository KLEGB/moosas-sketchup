# moosas-sketchup

`moosas-sketchup` is a public, passive release repository for the Moosas SketchUp extension. Its release artifact is a small Windows bootstrap executable compiled from [`setup/toSketchUp.nsi`](setup/toSketchUp.nsi). The executable performs the RBZ build at run time; it does not embed source code, Python, or the setup directory.

## What the builder does

When `moosas-sketchup-builder.exe` is run, it:

1. downloads the current `main` branch of [KLEGB/moosas](https://github.com/KLEGB/moosas) for `MoosasPy`;
2. downloads the current `main` branch of this repository for `skp/` and `setup/`;
3. downloads the official 64-bit Python 3.12.10 embeddable distribution;
4. installs the Python dependencies declared by the Moosas project, assembles the Ruby code, `MoosasPy`, and the embedded Python runtime; and
5. writes the RBZ package to the folder and file name selected in the builder.

The builder uses GitHub source archives, so Git and a pre-installed Python runtime are not required. Internet access is required. The generated RBZ is built from the latest `main` branches at execution time; use a tagged release or commit-pinned builder if a reproducible build is required.

## Build the bootstrap executable

Compile `setup/toSketchUp.nsi` with NSIS. The resulting `dist/moosas-sketchup-builder.exe` is written to the `dist` directory. Because the NSIS definition contains only lightweight PowerShell bootstrap code, the EXE remains small.

The builder's settings page lets users select the export folder and RBZ file name. It also includes an optional local HTTP proxy switch; when enabled, the specified port is used at `127.0.0.1` for GitHub and package downloads.

On build failure, diagnostic files are retained in `<selected output folder>/.build/logs/`, including `build.log` and `bootstrap.log`. On success, the temporary `.build/` directory is removed and only the RBZ remains.

## Repository layout

- `setup/toSketchUp.nsi` — minimal NSIS bootstrap definition.
- `setup/build_rbz.py` — runtime packager downloaded with this repository.
- `skp/` — SketchUp Ruby extension source.
- `dist/moosas-sketchup.rbz` — generated extension package.

## License

This repository is available under the [MIT License](LICENSE).
