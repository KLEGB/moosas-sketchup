"""Bundled-Python CLI: main_analysis.py /absolute/path/to/request.json."""
import contextlib
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
request = Path(sys.argv[1]).resolve()
with (request.parent / 'stdout.log').open('a', encoding='utf-8', buffering=1) as log:
    with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
        from skp.scripts.main_analysis import run_file
        run_file(request)
print(str(request.parent / 'result.json'))
