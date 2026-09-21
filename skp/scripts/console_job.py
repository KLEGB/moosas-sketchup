"""Run a conversion in its own visible Windows console; retain exit status/log."""
import ctypes
import os
import subprocess
import sys

def install_log(filename):
    if os.name == 'nt':
        ctypes.windll.kernel32.SetConsoleOutputCP(65001)
        ctypes.windll.kernel32.SetConsoleTitleW('Moosas conversion progress')
        console = open('CONOUT$', 'w', encoding='utf-8', buffering=1)
    else:
        console = sys.stdout
    log = open(filename, 'a', encoding='utf-8', buffering=1)
    class Tee:
        encoding = 'utf-8'
        def write(self, value):
            log.write(value); log.flush()
            console.write(value); console.flush()
            return len(value)
        def flush(self):
            log.flush(); console.flush()
        def isatty(self):
            return False
    sys.stdout = sys.stderr = Tee()

if __name__ == '__main__':
    script = os.path.abspath(sys.argv[1])
    child = subprocess.Popen([sys.executable, '-u', script], cwd=os.path.dirname(script),
                             creationflags=subprocess.CREATE_NEW_CONSOLE if os.name == 'nt' else 0)
    raise SystemExit(child.wait())
