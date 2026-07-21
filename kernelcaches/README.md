# Kernelcache 文件目录

此目录存放预提取的 kernelcache，用于「无需 VPN」安装 TrollStore2。

## 文件格式说明（重要）

本目录中的 `kernelcache` 文件是 **LZFSE 压缩**格式（Apple 原生内核缓存压缩），
不是解压后的原始 Mach-O。其文件结构为：

```
bvx2 (4 字节魔数) + LZFSE 头 + LZFSE 压缩数据 + bvx$ (结束魔数)
```

安装器在 iOS 设备上使用系统 `compression_decode_buffer(COMPRESSION_LZFSE)`
**本机解码**，无需 VPN、无需额外工具。解码后校验 Mach-O 魔数，确保有效。

> 之所以存 LZFSE 而非原始文件：原始 kernelcache 约 100–1000 MB，而 LZFSE
> 仅约 17 MB，便于提交到 Git / GitHub raw 镜像，下载更快、更省流量。

## 文件命名规则

```
{model}/kernelcache          例如: iPhone14,2/kernelcache
{model_underscore}/kernelcache  例如: iPhone14_2/kernelcache
```

安装器会依次尝试 `{model}` 和 `{model_}` 两种路径（以及根目录），均失败再回退。

## 如何获取 kernelcache（LZFSE 格式）

从 Apple 官方 IPSW 提取（`extract_kernelcache_v2.py` + `carve.py`）：

1. `extract_kernelcache_v2.py` 通过 HTTP Range 从 IPSW 下载 DEFLATE 压缩的
   kernelcache 条目（ZIP64 解析）；
2. `carve.py` 对 DEFLATE 输出做 zlib 解压，取出其中 IM4P payload 里的
   `bvx2…bvx$` LZFSE 缓冲，保存为本目录的 `kernelcache`。

以上两步已在本地（Windows）完成 iPhone14,2 / 16.5.1 / 20F75 的提取。

## 支持的设备 + 版本组合

| 设备型号 | iOS 版本 | Build | 状态 |
|---------|---------|-------|------|
| iPhone14,2 | 16.5.1 | 20F75 | ✅ 已内置（LZFSE，安装器本机解码，完全离线） |

> 如需支持其它设备，请按上述方法提取对应 LZFSE 文件并提交到对应子目录，
> 安装器会自动尝试下载并解码。
