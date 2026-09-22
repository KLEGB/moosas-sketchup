"""Build a self-contained SketchUp RBZ from downloaded Moosas sources.

The lightweight NSIS bootstrap downloads the source archives and the Python
embeddable distribution before invoking this script with their locations.
All generated files are confined to the selected output directory.
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

import tomllib


def copy_tree(source: Path, target: Path) -> None:
    if not source.is_dir():
        raise FileNotFoundError(source)
    shutil.copytree(source, target, ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".idea"))


def build_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PYTHONNOUSERSITE"] = "1"
    return env


def run(command: list[str], *, cwd: Path) -> None:
    logging.info("RUN %s", " ".join(command))
    subprocess.run(command, cwd=cwd, env=build_env(), check=True)


def install_dependencies(python_root: Path, sketchup_root: Path, moosas_root: Path) -> None:
    python_exe = python_root / "python.exe"
    setup_root = sketchup_root / "setup"
    run([str(python_exe), "--version"], cwd=python_root)
    run([str(python_exe), str(setup_root / "get-pip.py")], cwd=python_root)
    # pydot3k is an older source distribution and needs the legacy setuptools
    # build backend explicitly available under Python 3.12's embeddable runtime.
    run([str(python_exe), "-m", "pip", "install", "--no-cache-dir", "setuptools", "wheel"], cwd=python_root)
    for package in ("pydot==4.0.1", str(setup_root / "pydot3k-1.0.17.tar.gz"), str(setup_root / "db_eplusout_reader-0.3.1-py2.py3-none-any.whl")):
        run([str(python_exe), "-m", "pip", "install", "--no-cache-dir", package], cwd=python_root)
    project = tomllib.loads((moosas_root / "pyproject.toml").read_text(encoding="utf-8"))
    dependencies = project["project"].get("dependencies", [])
    if dependencies:
        run([str(python_exe), "-m", "pip", "install", "--no-cache-dir", *dependencies], cwd=python_root)


def write_rbz(staging_root: Path, output_rbz: Path) -> None:
    required = {"moosas-sketchup.rb", "moosas-sketchup/skp/MoosasMain.rb", "moosas-sketchup/python/python.exe", "moosas-sketchup/MoosasPy/__init__.py"}
    temporary_rbz = output_rbz.with_suffix(".rbz.tmp")
    with zipfile.ZipFile(temporary_rbz, "w", zipfile.ZIP_DEFLATED) as archive:
        for file_path in sorted(staging_root.rglob("*")):
            if file_path.is_file():
                archive.write(file_path, file_path.relative_to(staging_root).as_posix())
    with zipfile.ZipFile(temporary_rbz) as archive:
        missing = required - set(archive.namelist())
        if missing:
            raise RuntimeError(f"RBZ missing required entries: {sorted(missing)}")
    os.replace(temporary_rbz, output_rbz)
    logging.info("RBZ file count: %d", len(zipfile.ZipFile(output_rbz).namelist()))
    logging.info("RBZ size: %d bytes", output_rbz.stat().st_size)


def main() -> int:
    parser = argparse.ArgumentParser(description="Build the moosas-sketchup RBZ")
    parser.add_argument("--output-path", type=Path, required=True)
    parser.add_argument("--moosas-root", type=Path, required=True)
    parser.add_argument("--sketchup-root", type=Path, required=True)
    parser.add_argument("--python-root", type=Path, required=True)
    args = parser.parse_args()

    output_rbz, moosas_root = args.output_path.resolve(), args.moosas_root.resolve()
    sketchup_root, python_root = args.sketchup_root.resolve(), args.python_root.resolve()
    output_root = output_rbz.parent
    build_root = output_root / ".build"
    staging_root = build_root / "staging"
    plugin_root = staging_root / "moosas-sketchup"
    log_root = build_root / "logs"
    output_root.mkdir(parents=True, exist_ok=True)
    log_root.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", handlers=[logging.FileHandler(log_root / "build.log", encoding="utf-8"), logging.StreamHandler()])
    try:
        if staging_root.exists():
            shutil.rmtree(staging_root)
        install_dependencies(python_root, sketchup_root, moosas_root)
        copy_tree(python_root, plugin_root / "python")
        copy_tree(moosas_root / "MoosasPy", plugin_root / "MoosasPy")
        copy_tree(sketchup_root / "skp", plugin_root / "skp")
        (staging_root / "moosas-sketchup.rb").write_text('Sketchup::require "moosas-sketchup/skp/MoosasMain"\n', encoding="utf-8")
        write_rbz(staging_root, output_rbz)
        logging.info("BUILD SUCCESS")
        return 0
    except Exception:
        logging.exception("BUILD FAILED")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
