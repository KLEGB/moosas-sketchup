"""Keep adapter temporary files inside their replayable job directory."""
from contextlib import contextmanager
from pathlib import Path
import tempfile

@contextmanager
def workspace(directory):
    target = Path(directory).resolve() / 'tmp'
    target.mkdir(parents=True, exist_ok=True)
    previous = tempfile.tempdir
    tempfile.tempdir = str(target)
    try:
        yield
    finally:
        tempfile.tempdir = previous
