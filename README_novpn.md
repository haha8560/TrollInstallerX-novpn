# TrollInstallerX — 无需 VPN 版（fork）

在官方 [alfiecg24/TrollInstallerX](https://github.com/alfiecg24/TrollInstallerX) 基础上改造，
目标是：**无需 VPN 即可安装 TrollStore2，并支持 iOS 15.0–15.1 与 iOS 15.8.7–15.8.8 一键安装**。
改造思路参考了「果粉助手」的做法（它本质就是 TrollInstallerX 的改版）。

---

## 一、改了什么（相对官方）

| 项 | 官方行为 | 本 fork |
|----|----------|---------|
| TrollStore.tar | 运行时从 `github.com/opa334/TrollStore` 下载 | **已内置**（最新版，含 15.8.7 / 15.8.8 的 CoreTrust 数据） |
| 版本检查 `getUpdatedTrollStore` | 启动即访问 `api.github.com` | **已关闭**（`OFFLINE_MODE = true`，零 GitHub 依赖） |
| kernelcache 来源 `getKernel` | 仅本地 / Apple 服务器（国内被墙→需 VPN） | **镜像优先 + 内嵌兜底**：可配置国内镜像 `KernelcacheSource.mirrorBaseURL`，优先用内嵌 `kernelcache`（完全离线） |
| 版本范围 | 14.0 – 16.6.1 | 不变（见下文：15.0–15.1 / 15.8.7–15.8.8 上游本就支持） |

> 关键结论：**官方代码早已支持 15.0–15.1 与 15.8.7–15.8.8**（漏洞 `landa` 覆盖 14.0–16.6.1，
> `isSupported` 对这两段均为 `true`）。果粉助手“新增”这两段，真正补的是：
> ① 更新的 TrollStore.tar（对应 CoreTrust 数据）；② 国内可直连的 kernelcache 镜像。
> 本 fork 用「内置最新 TrollStore.tar + 国内镜像/内嵌 kernelcache」复刻了这一点。

---

## 二、两种「无需 VPN」策略

### 策略 A：运行时镜像下载（默认，开箱即用，像果粉助手）
- `TrollInstallerX/Installer/Installation.swift` 中
  `KernelcacheSource.mirrorBaseURL` 默认 = `https://kcache.js.appstore.top`
  （该域名是从果粉助手二进制中还原出的国内镜像）。
- `downloadKernelcacheFromMirror` 会按顺序尝试多种路径模板
  （`<base>/<model>/kernelcache`、`/<model>_<build>/`、`/<build>/` 等），提高命中率。
- **无需为每种机型单独准备文件**，一个 IPA 覆盖所有机型/版本。
- ⚠️ 该镜像为国内 CDN，作者在 Windows 环境下无法联网验证路径是否正确；
  请你在设备上实测。若拿不到 kernelcache，把果粉助手日志里的真实 URL 发我，我据此修正模板。

### 策略 B：构建期内嵌 kernelcache（100% 离线，零网络）
- 用 `fetch_kernelcache.py` 获取对应机型的 kernelcache，放到 `Resources/kernelcache`（无扩展名）。
- `build.sh` 会把它拷进 `.app`；运行时 `getKernel()` 优先用内嵌文件，**完全不碰网络**。
- 适合只给自己/少数固定机型用。脚本为 best-effort（需 AppleDB + pyimg4 + lzfse 解压），
  如解压失败可改从任意可用 TrollStore 安装器的 bundle 里取现成 kernelcache。

---

## 三、如何构建

> 编译 iOS app 必须有 **macOS + Xcode**。作者在 Windows 环境，无法在此直接产出 IPA。
> 以下两种方式二选一。

### 方式 1：GitHub Actions 云端编译（推荐，不需要自己的 Mac）
1. 把这个仓库 fork 到你的 GitHub。
2. （可选）若要走策略 B，先运行 `fetch_kernelcache.py` 生成 `Resources/kernelcache` 并提交。
3. 在仓库 `Actions` 标签页手动运行 `Build TrollInstallerX (no-VPN)`。
4. 运行结束后在 `Artifacts` 里下载 `TrollInstallerX-novpn`（即 `TrollInstallerX.ipa`）。

### 方式 2：本地 Mac 编译
```bash
brew install ldid            # 可选；没有也能用系统 codesign 伪签
bash build.sh                # 产物 TrollInstallerX.ipa 在当前目录
```

---

## 四、如何安装到手机

TrollInstallerX 自身需要被安装到手机才能运行，使用**免费 Apple ID** 自签即可：

- **AltStore**（电脑端 AltServer + 手机端 AltStore）：把 IPA 丢进去安装，
  同一 Wi-Fi 下可自动 7 天续签；或手动重装。
- **Sideloadly**：直接连手机安装。
- ⚠️ 免费签名 **7 天有效期**，到期需重签（系统限制，任何工具都一样）。

安装后打开 App → 点 Install → 按提示完成 TrollStore2 安装。
iOS 15.0–15.1 / 15.8.7–15.8.8 均可走此流程。

---

## 五、重要声明 / 风险

- 作者**未在真机验证**（无 Mac / 无 iPhone / 无 VPN 环境），代码逻辑经静态分析确认，
  但最终能否在你的设备上成功安装，**需你实测**。
- 内核漏洞（kfd / dmaFail / MacDirtyCow）对机型与固件版本敏感，少数组合可能失败。
- 国内镜像域名 `kcache.js.appstore.top` 来自对果粉助手二进制的静态还原，
  其可用性、路径格式、长期稳定性**未经验证**，以你设备实测为准。
- 仅用于学习与研究；使用后果自负。
