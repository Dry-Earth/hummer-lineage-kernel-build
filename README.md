# 一加 Ace 5 Pro（hummer）LineageOS 24.0 自编译内核 boot.img

目标：在 GitHub Actions 云端编译 **只含 `Image` 的 boot.img**，打开

- `CONFIG_PID_NS`
- `CONFIG_IPC_NS`
- `CONFIG_SYSVIPC`
- `CONFIG_POSIX_MQUEUE`

同时保持 kABI 和 `vermagic`，让 `vendor_dlkm` / `system_dlkm` 里的原厂模块继续加载。

## 构建结果 ✅

| 项目 | 值 |
|---|---|
| 机型 | OnePlus Ace 5 Pro / `hummer` |
| ROM | LineageOS 24.0（20261030） |
| 内核仓库 | `LineageOS/android_kernel_oneplus_sm8750` |
| 分支 | `lineage-24.0` |
| 精确 commit | `6350e8af3f4c452d087fbd6fe1aabe03cbc0af75` |
| modules 仓库 | `LineageOS/android_kernel_oneplus_sm8750-modules` @ `e05c031ce1512477f2d5db7bfa26a859adfcfbc7` |
| 目标 release / vermagic | `6.6.144-4k-g6350e8af3f4c` ✅ |
| 官方 boot.img | `mirrorbits.lineageos.org/full/hummer/20261030/boot.img` |
| 官方 boot sha256 | `826353bfa49cc58fbc04d71b1cf07bbbc58151049d7fbab73f3b77ac3a29938c` |
| 编译容器 | `ghcr.io/ylarod/ddk-min:android15-6.6-20260313`（clang r510928） |
| 配置基线 | 从官方 boot.img 提取的真实 `.config`（`config/hummer_config.gz`） |
| 成功 run | https://github.com/Dry-Earth/hummer-lineage-kernel-build/actions/runs/42061358728 |

**下载（Release 直链，不需要登录 Actions）：**

- 编译后的 boot（推荐，真实原厂 config 基线）：https://github.com/Dry-Earth/hummer-lineage-kernel-build/releases/download/boot-42061358728/new-boot.img
- 官方原版 boot（回滚用）：https://github.com/Dry-Earth/hummer-lineage-kernel-build/releases/download/boot-42061358728/stock-boot.img
- Release 页面：https://github.com/Dry-Earth/hummer-lineage-kernel-build/releases/tag/boot-42061358728

| 文件 | 大小 | sha256 |
|---|---|---|
| `new-boot.img` | 100663296 | `7f602e2165f4039ca4eed79f7201bf061fd2fe2dec14c8fd44fd89141c2dd8c0` |
| `stock-boot.img` | 100663296 | `826353bfa49cc58fbc04d71b1cf07bbbc58151049d7fbab73f3b77ac3a29938c` |

第一次构建（合并配置基线）的产物也保留着：
https://github.com/Dry-Earth/hummer-lineage-kernel-build/releases/tag/boot-42054473850

构建日志已确认：

```
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_IPC_NS=y
CONFIG_PID_NS=y
Linux version 6.6.144-4k-g6350e8af3f4c
```

## 目录内容

```
.github/workflows/build-hummer-boot.yml   # 云端编译流程
.github/workflows/extract-stock-config.yml # 从官方 boot.img 提取真实 config（无需设备）
.github/workflows/publish-boot.yml         # 把已有构建产物发成 Release（不重编）
patches/0001-sysvipc-kabi.patch            # Droidspaces 官方 kABI padding 补丁
config/hummer_config.gz                    # 从官方 boot.img 提取的真实内核配置
config/README.md                           # 配置说明
```

## 关键点

### 1. 为什么只编 Image

LineageOS 的 `vendor_dlkm` / `system_dlkm` 模块是预编译的，加载时会检查：

1. `vermagic`（内核 release + SMP/PREEMPT/MODVERSIONS 等）
2. 导出符号的 CRC（`CONFIG_MODVERSIONS=y`）

所以：

- `Image` 的 release 必须是 `6.6.144-4k-g6350e8af3f4c`
- `CONFIG_SYSVIPC` 会把 `sysvsem` / `sysvshm` 加进 `task_struct`，
  必须用 `patches/0001-sysvipc-kabi.patch` 把它们挪到末尾的 `ANDROID_KABI_RESERVE`
  槽位，否则所有后续字段偏移变化，厂商模块直接拒绝加载。

workflow 已经做了这两件事：

- 构建时强制 `KERNELRELEASE=6.6.144-4k-g6350e8af3f4c`（绕过 git dirty/SHA 影响）
- 先打 kABI 补丁，再打开 `SYSVIPC`

**不要**顺手打开 `CONFIG_CFS_BANDWIDTH` / `CONFIG_CGROUP_PIDS`。
这两个会改结构体大小，没有 padding 能救，必须全量重编所有 vendor 模块并刷多个分区。

### 2. 为什么必须同时检出 modules 仓库

内核源码里这些路径是**符号链接**，指向 `../../../../sm8750-modules/...`：

```
drivers/soc/oplus/{boot,device_info,dfr,dft,fpga_notify,mdmrst,multimedia,storage,trackpoint}
drivers/base/kernelFwUpdate
```

workflow 会把 modules 仓库检出到 `kernel` 的**同级目录** `sm8750-modules`，
再挂载到容器里的 `/sm8750-modules`，否则会出现：

```
drivers/base/Kconfig:245: can't open file "drivers/base/kernelFwUpdate/Kconfig"
make[6]: *** No rule to make target '../drivers/soc/oplus/boot/Makefile'
```

### 3. 配置来源

优先级：

1. `config/hummer_config.gz`（当前已通过“从原厂 boot.img 提取”生成并提交）——**推荐，当前使用**
2. 按 LineageOS `TARGET_KERNEL_CONFIG` 顺序合并：
   ```
   gki_defconfig
   + vendor/sun_perf.config
   + vendor/oplus/sun_perf.config
   ```
   然后只改上面 4 个选项。

#### 方法 A：从设备拉 `/proc/config.gz`

```bash
adb shell su -c "cp /proc/config.gz /sdcard/hummer_config.gz"
adb pull /sdcard/hummer_config.gz hummer-kernel-ci/config/hummer_config.gz
```

#### 方法 B：直接从 LineageOS 原厂 boot.img 提取（已实现，无需设备）

Actions → **Extract stock kernel config from LineageOS boot.img** → Run workflow。

它做的事情：

1. 下载官方 `boot.img` 并校验 sha256（`826353b...`）
2. 用 magiskboot 解包，取出里面的 `Image`
3. 用内核自带的 `scripts/extract-ikconfig` 提取内嵌的 `.config`
   （原厂内核 `CONFIG_IKCONFIG=y` / `IKCONFIG_PROC=y`，所以一定带配置）
4. 压缩成 `config/hummer_config.gz`，**自动提交回仓库**
5. 之后再跑 **Build hummer kernel boot.img**，就会自动以它为基线

本次已提取成功：2683 个 `CONFIG_*`，原厂 boot 里四个目标选项均为 `not set`，
与预期一致。

#### 仓库内缓存的原厂资源

为了避免 mirrorbits / USTC 对 runner IP 返回 403，官方 `boot.img` 和
`magiskboot` 也缓存到了 Release（内容与官方完全一致，已用 sha256 校验）：

- https://github.com/Dry-Earth/hummer-lineage-kernel-build/releases/download/test-assets/stock-boot.img
  （sha256 `826353bfa49cc58fbc04d71b1cf07bbbc58151049d7fbab73f3b77ac3a29938c`）
- https://github.com/Dry-Earth/hummer-lineage-kernel-build/releases/download/test-assets/libmagiskboot-x86_64.so
  （来自 Magisk v31.1）

workflow 会**优先**用仓库缓存，失败后再回退到 `mirrorbits` → USTC 官方镜像。

## 刷机

先确认设备已解锁 bootloader，并且 `adb` / `fastboot` 可用。

```bash
adb reboot bootloader
fastboot getvar current-slot
fastboot flash boot new-boot.img
fastboot reboot
```

`fastboot flash boot` 会自动刷当前 slot。

如果提示 AVB / verification 相关错误，再补一次（需要官方 `vbmeta.img`）：

```bash
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
```

## 刷完验证

```bash
adb shell su -c "uname -r"
# 期望：6.6.144-4k-g6350e8af3f4c

adb shell su -c "zcat /proc/config.gz | grep -E 'CONFIG_(PID_NS|IPC_NS|SYSVIPC|POSIX_MQUEUE)='"
# 期望四个都是 =y

adb shell su -c "ls -l /proc/self/ns"
# 应该能看到 pid / ipc 等 namespace

adb shell su -c "dmesg | grep -iE 'disagrees about version|Unknown symbol|module verification failed'"
# 没有输出最好；有的话先不要继续用
```

确认内核本身没问题后，再到 Magisk / KernelSU 管理器里**停用 phDroid 模块并重启**，
再跑：

```bash
adb shell su -c "droidspaces check"
```

如果全绿，就可以彻底不用 phDroid 了。
建议先停用、观察几天，再删除模块文件。

## 回滚

```bash
adb reboot bootloader
fastboot flash boot stock-boot.img
fastboot reboot
```

`stock-boot.img` 和 20261030 官方 boot 完全一致（sha256 已校验）。

## 以后重新构建

- GitHub 仓库 → **Actions** → **Build hummer kernel boot.img** → **Run workflow**
- 实际耗时约 **20 分钟**（4 核 runner）
- 成功后在该 run 的 **Artifacts** 下载，或者再跑一次
  **Publish built boot.img as release**（输入 run_id）生成 Release 直链。

OTA 注意：每次 LineageOS 更新，如果内核 SHA 变了，需要同步改
`KERNEL_SHA`、`STOCK_BOOT_URL`、`STOCK_BOOT_SHA256`、`MODULES_SHA` 再重新编；
不要拿旧内核配新系统。

## 排错

- `patch` 失败：内核源码和预期不一致，确认 `KERNEL_SHA`
- `grep CONFIG_...=y` 失败：看 `olddefconfig` 是否把某个选项关掉
- `can't open file .../kernelFwUpdate/Kconfig`：modules 仓库没检出或没挂载到 `/sm8750-modules`
- 下载 boot.img 403：换 `mirrorbits` / USTC 源，workflow 已内置双源 + sha256 校验
- 链接/OOM：把 workflow 里的 `-j$(nproc)` 改成 `-j2`
