//
//  Installation.swift
//  TrollInstallerX
//
//  Created by Alfie on 22/03/2024.
//

import SwiftUI
import Compression

let fileManager = FileManager.default
let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
let docsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0].path
let kernelPath = docsDir + "/kernelcache"

/// No-VPN kernelcache source configuration.
/// Multiple mirrors are tried in order. If ALL mirrors fail AND Apple's servers
/// are unreachable (GFW), the app shows clear instructions.
///
/// Mirror URL path template: {base}/{model}/kernelcache or {base}/{model}_{build}/kernelcache
/// The downloader tries several common layouts automatically.
struct KernelcacheSource {
    /// Ordered list of mirror base URLs (tried first-to-last). `nil` entries skipped.
    static let mirrors: [String?] = [
        // GitHub raw - our own repo (most reliable in China)
        "https://raw.githubusercontent.com/haha8560/TrollInstallerX-novpn/main/kernelcaches",
        // GuoFen Assistant mirror (original, may or may not work)
        "https://kcache.js.appstore.top",
        // Community fallback mirrors (add more as needed)
        nil  // placeholder for future mirrors
    ]
    /// Timeout per download attempt in seconds (China network needs patience).
    static let downloadTimeoutSec: TimeInterval = 120
}


func checkForMDCUnsandbox() -> Bool {
    return fileManager.fileExists(atPath: docsDir + "/full_disk_access_sandbox_token.txt")
}

/// Decode an LZFSE-compressed kernelcache buffer (Apple's native LZFSE format,
/// magic `bvx2`…`bvx$`) using the system `compression` framework.
/// Returns the decoded raw Mach-O data, or nil on failure.
func decodeLZFSE(_ src: Data) -> Data? {
    // Growable output buffer. iOS kernelcaches decompress to ~100–1000 MB.
    var outSize = 384 * 1024 * 1024
    for _ in 0..<6 {
        var out = Data(count: outSize)
        let written = out.withUnsafeMutableBytes { obuf -> Int in
            src.withUnsafeBytes { ibuf -> Int in
                let sp = ibuf.bindMemory(to: UInt8.self).baseAddress!
                let dp = obuf.bindMemory(to: UInt8.self).baseAddress!
                return compression_decode_buffer(dp, outSize, sp, src.count, nil, COMPRESSION_LZFSE)
            }
        }
        if written > 0 && written < outSize {
            return out.subdata(in: 0..<written)
        } else if written == outSize {
            // Buffer may have been too small — grow and retry.
            outSize *= 2
            if outSize > 2_000_000_000 { return nil }
            continue
        }
        return nil
    }
    return nil
}

/// True if the first 4 bytes are a Mach-O magic.
func isMachO(_ d: Data) -> Bool {
    let m = d.prefix(4)
    return m.elementsEqual([UInt8(0xcf), 0xfa, 0xed, 0xfe])   // MH_MAGIC_64 (LE)
        || m.elementsEqual([UInt8(0xfe), 0xed, 0xfa, 0xcf])   // MH_MAGIC_64 (BE)
        || m.elementsEqual([UInt8(0xce), 0xfa, 0xed, 0xfe])   // MH_MAGIC (LE)
        || m.elementsEqual([UInt8(0xfe), 0xed, 0xfa, 0xce])   // MH_MAGIC (BE)
}

/// Ensure the file at `path` is a usable raw kernelcache Mach-O.
/// - If it is NOT LZFSE, it is assumed already raw and usable.
/// - If it IS LZFSE, it is decoded in place; the result must be a valid Mach-O.
/// Returns false only when the file looked like LZFSE but failed to decode.
func prepareKernelcache(_ path: String) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return false }
    let isLZFSE = data.count >= 4 && data.prefix(4).elementsEqual([UInt8(0x62), 0x76, 0x78, 0x32]) // "bvx2"
    guard isLZFSE else { return true }
    Logger.log("检测到 LZFSE 内核缓存，正在本机解码（无需VPN）", type: .success)
    guard let raw = decodeLZFSE(data) else {
        Logger.log("内核缓存 LZFSE 解码失败", type: .error)
        return false
    }
    guard raw.count > 4 && isMachO(raw) else {
        Logger.log("内核缓存解码结果无效（非 Mach-O）", type: .error)
        return false
    }
    try? raw.write(to: URL(fileURLWithPath: path))
    Logger.log("内核缓存 LZFSE 解码成功（离线可用）", type: .success)
    return true
}

func getKernel(_ device: Device) -> Bool {
    if !fileManager.fileExists(atPath: kernelPath) {
        // 1. Try embedded kernelcache (100% offline, no network needed).
        //    The LZFSE-compressed blob for this exact device is embedded so the
        //    install works fully offline (no VPN, no mirror). Decoded on-device.
        if device.modelIdentifier == "iPhone14,2" {
            if let embedded = Bundle.main.path(forResource: "kernelcache", ofType: "lzfse") {
                try? fileManager.copyItem(atPath: embedded, toPath: kernelPath)
            }
        }
        // (Legacy) raw embedded kernelcache
        if !fileManager.fileExists(atPath: kernelPath) {
            if let embedded = Bundle.main.path(forResource: "kernelcache", ofType: "") {
                try? fileManager.copyItem(atPath: embedded, toPath: kernelPath)
            }
        }
        // 2. Try MacDirtyCow unsandboxed system copy
        if !fileManager.fileExists(atPath: kernelPath) {
            if MacDirtyCow.supports(device) && checkForMDCUnsandbox() {
                let fd = open(docsDir + "/full_disk_access_sandbox_token.txt", O_RDONLY)
                if fd > 0 {
                    let tokenData = get_NSString_from_file(fd)
                    sandbox_extension_consume(tokenData)
                    Logger.log("正在复制内核缓存")
                    if let path = get_kernelcache_path() {
                        do {
                            try fileManager.copyItem(atPath: path, toPath: kernelPath)
                        } catch {
                            Logger.log("复制内核缓存失败", type: .error)
                            NSLog("Failed to copy kernelcache - \(error)")
                        }
                    }
                }
            }
        }
        // 3. Try all configured mirrors (China-accessible, no VPN needed)
        if !fileManager.fileExists(atPath: kernelPath) {
            if downloadKernelcacheFromAnyMirror(device, to: kernelPath) {
                Logger.log("已从镜像获取内核缓存", type: .success)
            }
        }
        // 4. Last resort: Apple's official servers (requires VPN in China)
        if !fileManager.fileExists(atPath: kernelPath) {
            Logger.log("正在从 Apple 服务器下载内核（可能需要VPN）")
            if grab_kernelcache(kernelPath) {
                Logger.log("已从 Apple 服务器获取内核缓存", type: .success)
            }
        }
        // 5. All sources exhausted — show clear guidance
        if !fileManager.fileExists(atPath: kernelPath) {
            Logger.log("⚠️ 内核缓存获取失败（所有来源均不可达）", type: .error)
            Logger.log("请尝试：①开启VPN后重试 ②或手动将kernelcache放入应用文档目录", type: .error)
            return false
        }
    }
    // Decode LZFSE-compressed kernelcache in place (safe no-op for raw files),
    // and validate it is a usable Mach-O before handing it to the patchfinder.
    if !prepareKernelcache(kernelPath) {
        try? fileManager.removeItem(atPath: kernelPath)
        return false
    }
    return true
}

/// Tries to download kernelcache from ANY configured mirror.
/// Iterates through KernelcacheSource.mirrors; for each mirror, tries
/// several common URL path layouts. Uses extended timeout for China networks.
/// Returns true as soon as one mirror succeeds.
func downloadKernelcacheFromAnyMirror(_ device: Device, to path: String) -> Bool {
    let model = device.modelIdentifier                     // e.g. "iPhone14,2"
    let modelU = model.replacingOccurrences(of: ",", with: "_") // "iPhone14_2"

    for (idx, mirrorBase) in KernelcacheSource.mirrors.enumerated() {
        guard let base = mirrorBase else { continue }
        Logger.log("正在尝试镜像源 \(idx + 1)/\(KernelcacheSource.mirrors.count): \(base)")

        // Generate candidate URLs for this mirror
        let candidates = [
            "\(base)/\(model)/kernelcache",
            "\(base)/\(modelU)/kernelcache",
            "\(base)/kernelcache"
        ].compactMap { URL(string: $0) }

        for url in candidates {
            Logger.log("Mirror URL: \(url.absoluteString)")
            if downloadKernelcacheFromURL(url, to: path, timeout: KernelcacheSource.downloadTimeoutSec) {
                return true
            }
        }
        Logger.log("镜像源 \(base) 所有路径均失败", type: .error)
    }
    return false
}

/// Downloads kernelcache from a single URL with configurable timeout.
func downloadKernelcacheFromURL(_ url: URL, to path: String, timeout: TimeInterval) -> Bool {
    let sem = DispatchSemaphore(value: 0)
    var result: (loc: URL?, error: Error?) = (nil, nil)

    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = timeout
    config.timeoutIntervalForResource = timeout
    let session = URLSession(configuration: config)

    session.downloadTask(with: url) { loc, _, err in
        result = (loc, err)
        sem.signal()
    }.resume()

    _ = sem.wait(timeout: .now() + timeout + 10) // hard safety margin

    if let loc = result.loc, result.error == nil {
        do {
            try FileManager.default.moveItem(at: loc, to: URL(fileURLWithPath: path))
            Logger.log("内核缓存下载成功！", type: .success)
            return true
        } catch {
            Logger.log("移动内核缓存失败: \(error.localizedDescription)", type: .error)
        }
    } else {
        let errMsg = result.error?.localizedDescription ?? "超时或网络错误"
        Logger.log("下载失败: \(errMsg)", type: .error)
    }
    return false
}


func cleanupPrivatePreboot() -> Bool {
    // Remove /private/preboot/tmp
    let fileManager = FileManager.default
    do {
        try fileManager.removeItem(atPath: "/private/preboot/tmp")
    } catch let e {
        print("Failed to remove /private/preboot/tmp! \(e.localizedDescription)")
        return false
    }
    return true
}

func selectExploit(_ device: Device) -> KernelExploit {
    let flavour = (TIXDefaults().string(forKey: "exploitFlavour") ?? (physpuppet.supports(device) ? "physpuppet" : "landa"))
    if flavour == "landa" { return landa }
    if flavour == "physpuppet" { return physpuppet }
    if flavour == "smith" { return smith }
    return landa
}

func getCandidates() -> [InstalledApp] {
    var apps = [InstalledApp]()
    for candidate in persistenceHelperCandidates {
        if candidate.isInstalled { apps.append(candidate) }
    }
    return apps
}

@discardableResult
func doDirectInstall(_ device: Device) async -> Bool {
    
    let exploit = selectExploit(device)
    
    let iOS14 = device.version < Version("15.0")
    let supportsFullPhysRW = !(device.cpuFamily == .A8 && device.version > Version("15.1.1")) && ((device.isArm64e && device.version >= Version(major: 15, minor: 2)) || (!device.isArm64e && device.version >= Version("15.0")))
    
    Logger.log("当前设备：\(device.modelIdentifier)，iOS \(device.version.readableString)")

    if !iOS14 {
        if !(getKernel(device)) {
            Logger.log("获取内核失败", type: .error)
            return false
        }
    }

    Logger.log("正在分析内核信息")
    if !initialise_kernel_info(kernelPath, iOS14) {
        Logger.log("内核分析失败", type: .error)
        return false
    }

    Logger.log("正在利用内核漏洞 (\(exploit.name))")
    if !exploit.initialise() {
        Logger.log("内核利用失败", type: .error)
        return false
    }
    Logger.log("内核利用成功！", type: .success)
    post_kernel_exploit(iOS14)
    
    var trollstoreTarData: Data?
    if FileManager.default.fileExists(atPath: docsDir + "/TrollStore.tar") {
        trollstoreTarData = try? Data(contentsOf: docsURL.appendingPathComponent("TrollStore.tar"))
    }
    
    if supportsFullPhysRW {
        if device.isArm64e {
            Logger.log("正在绕过 PPL (\(dmaFail.name))")
            if !dmaFail.initialise() {
                Logger.log("绕过 PPL 失败", type: .error)
                return false
            }
            Logger.log("成功绕过 PPL！", type: .success)
        }
        
        if #available(iOS 16, *) {
            libjailbreak_kalloc_pt_init()
        }
        
        if !build_physrw_primitive() {
            Logger.log("构建物理读写原语失败", type: .error)
            return false
        }
        
        if device.isArm64e {
            if !dmaFail.deinitialise() {
                Logger.log("释放 \(dmaFail.name) 失败", type: .error)
                return false
            }
        }
        
        if !exploit.deinitialise() {
            Logger.log("释放 \(exploit.name) 失败", type: .error)
            return false
        }

        Logger.log("正在解除沙箱限制")
        if !unsandbox() {
            Logger.log("解除沙箱失败", type: .error)
            return false
        }

        Logger.log("正在提升权限")
        if !get_root_pplrw() {
            Logger.log("提升权限失败", type: .error)
            return false
        }
        if !platformise() {
            Logger.log("平台化失败", type: .error)
            return false
        }
    } else {
        
        Logger.log("正在解除沙箱并提升权限")
        if !get_root_krw(iOS14) {
            Logger.log("解除沙箱或提升权限失败", type: .error)
            return false
        }
    }
    
    remount_private_preboot()
    
    if let data = trollstoreTarData {
        do {
            try FileManager.default.createDirectory(atPath: "/private/preboot/tmp", withIntermediateDirectories: false)
            FileManager.default.createFile(atPath: "/private/preboot/tmp/TrollStore.tar", contents: nil)
            try data.write(to: URL(string: "file:///private/preboot/tmp/TrollStore.tar")!)
        } catch {
            print("Failed to write out TrollStore.tar - \(error.localizedDescription)")
        }
    }
    
    // Prevents download finishing between extraction and installation
    let useLocalCopy = FileManager.default.fileExists(atPath: "/private/preboot/tmp/TrollStore.tar")

    if !fileManager.fileExists(atPath: "/private/preboot/tmp/trollstorehelper") {
        Logger.log("正在解压 TrollStore.tar")
        if !extractTrollStore(useLocalCopy) {
            Logger.log("解压 TrollStore.tar 失败", type: .error)
            return false
        }
    }
    
    let newCandidates = getCandidates()
    persistenceHelperCandidates = newCandidates
    
    DispatchQueue.main.sync {
        HelperAlert.shared.showAlert = true
        HelperAlert.shared.objectWillChange.send()
    }
    while HelperAlert.shared.showAlert { }
    let persistenceID = TIXDefaults().string(forKey: "persistenceHelper")
    
    if persistenceID != "" {
        if install_persistence_helper(persistenceID) {
            Logger.log("持久化助手安装成功！", type: .success)
        } else {
            Logger.log("持久化助手安装失败", type: .error)
        }
    }
    
    Logger.log("正在安装 TrollStore")
    if !install_trollstore(useLocalCopy ? "/private/preboot/tmp/TrollStore.tar" : Bundle.main.bundlePath + "/TrollStore.tar") {
        Logger.log("安装 TrollStore 失败", type: .error)
    } else {
        Logger.log("TrollStore 安装成功！", type: .success)
    }
    
    if !cleanupPrivatePreboot() {
        Logger.log("清理 /private/preboot 失败", type: .error)
    }
    
    if !supportsFullPhysRW {
        if !drop_root_krw(iOS14) {
            Logger.log("释放 root 权限失败", type: .error)
            return false
        }
        if !exploit.deinitialise() {
            Logger.log("释放 \(exploit.name) 失败", type: .error)
            return false
        }
    }
    
    return true
}

func doIndirectInstall(_ device: Device) async -> Bool {
    let exploit = selectExploit(device)
    
    Logger.log("当前设备：\(device.modelIdentifier)，iOS \(device.version.readableString)")
    
    if !extractTrollStoreIndirect() {
        return false
    }
    defer {
        cleanupIndirectInstall()
    }
    
    if !(getKernel(device)) {
        Logger.log("获取内核失败", type: .error)
    }
    
    Logger.log("正在分析内核信息")
    if !initialise_kernel_info(kernelPath, false) {
        Logger.log("内核分析失败", type: .error)
        return false
    }
    
    Logger.log("正在利用内核漏洞 (\(exploit.name))")
    if !exploit.initialise() {
        Logger.log("内核利用失败", type: .error)
        return false
    }
    defer {
        if !exploit.deinitialise() {
            Logger.log("释放 \(exploit.name) 失败", type: .error)
        }
    }
    Logger.log("内核利用成功！", type: .success)
    post_kernel_exploit(false)
    
    var path: UnsafePointer<CChar>? = nil
    let pathPointer = withUnsafeMutablePointer(to: &path) { ptr in
        UnsafeMutablePointer<UnsafePointer<CChar>?>.init(ptr)
    }
    if is_persistence_helper_installed(pathPointer) {
        Logger.log("持久化助手已安装！(\(path == nil ? "未知" : String(cString: path!)))", type: .warning)
        return false
    }
    
    let apps = get_installed_apps() as? [String]
    var candidates = [InstalledApp]()
    for app in apps ?? [String]() {
        print(app)
        for candidate in persistenceHelperCandidates {
            if app.components(separatedBy: "/")[1].replacingOccurrences(of: ".app", with: "") == candidate.bundleName {
                candidates.append(candidate)
                candidates[candidates.count - 1].isInstalled = true
                candidates[candidates.count - 1].bundlePath = "/var/containers/Bundle/Application/" + app
            }
        }
    }
    
    persistenceHelperCandidates = candidates
    
    DispatchQueue.main.sync {
        HelperAlert.shared.showAlert = true
        HelperAlert.shared.objectWillChange.send()
    }
    while HelperAlert.shared.showAlert { }
    let persistenceID = TIXDefaults().string(forKey: "persistenceHelper")
    
    var pathToInstall = ""
    for candidate in persistenceHelperCandidates {
        if persistenceID == candidate.bundleIdentifier {
            pathToInstall = candidate.bundlePath!
        }
    }
    var success = false
    if !install_persistence_helper_via_vnode(pathToInstall) {
        Logger.log("持久化助手安装失败", type: .error)
    } else {
        Logger.log("持久化助手安装成功！", type: .success)
        success = true

        // v7 fix: After vnode-based binary replacement, we MUST also update the
        // system trust cache so AMFI on iOS 16.x accepts the injected PersistenceHelper.
        // Without this step, opening the host app (e.g. Tips) crashes immediately.
        // The trollstorehelper's "install-persistence-helper" command edits
        // pmap_image4_trust_caches to include the new binary's CDHash.
        let indirectHelperPath = docsDir + "/trollstorehelper"
        let indirectPHPath = docsDir + "/PersistenceHelper"
        if FileManager.default.fileExists(atPath: indirectHelperPath)
            && FileManager.default.fileExists(atPath: indirectPHPath) {
            Logger.log("正在更新系统信任缓存（防止闪退）")
            if install_persistence_helper_with_paths(pathToInstall as NSString, indirectPHPath as NSString, indirectHelperPath as NSString) {
                Logger.log("信任缓存更新成功！", type: .success)
            } else {
                Logger.log("信任缓存更新失败（可能仍会导致闪退）", type: .warning)
                // Don't set success=false here — the injection itself succeeded,
                // and the user can retry or use alternative methods.
            }
        } else {
            Logger.log("找不到 trollstorehelper/PersistenceHelper，跳过信任缓存更新", type: .warning)
        }
    }
    
    if success {
        let verbose = TIXDefaults().bool(forKey: "verbose")
        Logger.log("即将重启桌面（\(verbose ? "15" : "5") 秒后）")
        DispatchQueue.global().async {
            sleep(verbose ? 15 : 5)
            restartBackboard()
        }
    }
    
    return true
}
