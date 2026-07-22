# Kernelcache 文件目录

> v10 更新：移除内嵌 kernelcache（IPA 从 26MB 降到 8MB，与果粉助手一致）。
> 改为**运行时动态下载**（首选国内镜像 `kcache.js.appstore.top`），首次需联网，
> 之后保存在应用沙盒 `Documents/kernelcache` 中完全离线。
> 这同时修复了 v6–v9 因内嵌 build 与用户实际 iOS build 不匹配而引发的
> `build_physrw` 内核 panic（黑屏重启）。

## 历史说明（v6–v9，仅供参考）

v6–v9 曾在此目录内置 iPhone14,2 / 16.5.1 / 20F75 的 LZFSE 压缩 kernelcache，
但遇到跨 build（甚至同 iOS 版本的微小 build 差异）时，`build_physrw_primitive()`
在 PPL 绕过后会因 PTE 物理地址假设失效而触发内核 panic。

修复后 v10 改为：

1. **首选镜像**：`https://kcache.js.appstore.top`（果粉助手同款，国内可直连，
   多路径模板自动尝试）
2. **GitHub raw 回退**：`https://raw.githubusercontent.com/haha8560/TrollInstallerX-novpn/main/kernelcaches`
3. **AppleDB / Apple 最后回退**（可能需要 VPN）：通过预编译的 `libgrabkernel2`
4. **手动放置**：将原始 kernelcache 复制到应用沙盒 `Documents/kernelcache`
   （不需 LZFSE，安装器会自动识别）

镜像下载失败时会清晰提示用户开启 VPN 一次或手动放置。

## 如何临时重新启用内嵌（高级用户）

如果网络完全不可用且你需要为特定 build 离线安装，可把对应 LZFSE 文件放回
`{model}/kernelcache`（如 `iPhone14,2/kernelcache`），并在 `build.sh` 中
重新打开内嵌段（已注释保留）。
