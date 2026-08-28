"""Put the template root on sys.path so `import lib.*` works under pytest."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
