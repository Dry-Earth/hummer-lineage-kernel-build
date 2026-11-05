# 一加 Ace 5 Pro（hummer）LineageOS 24.0 自编译内核 boot.img

目标：在 GitHub Actions 云端编译 **只含 `Image` 的 boot.img**，打开

- `CONFIG_PID_NS`
- `CONFIG_IPC_NS`
- `CONFIG_SYSVIPC`
- `CONFIG_POSIX_MQUEUE`

同时保持 kABI 和 `vermagic`，让 `vendor_dlkm` / `system_dlkm` 里的原厂模块继续加载。

编译参数对应你当前的内核：

| 项目 | 值 |
|---|---|
| 机型 | OnePlus Ace 5 Pro / `hummer` |
| ROM | LineageOS 24.0 |
| 内核仓库 | `LineageOS/android_kernel_oneplus_sm8750` |
| 分支 | `lineage-24.0` |
| 精确 commit | `6350e8af3f4c452d087fbd6fe1aabe03cbc0af75` |
| 目标 release | `6.6.144-4k-g6350e8af3f4c` |
| 官方 boot.img | `mirrors.ustc.edu.cn/lineageos/full/hummer/20261030/boot.img` |
| 编译容器 | `ghcr.io/ylarod/ddk-min:android15-6.6-20260313`（clang r510928） |

## 目录内容

```
.github/workflows/build-hummer-boot.yml   # 云端编译流程
patches/0001-sysvipc-kabi.patch           # Droidspaces 官方 kABI padding 补丁
config/README.md                          # 可选的 /proc/config.gz 说明
```

## 为什么只编 Image

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

## 用法

### 1. 建仓库

当前这台机器没有装 `git` / `gh`，所以需要你在网页上操作，或者先装 git。

**网页方式**

1. 在 GitHub 新建一个仓库，例如 `hummer-kernel-ci`（public / private 都行）。
2. 打开仓库页面 → **Add file → Upload files**。
3. 把这个 `hummer-kernel-ci` 目录里的内容拖进去：
   - `.github/workflows/build-hummer-boot.yml`
   - `patches/0001-sysvipc-kabi.patch`
   - `config/README.md`
   - `README.md`
4. Commit。

注意 `.github` 是隐藏目录，Windows 资源管理器里要开启“显示隐藏项目”，
或者直接把整个文件夹拖进浏览器上传。

**git 方式**

```bash
winget install --id Git.Git -e
cd hummer-kernel-ci
git init -b main
git add .
git commit -m "hummer kernel ci"
git remote add origin https://github.com/<你的用户名>/hummer-kernel-ci.git
git push -u origin main
```

### 2.（可选，强烈建议）放设备当前 config

```bash
adb shell su -c "cp /proc/config.gz /sdcard/hummer_config.gz"
adb pull /sdcard/hummer_config.gz hummer-kernel-ci/config/hummer_config.gz
```

把这个文件也提交。有它时 workflow 直接以**当前内核的真实 config** 为基线，
只改 4 个选项，最稳。

没有它也能编，workflow 会按 LineageOS 的顺序合并：

```
gki_defconfig
+ vendor/sun_perf.config
+ vendor/oplus/sun_perf.config
```

### 3. 运行

GitHub 仓库 → **Actions** → 左侧 **Build hummer kernel boot.img** → **Run workflow**。

大概需要 40–90 分钟（4 核 runner，KASAN + CFI 比较慢）。

成功后在该次 run 的 **Artifacts** 下载：

- `new-boot.img` ← 要刷的
- `stock-boot.img` ← 官方原版，回滚用
- `Image`、`config.final`、`System.map.final`、`build-info.txt`

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

`stock-boot.img` 就是仓库 artifact 里那份，和 20261030 官方 boot 完全一致。

## 注意事项

- **OTA 会覆盖 boot**：以后每次 LineageOS 更新，如果内核 SHA 变了，需要同步改
  `KERNEL_SHA` 和 `STOCK_BOOT_URL` 再重新编；不要拿旧内核配新系统。
- 第一次刷完如果卡开机，长按电源键强制重启进 fastboot，刷回 `stock-boot.img`。
- 这个方案只解决命名空间 + SysV IPC + POSIX mqueue；
  `--cpus` / `--pids-limit` 仍然不可用（需要 `CFS_BANDWIDTH` / `CGROUP_PIDS` 全量重编）。
- 构建失败先看日志里是哪一步：
  - `patch` 失败：说明内核源码和预期不一致，确认 `KERNEL_SHA`
  - `grep CONFIG_...=y` 失败：看 `olddefconfig` 是否把某个选项关掉
  - 链接/OOM：把 workflow 里的 `-j$(nproc)` 改成 `-j2`
