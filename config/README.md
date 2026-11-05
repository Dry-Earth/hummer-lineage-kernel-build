# config/hummer_config.gz

可选，但强烈建议放进来。

这是设备当前内核的 `/proc/config.gz`，用来当**基线 config**。有它时，
GitHub Actions 会直接用这份 config，只改 4 个选项，生成的 `.config` 和你正在跑的内核最接近。

## 怎么取

```bash
adb shell su -c "cp /proc/config.gz /sdcard/hummer_config.gz"
adb pull /sdcard/hummer_config.gz hummer-kernel-ci/config/hummer_config.gz
```

然后把这个文件提交到仓库（放到 `config/hummer_config.gz`）。

没有这个文件也能编：workflow 会退回成

```
gki_defconfig
+ arch/arm64/configs/vendor/sun_perf.config
+ arch/arm64/configs/vendor/oplus/sun_perf.config
```

这正是 LineageOS `BoardConfigCommon.mk` 里 `TARGET_KERNEL_CONFIG` 的顺序，通常也能对上。
