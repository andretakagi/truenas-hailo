#!/usr/bin/env bash
# Verify that the PREINIT script embedded in scripts/install.sh (heredoc)
# matches scripts/hailo-preinit.sh. The standalone copy carries a 3-line
# header note ("This script is also embedded inline in install.sh...") that
# must NOT appear in the embedded copy — those lines are ignored when
# comparing.
#
# Run locally:
#   .github/scripts/check-preinit-sync.sh
# Exits non-zero with a unified diff if the two copies have drifted.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL_SH="${REPO_ROOT}/scripts/install.sh"
STANDALONE="${REPO_ROOT}/scripts/hailo-preinit.sh"

if [ ! -f "$INSTALL_SH" ]; then
  echo "::error title=preinit-sync::scripts/install.sh not found" >&2
  exit 1
fi
if [ ! -f "$STANDALONE" ]; then
  echo "::error title=preinit-sync::scripts/hailo-preinit.sh not found" >&2
  exit 1
fi

EMBEDDED=$(mktemp)
STANDALONE_NORM=$(mktemp)
trap 'rm -f "$EMBEDDED" "$STANDALONE_NORM"' EXIT

# Extract the heredoc body (between `cat > ... <<'PREINIT_EOF'` and the
# closing `PREINIT_EOF` line).
python3 - "$INSTALL_SH" > "$EMBEDDED" <<'PY'
import re, sys
with open(sys.argv[1]) as f:
    src = f.read()
m = re.search(r"cat > [^\n]* <<'PREINIT_EOF'\n(.*?)\nPREINIT_EOF\n", src, re.DOTALL)
if not m:
    sys.stderr.write("::error title=preinit-sync::could not locate PREINIT_EOF heredoc in install.sh\n")
    sys.exit(1)
sys.stdout.write(m.group(1) + "\n")
PY

# Strip the 3-line "embedded inline" note from the standalone before
# comparing. Anything else that diverges is a real drift.
python3 - "$STANDALONE" > "$STANDALONE_NORM" <<'PY'
import sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
out = []
skip = 0
for line in lines:
    if skip > 0:
        skip -= 1
        continue
    if line.rstrip() == "# NOTE: This script is also embedded inline in install.sh (heredoc).":
        # Drop this line, the next ("# Keep both copies in sync..."), and
        # the preceding blank-comment separator ("#") if we just emitted
        # one. The standalone uses a "#\n# NOTE:..." separator pattern.
        if out and out[-1].rstrip() == "#":
            out.pop()
        skip = 1
        continue
    out.append(line)
sys.stdout.writelines(out)
PY

if ! diff -u "$EMBEDDED" "$STANDALONE_NORM"; then
  echo "::error title=preinit-sync::scripts/install.sh embedded PREINIT heredoc has drifted from scripts/hailo-preinit.sh" >&2
  echo "Update one to match the other; the heredoc and the standalone script must be byte-equal modulo the 'embedded inline' header note." >&2
  exit 1
fi

echo "preinit-sync: scripts/install.sh heredoc matches scripts/hailo-preinit.sh"
