# Kernelcache 文件目录（v12 — 多设备离线内嵌）

> v12 核心变化：**一个 IPA 可内嵌多台设备/版本的内核缓存**，安装时按 `设备型号 + iOS 版本`
> 自动匹配，命中即 100% 离线安装，完全不需要 VPN / 镜像 / 网络。
> TrollStore.tar 早已内置（见 README_novpn.md），无需再处理。

## 下载策略（v12，按优先级）

1. **内嵌 kernelcache（按设备+版本匹配）** → 100% 离线，首选
2. MacDirtyCow 系统拷贝（iOS 15.0–15.7.1 / 16.0–16.1.2）
3. 镜像服务器（多源 + 重试 + 多路径模板；含已失效的 `kcache.js.appstore.top`）
4. Apple 官方源（`libgrabkernel2`，国内可能需 VPN）
5. 全部失败 → 显示清晰操作指引

## 目录布局

每个设备/版本单独一个子目录，目录名 = `<型号>_<iOS版本>`，里面放名为 `kernelcache` 的
LZFSE 压缩文件（magic `bvx2`，无扩展名）：

```
kernelcaches/
├── iPhone8,1_15.8.7/kernelcache     ← iPhone 6s, iOS 15.8.7 (build 19H384)
├── iPhone14,2_16.5.1/kernelcache    ← iPhone 13 Pro Max, iOS 16.5.1 (build 20F75)
└── ...（可继续添加任意设备/版本）
```

`build.sh` 会把这些文件拷进 App 包，命名为 `kernelcache_<型号U>_<版本>.lzfse`
（型号里的逗号替换为下划线，例如 `kernelcache_iPhone14_2_16.5.1.lzfse`）。
运行时 `getKernel()` 依据 `device.modelIdentifier` + `device.version` 自动选取，**多设备互不干扰**。

## 如何添加一台设备的离线 kernelcache

最简单：在本机（能连 Apple CDN，无需 VPN）运行：

```bash
python3 tools/fetch_kernelcache_user.py --device iPhone8,1 --version 15.8.7 --build 19H384
```

脚本会自动向 Apple 官方资产源 `gdmf.apple.com` 查询 IPSW 地址，并只下载其中的
kernelcache 片段，存入 `kernelcaches/iPhone8,1_15.8.7/kernelcache`。

- 不指定参数时默认抓取 **iPhone8,1 / 15.8.7 (19H384)**。
- 也可用 `--url <直接 .ipsw 链接>` 跳过查询。
- 若 Apple 资产源被墙，可手动用任意 TrollStore 安装器 / IPSW 提取 LZFSE kernelcache 放入对应目录。

添加后提交并触发构建，该设备即可离线安装。

> ⚠️ **版本必须完全匹配**：内嵌 kernelcache 的 iOS build 必须与设备**完全一致**，
> 否则 `build_physrw` 会内核 panic（黑屏重启）。目录名里的版本号请写准确。
