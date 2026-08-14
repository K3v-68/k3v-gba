#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RBF="$PROJECT_DIR/src/fpga/build/output_files/ap_core.rbf"
RBF_R="$PROJECT_DIR/pkg/Cores/K3V.GBA/bitstream.rbf_r"
BUILD_LOG="$PROJECT_DIR/build_output/quartus-build.log"
RESOURCE_JSON="$PROJECT_DIR/build_output/resource-usage.json"
RESOURCE_MARKDOWN="$PROJECT_DIR/build_output/resource-usage.md"
QUARTUS_IMAGE="${QUARTUS_IMAGE:-raetro/quartus@sha256:817a783727492269d33aa98c903e8efc216e95d785ee76bfc8f426eddee98d0b}"
BUILD_BACKEND="${BUILD_BACKEND:-docker}"
QUARTUS_SH="${QUARTUS_SH:-quartus_sh}"

mkdir -p "$PROJECT_DIR/build_output"

# Do not allow an aborted build to leave a stale image or resource report current.
rm -f -- "$RBF" "$RBF_R" "$RESOURCE_JSON" "$RESOURCE_MARKDOWN"

if [[ -n "${PYTHON:-}" ]]; then
  PYTHON_CMD="$PYTHON"
elif command -v python3 >/dev/null 2>&1; then
  PYTHON_CMD=python3
elif command -v python >/dev/null 2>&1; then
  PYTHON_CMD=python
else
  echo "Python 3 is required to reverse and package the bitstream." >&2
  exit 1
fi

echo "=== Starting Quartus build ($BUILD_BACKEND) ==="
case "$BUILD_BACKEND" in
  docker)
    if ! docker run --rm --platform linux/amd64 \
      --mount "type=bind,src=$PROJECT_DIR,dst=/build" \
      --env K3V_PROJECT_ROOT=/build \
      -w /build \
      "$QUARTUS_IMAGE" \
      quartus_sh -t generate.tcl 2>&1 | tee "$BUILD_LOG"; then
      echo "Quartus Docker build failed. See $BUILD_LOG" >&2
      exit 1
    fi
    ;;
  native)
    QUARTUS_VERSION="$($QUARTUS_SH --version 2>&1)"
    if [[ "$QUARTUS_VERSION" != *"Version 21.1.1 Build 850"* ]]; then
      echo "This release requires Quartus 21.1.1 Build 850; found:" >&2
      echo "$QUARTUS_VERSION" >&2
      exit 1
    fi
    echo "$QUARTUS_VERSION"
    if ! (cd "$PROJECT_DIR" && K3V_PROJECT_ROOT="$PROJECT_DIR" "$QUARTUS_SH" -t generate.tcl) 2>&1 | tee "$BUILD_LOG"; then
      echo "Native Quartus build failed. Set QUARTUS_SH to the Quartus 21.1.1 executable if needed." >&2
      exit 1
    fi
    ;;
  *)
    echo "Unknown BUILD_BACKEND '$BUILD_BACKEND'; expected docker or native." >&2
    exit 2
    ;;
esac

if [[ ! -s "$RBF" ]]; then
  echo "Quartus completed without producing $RBF" >&2
  exit 1
fi

echo ""
echo "=== Enforcing FPGA resource budget ==="
if ! "$PYTHON_CMD" "$SCRIPT_DIR/check_quartus_resources.py" \
    --summary "$PROJECT_DIR/src/fpga/build/output_files/ap_core.fit.summary" \
    --qsf "$PROJECT_DIR/src/fpga/build/ap_core.qsf" \
    --json-out "$PROJECT_DIR/build_output/resource-usage.json" \
    --markdown-out "$PROJECT_DIR/build_output/resource-usage.md"; then
  rm -f -- "$RBF" "$RBF_R"
  echo "Quartus resource budget failed; release images removed." >&2
  exit 1
fi

echo ""
echo "=== Enforcing release timing/report gates ==="
if ! "$SCRIPT_DIR/print_timing.sh" \
    "$PROJECT_DIR/src/fpga/build/output_files/ap_core.sta.summary" \
    "$PROJECT_DIR/build_output/reports/ap_core.sta.clock_summary.rpt"; then
  rm -f -- "$RBF" "$RBF_R"
  echo "Quartus timing did not close; release images removed." >&2
  exit 1
fi
if grep -Eq '^[[:space:]]*Critical Warning' "$BUILD_LOG"; then
  rm -f -- "$RBF" "$RBF_R"
  echo "Quartus emitted a critical warning; release images removed." >&2
  exit 1
fi
for report in \
  ap_core.sta.paths_setup.rpt \
  ap_core.sta.paths_setup_current_0c.rpt \
  ap_core.sta.paths_hold.rpt \
  ap_core.sta.clock_summary.rpt \
  ap_core.sta.sdram_write.rpt \
  ap_core.sta.sdram_read.rpt \
  ap_core.sta.cram0_output_setup.rpt \
  ap_core.sta.cram0_input_setup.rpt \
  ap_core.sta.cram0_output_hold.rpt \
  ap_core.sta.cram0_input_hold.rpt \
  ap_core.sta.sram_output_setup.rpt \
  ap_core.sta.sram_input_setup.rpt \
  ap_core.sta.sram_output_hold.rpt \
  ap_core.sta.sram_input_hold.rpt; do
  if [[ ! -s "$PROJECT_DIR/build_output/reports/$report" ]]; then
    rm -f -- "$RBF" "$RBF_R"
    echo "Required custom STA report missing or empty: $report" >&2
    exit 1
  fi
done

echo ""
echo "=== Build verified, reversing bitstream ==="
"$PYTHON_CMD" "$SCRIPT_DIR/reverse_bitstream.py" "$RBF" "$RBF_R"

if [[ "${PACKAGE_RELEASE:-1}" != "0" ]]; then
  echo ""
  echo "=== Creating deterministic release package ==="
  "$PYTHON_CMD" "$SCRIPT_DIR/package_release.py" \
    --output-dir "$PROJECT_DIR/dist" \
    --evidence "$BUILD_LOG"
fi

echo "=== Done! ==="
echo "Bitstream: $RBF_R"
echo "Build log: $BUILD_LOG"
