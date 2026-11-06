#!/bin/bash
# 在 DDK 容器里用“原厂 config + 原厂 clang r596125”编译 Image。
# 只补 Droidspaces 必需的 6 项，其他保持原厂。
set -euxo pipefail

export PATH="/work/clang-stock/bin:$PATH"
echo "==> clang: $(clang --version | head -n1)"
clang --version | grep -q 'r596125' || {
  echo "::error::当前 clang 不是原厂 r596125，拒绝继续（避免 KCFI 不匹配）"
  exit 1
}

export ARCH=arm64
export LLVM=1
export LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-

cd /work/kernel
mkdir -p out

if [ ! -s /work/build-config/stock.config ]; then
  echo "::error::/work/build-config/stock.config 不存在"
  exit 1
fi

cp /work/build-config/stock.config out/.config
cp out/.config out/.config.stock
echo "==> baseline config: $(grep -c '^CONFIG_' out/.config) lines"

REQUIRED="SYSVIPC POSIX_MQUEUE IPC_NS PID_NS DEVTMPFS NETFILTER_XT_MATCH_ADDRTYPE"

enable_opt() {
  opt=$1
  if grep -q "^CONFIG_${opt}=y$" out/.config; then
    echo "  [keep]    $opt 已经是 y"
  elif grep -q "^CONFIG_${opt}=m$" out/.config; then
    echo "  [promote] $opt 由 m 改为 y"
    scripts/config --file out/.config -e "$opt"
  else
    echo "  [add]     $opt"
    scripts/config --file out/.config -e "$opt"
  fi
}

echo "==> 只补充 Droidspaces 必需项"
for o in $REQUIRED; do enable_opt "$o"; done

make O=out olddefconfig

echo "==> 断言：必须为 y"
fail=0
for o in $REQUIRED; do
  if grep -q "^CONFIG_${o}=y$" out/.config; then
    echo "  [ok]   $o"
  else
    echo "  [FAIL] $o 未开启"
    fail=1
  fi
done
test "$fail" = "0"

echo "==> 断言：会破坏 kABI 的选项必须保持关闭"
for o in CFS_BANDWIDTH CGROUP_PIDS NF_TABLES NET_L3_MASTER_DEV USER_NS; do
  if grep -q "^CONFIG_${o}=y$" out/.config; then
    echo "  [FAIL] $o 不应该开启"
    fail=1
  else
    echo "  [ok]   $o 未开启"
  fi
done
test "$fail" = "0"

echo "==> 断言：原厂 OPLUS/DTB 选项不能被改动"
for o in OPLUS_DEVICE_DTBS HUMMER_DTB; do
  b=$(grep -E "^(# )?CONFIG_${o}(=| is not set)" out/.config.stock | head -n1 || true)
  a=$(grep -E "^(# )?CONFIG_${o}(=| is not set)" out/.config | head -n1 || true)
  [ -z "$b" ] && b="(absent)"
  [ -z "$a" ] && a="(absent)"
  echo "  $o: $b -> $a"
  if [ "$b" != "(absent)" ] && [ "$b" != "$a" ]; then
    echo "  [FAIL] $o 被改变了"
    fail=1
  fi
done
test "$fail" = "0"

echo "==> 配置变化（原厂 -> 最终）"
{
  for o in $REQUIRED; do
    b=$(grep -E "^(# )?CONFIG_${o}(=| is not set)" out/.config.stock | head -n1 || true)
    a=$(grep -E "^(# )?CONFIG_${o}(=| is not set)" out/.config | head -n1 || true)
    [ -z "$b" ] && b="(absent)"
    [ -z "$a" ] && a="(absent)"
    echo "$o | $b | $a"
  done
} | tee out/config.report.txt
diff -u out/.config.stock out/.config > out/config.diff || true
changed=$(grep -cE "^[+-]CONFIG_|^[+-]# CONFIG_" out/config.diff || true)
echo "changed config lines: $changed"

echo "==> building Image"
ccache_arg=()
if command -v ccache >/dev/null 2>&1; then
  echo "    ccache: $(ccache --version | head -n1)"
  ccache_arg=(CC="ccache clang")
else
  echo "    ccache 不可用，使用普通 clang"
fi
make O=out -j"$(nproc)" KERNELRELEASE="$KERNELRELEASE" "${ccache_arg[@]}" Image

echo "==> 校验 vermagic"
test "$(make -s O=out KERNELRELEASE="$KERNELRELEASE" kernelrelease)" = "$KERNELRELEASE"
grep -q "$KERNELRELEASE" out/include/generated/utsrelease.h
grep -a -q "Linux version $KERNELRELEASE" out/arch/arm64/boot/Image

cp out/.config out/config.final
cp out/System.map out/System.map.final
ls -lh out/arch/arm64/boot/Image
