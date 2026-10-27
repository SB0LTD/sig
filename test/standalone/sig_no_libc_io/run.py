"""Execute a compiled native I/O contract in its own disposable directory."""
import argparse
from pathlib import Path
import subprocess
import tempfile
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('binary',type=Path)
args=parser.parse_args()
binary=args.binary.resolve(strict=True)
with tempfile.TemporaryDirectory(prefix='sig-native-io-') as directory:
    subprocess.run([str(binary)],cwd=directory,check=True,timeout=30)
