#!/usr/bin/env bash
# Regenerate macOS AppIcon.appiconset PNGs from assets/MG-icon.png.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT}/assets/MG-icon.png"
OUT="${ROOT}/macos/Runner/Assets.xcassets/AppIcon.appiconset"

if [[ ! -f "${SRC}" ]]; then
  echo "Missing source icon: ${SRC}" >&2
  exit 1
fi

mkdir -p "${OUT}"

if command -v sips >/dev/null 2>&1; then
  for size in 16 32 64 128 256 512 1024; do
    sips -z "${size}" "${size}" "${SRC}" --out "${OUT}/app_icon_${size}.png" >/dev/null
    echo "wrote app_icon_${size}.png (${size}x${size})"
  done
  exit 0
fi

VENV="${ROOT}/.venv-icons"
if [[ ! -d "${VENV}" ]]; then
  uv venv "${VENV}"
  # shellcheck source=/dev/null
  source "${VENV}/bin/activate"
  uv pip install pillow
else
  # shellcheck source=/dev/null
  source "${VENV}/bin/activate"
fi

python3 - "${SRC}" "${OUT}" <<'PY'
import sys
from pathlib import Path
from PIL import Image

src, out_dir = Path(sys.argv[1]), Path(sys.argv[2])
master = Image.open(src).convert("RGBA")
for size in (16, 32, 64, 128, 256, 512, 1024):
    name = f"app_icon_{size}.png"
    master.resize((size, size), Image.Resampling.LANCZOS).save(
        out_dir / name, format="PNG", optimize=True
    )
    print(f"wrote {name} ({size}x{size})")
PY