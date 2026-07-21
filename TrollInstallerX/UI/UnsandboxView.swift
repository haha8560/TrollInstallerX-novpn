//
//  UnsandboxView.swift
//  TrollInstallerX
//
//  Created by Alfie on 26/03/2024.
//

import SwiftUI

struct UnsandboxView: View {
    @Binding var isShowingMDCAlert: Bool
    var body: some View {            
        VStack {
                Text("解除沙箱限制")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
                    .padding()
                Text("TrollInstallerX 使用 100% 可靠的 MacDirtyCow 漏洞来解除沙箱限制并复制内核缓存。点击下方按钮执行漏洞利用——只需操作一次。")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundColor(.white)
                Button(action: {
                    UIImpactFeedbackGenerator().impactOccurred()
                    grant_full_disk_access({ error in
                        if let error = error {
                            Logger.log("MacDirtyCow 利用失败！")
                            NSLog("Failed to MacDirtyCow - \(error.localizedDescription)")
                        }
                        withAnimation {
                            isShowingMDCAlert = false
                        }
                    })
                }, label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .frame(width: 175, height: 45)
                            .foregroundColor(.white.opacity(0.2))
                            .shadow(radius: 10)
                        Text("解除沙箱")
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .padding()
                    }
                })
                .padding(.vertical)
            }
    }
}
