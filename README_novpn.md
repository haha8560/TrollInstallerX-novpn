# TrollInstallerX — 无需 VPN 版（fork）

在官方 [alfiecg24/TrollInstallerX](https://github.com/alfiecg24/TrollInstallerX) 基础上改造，
目标是：**无需 VPN 即可安装 TrollStore2（iOS 14.0–16.6.1 受支持）；通过内嵌各设备内核缓存，
让 iOS 15 / 16 这类需要内核缓存的版本也能完全离线安装**。
改造思路参考了「果粉助手」的做法（它本质就是 TrollInstallerX 的改版）。

---

## 一、改了什么（相对官方）

| 项 | 官方行为 | 本 fork |
|----|----------|---------|
| TrollStore.tar | 运行时从 `github.com/opa334/TrollStore` 下载 | **已内置**（最新版，含 15.8.7 / 15.8.8 的 CoreTrust 数据） |
| 版本检查 `getUpdatedTrollStore` | 启动即访问 `api.github.com` | **已关闭**（`OFFLINE_MODE = true`，零 GitHub 依赖） |
| kernelcache 来源 `getKernel` | 仅本地 / Apple 服务器（国内被墙→需 VPN） | **多设备内嵌优先（100% 离线）+ 镜像/Apple 兜底**：每个设备/版本的内核缓存单独内嵌，运行时按型号+版本自动匹配；未命中再走镜像（可能失效）或 Apple 源 |
| 版本范围 | 14.0 – 16.6.1 | 不变（见下文：15.0–15.1 / 15.8.7–15.8.8 上游本就支持） |

> 关键结论：**官方代码早已支持 15.0–15.1 与 15.8.7–15.8.8**（`landa` 覆盖 14.0–16.6.1，
> `isSupported` 对这两段均为 `true`）。但有一个**版本无关的硬前提**：我们的 fork 走的是
> 官方默认的 **kfd(landa)** 漏洞，而 kfd 必须先用 `kernelcache` 文件算出内核偏移
> （见 `libkfd/info/dynamic_info.h` 里的 `kernelcache__static_base` 等字段）——**没有 kernelcache 就装不了**。
>
> **果粉助手为什么能“一键”**：它内置了另一个漏洞 **`darksword`**（二进制里 `krw_init_darksword`、
> `[darksword] kernel_base/slide` 等符号为证）。darksword 在运行时自己算出内核 base/slide，
> **根本不需要下载 kernelcache**，所以在 15.8.7–15.8.8 上即使镜像源失效也能离线装上。
> 我们的 fork 是纯 TrollInstallerX（kfd），**没有 darksword 源码、也无法编译移植**，
> 所以 15.8.7–15.8.8 装不上的根因就是：**kfd 需要的 kernelcache 下载失败（镜像域名已死）**。
>
> 因此本 fork 对 15.8.7–15.8.8 的修复思路 = **把对应设备的 kernelcache 内嵌/提供好**，让 kfd 离线拿到它。
> TrollStore.tar 早已内置（含 15.8.7/15.8.8 的 CoreTrust 数据），不是问题。

---

## 二、两种「无需 VPN」策略

### 策略 A：运行时镜像下载（默认，开箱即用，像果粉助手）
- `TrollInstallerX/Installer/Installation.swift` 中 `KernelcacheSource.mirrors` 首选 =
  `https://kcache.js.appstore_k8x2mP9umo2.top`（**从果粉助手二进制里还原出的真实镜像域名**；
  之前误还原为已失效的 `kcache.js.appstore.top`，已修正）。
- 还会依次尝试 GitHub Releases / raw 作为兜底；`downloadKernelcacheFromAnyMirror` 自动尝试多种
  路径模板（`<base>/<model>/kernelcache`、`/<model>_<build>/`、`/<build>/` 等）提高命中率。
- **无需为每种机型单独准备文件**，一个 IPA 覆盖所有机型/版本——前提是镜像源当时可达。
- ⚠️ 该镜像为国内 CDN，作者在 Windows 环境下无法联网验证其当前是否仍可用；
  请在设备上实测。若镜像不可达会自动转策略 B/下面的兜底方案。

### 策略 B：构建期内嵌「多设备」kernelcache（100% 离线，零网络）— 推荐
- 每个设备/版本的内核缓存单独内嵌在 App 包里，运行时按 `型号 + iOS 版本` 自动匹配，
  **一台 IPA 即可离线安装多台设备**，完全不碰网络 / 镜像 / VPN。
- TrollStore.tar **早已内置**（从 v3 起就打进安装器），本方案只是把「缺的内核缓存」也补齐，
  从而让 iOS 15 / 16 这类需要内核缓存的版本也能离线装。
- 获取方式（本机联网 Apple CDN 即可，无需 VPN）：
  ```bash
  python3 tools/fetch_kernelcache_user.py --device iPhone8,1 --version 15.8.7 --build 19H384
  ```
  脚本会自动查 Apple 官方资产源并只抽取 kernelcache 片段，存入
  `kernelcaches/iPhone8,1_15.8.7/kernelcache`。`build.sh` 随后把它拷进 App 包。
- 想再加设备？再跑一次脚本换参数即可，目录互不干扰。

### iOS 15.8.7 / 15.8.8 专项（OTA-only，必须拿到 kernelcache 才能用 kfd 装）
- 这两个版本是 **OTA-only 安全更新，没有完整 restore IPSW**。新版 `fetch_kernelcache_user.py`
  会通过 AppleDB 自动改走 OTA 地址并抽取 kernelcache（已修好旧版“把 IPSW 里的 im4p 原样存盘、
  而非抽成 LZFSE”的 bug，抽出的文件 `getKernel` 才能直接解码）。
- 让 15.8.7–15.8.8 离线装好的**三种可靠办法（任选其一）**：
  1. **构建期内嵌（最稳，推荐）**：在能连 Apple 的机器上跑
     `python3 tools/fetch_kernelcache_user.py --device iPhone8,1 --version 15.8.7 --build 19H384`
     取下 kernelcache → 提交 → 推 GitHub 触发 Actions 编译 → 下载的 IPA 已内嵌，100% 离线。
     （`fetch_and_push.bat` 已自动做这一步。）
  2. **App 文档目录兜底（免重新编译）**：把 kernelcache 命名为 `kernelcache_iPhone8_1_15.8.7.lzfse`，
     用 Filza / iOS 文件 App 放进本安装器 App 的“文档”目录，再点安装。`getKernel` 会优先用它，完全离线。
  3. **一次性 VPN 缓存**：临时开 VPN 点一次安装 —— kernelcache 会缓存进本 App 文档
     （`getKernel` 下载到 `docsDir/kernelcache` 并持久化），之后关 VPN 再点即可离线安装。

> 为什么不能像果粉助手那样“永远不碰 kernelcache”？因为果粉助手用的是 **darksword**
> （运行时自算内核偏移），而本 fork 是官方 TrollInstallerX 的 **kfd**（必须读 kernelcache 文件）。
> 在没有 darksword 源码、也无法编译 iOS 漏洞的前提下，给 kfd 提供 kernelcache 是唯一可行的离线方案。

---

## 三、如何构建

> 编译 iOS app 必须有 **macOS + Xcode**。作者在 Windows 环境，无法在此直接产出 IPA。
> 以下两种方式二选一。

### 方式 1：GitHub Actions 云端编译（推荐，不需要自己的 Mac）
1. 确保仓库里已有所需设备的 kernelcache（见策略 B；`kernelcaches/` 目录）。
2. 在本机（能连 Apple CDN）一键完成「抓取 iPhone8,1 + 提交 + 推送」：
   ```bash
   fetch_and_push.bat        # Windows 双击运行；或手动执行里面的命令
   ```
   脚本会抓取 iPhone8,1/15.8.7 的 kernelcache，提交并推送到 GitHub，
   **自动触发 Actions 编译**。
3. 仓库 `Actions` 标签页等待 `Build TrollInstallerX (no-VPN)` 跑完，
   在 `Artifacts` 里下载 `TrollInstallerX.ipa`（已内嵌所有 kernelcache，离线可用）。
4. 想加更多设备：先 `python3 tools/fetch_kernelcache_user.py --device ... --version ... --build ...`，
   再 `git add -A && git commit -m "add xxx" && git push` 触发重新编译。

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
- 国内镜像域名 `kcache.js.appstore_k8x2mP9umo2.top` 来自对果粉助手二进制的静态还原（此前曾误还原为
  已失效的 `kcache.js.appstore.top`），其可用性、路径格式、长期稳定性**未经验证**，以你设备实测为准。
- 果粉助手“一键”靠的是内置漏洞 **darksword**（免 kernelcache）；本 fork 用 kfd，故 15.8.7–15.8.8
  必须提供 kernelcache（内嵌 / 文档目录 / 一次性 VPN 缓存三选一），这是当前架构下的必要前提。
- 仅用于学习与研究；使用后果自负。
