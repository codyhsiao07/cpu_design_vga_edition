"""Save the build settings beside a profiling image for later result comparison."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ap = argparse.ArgumentParser(description=__doc__)
ap.add_argument('--mem', type=Path, required=True)
ap.add_argument('--source', required=True)
ap.add_argument('--flags', required=True)
ap.add_argument('--compiler', required=True)
ap.add_argument('--extra', default='')
args = ap.parse_args()
manifest = {
    'mem_sha256': hashlib.sha256(args.mem.read_bytes()).hexdigest(),
    'source': args.source, 'extra_sources': args.extra, 'cflags': args.flags,
    'startup': 'tools/perf_crt0.S',
    'compiler_version': subprocess.check_output([args.compiler, '--version'], text=True).splitlines()[0],
}
Path(str(args.mem) + '.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
