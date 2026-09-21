"""Build an isolated SketchUp RBZ from the MoosasPy source tree.

The repository is input-only.  Temporary Python, staging, downloads and logs
are kept below ``dist/.build``; a successful build leaves only ``dist/moosas-sketchup.rbz``.
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import os
import platform
import re
import shutil
import subprocess
import sys
try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None
import urllib.request
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DIST_ROOT = REPO_ROOT / "dist"
BUILD_ROOT = DIST_ROOT / ".build"
BOOTSTRAP_ROOT = BUILD_ROOT / "bootstrap"
PYTHON_ROOT = BUILD_ROOT / "python"
STAGING_ROOT = BUILD_ROOT / "staging"
TEMP_ROOT = BUILD_ROOT / "temp"
LOG_ROOT = BUILD_ROOT / "logs"
PLUGIN_ROOT = STAGING_ROOT / "moosas-sketchup"
OUTPUT_RBZ = DIST_ROOT / "moosas-sketchup.rbz"
SETUP_ROOT = REPO_ROOT / "setup"

PYTHON_URLS = {
    "AMD64": "https://www.python.org/ftp/python/3.11.3/python-3.11.3-embed-amd64.zip",
    "i386": "https://www.python.org/ftp/python/3.11.3/python-3.11.3-embed-win32.zip",
    "aarch64": "https://www.python.org/ftp/python/3.11.3/python-3.11.3-embed-arm64.zip",
}


def safe_rmtree(path: Path) -> None:
    path = path.resolve()
    build_root = BUILD_ROOT.resolve()
    if path in {REPO_ROOT.resolve(), DIST_ROOT.resolve()}:
        raise RuntimeError(f"Refuse to delete protected directory: {path}")
    if path != build_root and build_root not in path.parents:
        raise RuntimeError(f"Unsafe deletion target: {path}")
    if path.exists():
        shutil.rmtree(path)


def copy_tree(source: Path, target: Path) -> None:
    if not source.is_dir():
        raise FileNotFoundError(source)
    shutil.copytree(
        source,
        target,
        ignore=shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".idea"),
    )


def run(command: list[str], *, cwd: Path | None = None) -> None:
    logging.info("RUN %s", " ".join(command))
    subprocess.run(command, cwd=cwd, env=build_env(), check=True)


def build_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PYTHONNOUSERSITE"] = "1"
    return env


def download_python() -> None:
    machine = platform.machine().upper()
    arch = "AMD64" if machine in {"AMD64", "X86_64", "AMD64T"} else machine
    url = PYTHON_URLS.get(arch, PYTHON_URLS["AMD64"])
    archive = TEMP_ROOT / "python.zip"
    logging.info("CPU architecture: %s", arch)
    logging.info("Python URL: %s", url)
    with urllib.request.urlopen(url, timeout=120) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(PYTHON_ROOT)
    archive.unlink()


def install_dependencies() -> None:
    python_exe = PYTHON_ROOT / "python.exe"
    run([str(python_exe), "--version"], cwd=PYTHON_ROOT)
    run([str(python_exe), str(BOOTSTRAP_ROOT / "get-pip.py")], cwd=PYTHON_ROOT)
    run([str(python_exe), "-m", "pip", "--version"], cwd=PYTHON_ROOT)

    local_packages = [
        "pydot==4.0.1",
        str(SETUP_ROOT / "pydot3k-1.0.17.tar.gz"),
        str(SETUP_ROOT / "db_eplusout_reader-0.3.1-py2.py3-none-any.whl"),
    ]
    for package in local_packages:
        run([str(python_exe), "-m", "pip", "install", "--no-cache-dir", package], cwd=PYTHON_ROOT)

    project_text = (REPO_ROOT / "pyproject.toml").read_text(encoding="utf-8")
    if tomllib is not None:
        dependencies = tomllib.loads(project_text)["project"].get("dependencies", [])
    else:
        match = re.search(r"dependencies\s*=\s*\[(.*?)\]", project_text, re.DOTALL)
        dependencies = re.findall(r'"([^\"]+)"', match.group(1)) if match else []
    run([str(python_exe), "-m", "pip", "install", "--no-cache-dir", *dependencies], cwd=PYTHON_ROOT)


def prepare_staging() -> None:
    copy_tree(PYTHON_ROOT, PLUGIN_ROOT / "python")
    copy_tree(REPO_ROOT / "MoosasPy", PLUGIN_ROOT / "MoosasPy")
    copy_tree(REPO_ROOT / "skp", PLUGIN_ROOT / "skp")
    (STAGING_ROOT / "moosas-sketchup.rb").write_text(
        'Sketchup::require "moosas-sketchup/skp/MoosasMain"\n', encoding="utf-8"
    )


def validate_runtime() -> None:
    python_exe = PLUGIN_ROOT / "python" / "python.exe"
    package_root = PLUGIN_ROOT
    code = f"import sys; sys.path.insert(0, {str(package_root)!r}); import MoosasPy; print(MoosasPy.__file__)"
    result = subprocess.run(
        [str(python_exe), "-c", code],
        cwd=package_root,
        env=build_env(),
        capture_output=True,
        text=True,
    )
    if result.stdout:
        logging.info("Runtime stdout: %s", result.stdout.strip())
    if result.stderr:
        logging.info("Runtime stderr: %s", result.stderr.strip())
    if result.returncode != 0:
        raise RuntimeError(f"Embedded Python runtime validation failed with exit code {result.returncode}")
    package_file = Path(result.stdout.strip()).resolve()
    if PLUGIN_ROOT.resolve() not in package_file.parents:
        raise RuntimeError(f"MoosasPy loaded outside staging: {package_file}")
    logging.info("MoosasPy import: %s", package_file)


def validate_and_write_rbz() -> None:
    required = {"moosas-sketchup.rb", "moosas-sketchup/skp/MoosasMain.rb", "moosas-sketchup/python/python.exe", "moosas-sketchup/MoosasPy/__init__.py"}
    temp_output = BUILD_ROOT / "moosas-sketchup.rbz.tmp"
    with zipfile.ZipFile(temp_output, "w", zipfile.ZIP_DEFLATED) as archive:
        for file_path in sorted(STAGING_ROOT.rglob("*")):
            if file_path.is_file():
                relative = file_path.relative_to(STAGING_ROOT).as_posix()
                if relative.startswith(("dist/", ".build/")) or ".." in Path(relative).parts:
                    raise RuntimeError(f"Unsafe ZIP entry: {relative}")
                archive.write(file_path, relative)
    with zipfile.ZipFile(temp_output) as archive:
        names = set(archive.namelist())
        missing = required - names
        if missing:
            raise RuntimeError(f"RBZ missing required entries: {sorted(missing)}")
    os.replace(temp_output, OUTPUT_RBZ)
    logging.info("RBZ file count: %d", len(zipfile.ZipFile(OUTPUT_RBZ).namelist()))
    logging.info("RBZ size: %d bytes", OUTPUT_RBZ.stat().st_size)


def build(*, clean: bool = True) -> None:
    DIST_ROOT.mkdir(exist_ok=True)
    if clean and BUILD_ROOT.exists():
        safe_rmtree(BUILD_ROOT)
    for directory in (BOOTSTRAP_ROOT, PYTHON_ROOT, STAGING_ROOT, TEMP_ROOT, LOG_ROOT):
        directory.mkdir(parents=True, exist_ok=True)

    logging.info("BUILD START")
    shutil.copy2(REPO_ROOT / "setup" / "get-pip.py", BOOTSTRAP_ROOT / "get-pip.py")
    download_python()
    shutil.copy2(SETUP_ROOT / "python311._pth", PYTHON_ROOT / "python311._pth")
    install_dependencies()
    prepare_staging()
    validate_runtime()
    validate_and_write_rbz()
    logging.info("BUILD SUCCESS")


def main() -> int:
    global REPO_ROOT, DIST_ROOT, BUILD_ROOT, BOOTSTRAP_ROOT, PYTHON_ROOT
    global STAGING_ROOT, TEMP_ROOT, LOG_ROOT, PLUGIN_ROOT, OUTPUT_RBZ, SETUP_ROOT
    parser = argparse.ArgumentParser(description="Build the isolated moosas-sketchup RBZ")
    parser.add_argument("--repo-root", type=Path, default=REPO_ROOT)
    parser.add_argument("--bootstrap-root", type=Path, default=None)
    args = parser.parse_args()
    REPO_ROOT = args.repo_root.resolve()
    DIST_ROOT = REPO_ROOT / "dist"
    BUILD_ROOT = DIST_ROOT / ".build"
    BOOTSTRAP_ROOT = BUILD_ROOT / "bootstrap"
    PYTHON_ROOT = BUILD_ROOT / "python"
    STAGING_ROOT = BUILD_ROOT / "staging"
    TEMP_ROOT = BUILD_ROOT / "temp"
    LOG_ROOT = BUILD_ROOT / "logs"
    PLUGIN_ROOT = STAGING_ROOT / "moosas-sketchup"
    OUTPUT_RBZ = DIST_ROOT / "moosas-sketchup.rbz"
    SETUP_ROOT = (args.bootstrap_root or (REPO_ROOT / "setup")).resolve()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        if BUILD_ROOT.exists():
            safe_rmtree(BUILD_ROOT)
        LOG_ROOT.mkdir(parents=True, exist_ok=True)
        file_handler = logging.FileHandler(LOG_ROOT / "build.log", encoding="utf-8")
        logging.getLogger().addHandler(file_handler)
        build(clean=False)
        file_handler.flush()
        file_handler.close()
        logging.getLogger().removeHandler(file_handler)
        safe_rmtree(BUILD_ROOT)
        return 0
    except Exception:
        logging.exception("BUILD FAILED")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
