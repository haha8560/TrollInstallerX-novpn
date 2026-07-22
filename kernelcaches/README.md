# Kernelcache 文件目录

> v11 更新：重新支持内嵌 kernelcache（可选），同时大幅改进网络下载逻辑。

## 下载策略（v11，按优先级）

安装器按以下顺序尝试获取 kernelcache：

1. **内嵌 LZFSE**（本目录有文件时自动启用）→ 100% 离线，无需网络
2. **MacDirtyCow 系统拷贝**（iOS 15.0–15.7.1 / 16.0–16.1.2）
3. **镜像服务器**（多源 + 重试 + 多路径模板）
   - `kcache.js.appstore.top`（果粉助手原镜像，可能已失效）
   - GitHub Releases（`releases/download/kernelcaches/`）
4. **AppleDB → Apple CDN**（`libgrabkernel2`，可能需要 VPN）
5. **全部失败** → 显示清晰的操作指引

## 如何添加内嵌 kernelcache

1. 获取对应设备+版本的 LZFSE 压缩 kernelcache
2. 放入 `{model}/kernelcache`，例如：
   ```
   kernelcaches/
   ├── iPhone8,1/kernelcache      ← iPhone 8 (任意 iOS 版本)
   ├── iPhone14,2/kernelcache     ← iPhone 13 Pro Max
   └── ...
   ```
3. 运行 `build.sh` 或 GitHub Actions 自动编译 → IPA 自动包含

> ⚠️ **版本匹配要求**：内嵌 kernelcache 的 iOS build 号必须与用户设备的**完全一致**。
> 不匹配会导致 `build_physrw` 内核 panic（黑屏重启）。详见下方「历史说明」。

## 镜像下载改进（v11）

- **超时时间**：120s → 180s
- **重试机制**：每个 URL 最多重试 2 次（间隔 3 秒）
- **路径模板**：每个镜像尝试 5 种路径格式
- **文件验证**：拒绝过小文件和 HTML 错误页面
- **HTTP 错误感知**：404/503 等不触发重试
- **GitHub Releases 支持**：可上传 kernelcaches 到 Release assets

## 历史说明（v6–v10 问题记录）

| 版本 | 方案 | 问题 |
|------|------|------|
| v6–v9 | 内嵌单一 kernelcache | build 不匹配 → 内核 panic 黑屏 |
| v10 | 纯网络下载 | kcache.js.appstore.top DNS 失效 → 全部超时 |
| v11 | 内嵌(可选) + 多源网络 + 重试 | 兼顾离线可靠性和网络灵活性 |
