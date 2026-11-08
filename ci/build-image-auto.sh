#!/bin/bash
# Build either the stock baseline or the container-enabled Image in the DDK
# container.  All inputs come from the OTA manifest / boot.img; nothing is
# hard-coded to a kernel release.
set -euo pipefail

export PATH="/work/clang-stock/bin:$PATH"
echo "==> clang: $(clang --version | head -n1)"

KERNELRELEASE=${KERNELRELEASE:?KERNELRELEASE is required}
CONFIG_IN=${CONFIG_IN:-/work/build-config/stock.config}
OUT=${OUT:-/work/kernel/out}
MODE=${MODE:-new}
TARGETS=${TARGETS:-Image}
EXPECTED_CLANG=${EXPECTED_CLANG:-}
REQUIRED_OPTS=${REQUIRED_OPTS:-"SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS NETFILTER_XT_MATCH_ADDRTYPE"}
EXTRA_OPTS=${EXTRA_OPTS:-}
FORBIDDEN_OPTS=${FORBIDDEN_OPTS:-"USER_NS NF_TABLES NET_L3_MASTER_DEV CGROUP_PIDS CFS_BANDWIDTH"}

if [ -n "$EXPECTED_CLANG" ]; then
	clang --version | grep -q "$EXPECTED_CLANG" || {
		echo "::error::clang is not the expected $EXPECTED_CLANG"
		exit 1
	}
fi

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

cd /work/kernel
test -s "$CONFIG_IN" || { echo "::error::missing $CONFIG_IN"; exit 1; }
mkdir -p "$OUT"
cp "$CONFIG_IN" "$OUT/.config"
cp "$OUT/.config" "$OUT/.config.stock"
echo "==> baseline config: $(grep -c '^CONFIG_' "$OUT/.config") lines"

enable_opt() {
	opt=$1
	if grep -q "^CONFIG_${opt}=y$" "$OUT/.config"; then
		echo "  [keep]    $opt"
	elif grep -q "^CONFIG_${opt}=m$" "$OUT/.config"; then
		echo "  [promote] $opt m -> y"
		scripts/config --file "$OUT/.config" -e "$opt"
	else
		echo "  [add]     $opt"
		scripts/config --file "$OUT/.config" -e "$opt"
	fi
}

if [ "$MODE" = new ]; then
	echo "==> enabling container options"
	for o in $REQUIRED_OPTS $EXTRA_OPTS; do enable_opt "$o"; done
fi

make O="$OUT" olddefconfig

fail=0
if [ "$MODE" = new ]; then
	echo "==> required options"
	for o in $REQUIRED_OPTS; do
		if grep -q "^CONFIG_${o}=y$" "$OUT/.config"; then
			echo "  [ok]   $o"
		else
			echo "  [FAIL] $o is not y"
			fail=1
		fi
	done
	echo "==> forbidden options"
	for o in $FORBIDDEN_OPTS; do
		if grep -q "^CONFIG_${o}=y$" "$OUT/.config"; then
			echo "  [FAIL] $o must stay off"
			fail=1
		else
			echo "  [ok]   $o off"
		fi
	done
	# EXTRA_OPTS are best-effort: report ones olddefconfig dropped.
	for o in $EXTRA_OPTS; do
		grep -q "^CONFIG_${o}=y$" "$OUT/.config" || echo "  [warn] $o not enabled (dependency?)"
	done
fi
test "$fail" = "0"

echo "==> building: $TARGETS (MODE=$MODE)"
ccache_arg=()
if command -v ccache >/dev/null 2>&1; then
	ccache_arg=(CC="ccache clang")
fi
make O="$OUT" -j"$(nproc)" KERNELRELEASE="$KERNELRELEASE" "${ccache_arg[@]}" $TARGETS

test "$(make -s O="$OUT" KERNELRELEASE="$KERNELRELEASE" kernelrelease)" = "$KERNELRELEASE"
if [ -e "$OUT/arch/arm64/boot/Image" ]; then
	grep -a -q "Linux version $KERNELRELEASE" "$OUT/arch/arm64/boot/Image"
fi
cp "$OUT/.config" "$OUT/config.final"
cp "$OUT/System.map" "$OUT/System.map.final" 2>/dev/null || true
echo "==> build outputs"
ls -lh "$OUT/vmlinux" "$OUT/arch/arm64/boot/Image" 2>/dev/null || true
