//
//  TrollHelperOTAView.swift
//  TrollInstallerX
//
//  Created by Alfie on 26/03/2024.
//

import SwiftUI

struct TrollHelperOTAView: View {
    @Binding var arm64eVersion: Bool
    var body: some View {
            VStack {
                Text("TrollHelperOTA 安装")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding()
                Text("您的设备支持 TrollHelperOTA —— 一种 100% 可靠的安装方式，无需自签应用。点击弹窗外部可关闭，或点击下方按钮通过 OTA 安装。")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                Button(action: {
                    UIImpactFeedbackGenerator().impactOccurred()
                    UIApplication.shared.open(URL(string: "https://api.jailbreaks.app/troll" + (arm64eVersion ? "64e" : ""))!)
                }, label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .frame(width: 175, height: 45)
                            .foregroundColor(.white.opacity(0.2))
                            .shadow(radius: 10)
                        Text("前往安装")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                    }
                })
                .padding(.vertical)
            }
    }
}
