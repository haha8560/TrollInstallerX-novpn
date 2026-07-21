# Kernelcache 文件目录

此目录用于存放预提取的 kernelcache 文件，实现 100% 离线安装。

## 文件命名规则

```
{model}/kernelcache          例如: iPhone14,2/kernelcache
{model_underscore}/kernelcache  例如: iPhone14_2/kernelcache
```

## 如何获取 kernelcache

1. 在有 VPN 的环境下运行一次 TrollInstallerX（官方版），成功安装后从应用的 Documents 目录获取已缓存的 `kernelcache` 文件
2. 或使用 `fetch_kernelcache.py` 脚本从 Apple IPSW 提取：
   ```bash
   python3 fetch_kernelcache.py --model iPhone14,2 --version 16.5.1 --build 20F75
   ```

## 当前状态

- 此目录当前为空——v5 IPA 需要联网下载 kernelcache
- 如果您有 VPN，首次运行会自动缓存到应用 Documents 目录
- 后续同一设备运行时直接使用缓存，无需再次下载

## 支持的设备+版本组合

| 设备型号 | iOS 版本 | Build | 状态 |
|---------|---------|-------|------|
| iPhone14,2 | 16.5.1 | 20F75 | ⏳ 待添加 |
