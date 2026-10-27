import SwiftUI
import TossCore
import UIKit

struct OnboardingView: View {
    @Environment(TossEngine.self) private var engine
    @Binding var onboarded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var showScanner = false

    var body: some View {
        ScrollView {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Group {
                switch page {
                case 0:
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 72, weight: .light))
                        .foregroundStyle(.tint)
                        .frame(height: 160)
                case 1: DeviceIllustration().frame(height: 160)
                case 2:
                    HStack(spacing: 18) {
                        ForEach(["map", "safari", "calendar", "folder"], id: \.self) { symbol in
                            Image(systemName: symbol).font(.title).foregroundStyle(.tint)
                                .frame(width: 52, height: 52)
                                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }.frame(height: 160)
                default:
                    Image(systemName: engine.pairingMessage?.hasPrefix("Connected") == true ? "checkmark.circle.fill" : "laptopcomputer.and.iphone")
                        .font(.system(size: 68)).foregroundStyle(.tint).frame(height: 160)
                }
            }
            .accessibilityHidden(true)

            Text(["Toss", "Pick up where you left off.", "It understands what you send.", "Connect your devices"][page])
                .font(.largeTitle.bold()).multilineTextAlignment(.center)
                .padding(.top, 24)
            Text([
                "Send anything between your devices.\nLinks, files, text and more, right where you need them.",
                "Send links, files and text between your devices without hunting through menus.",
                "Toss gives you the right actions for whatever arrives.",
                "Scan a pairing code on your Mac to start sending securely."
            ][page])
            .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(.top, 12).padding(.horizontal, 24)

            if page == 3 {
                if let message = engine.pairingMessage { Text(message).font(.subheadline).padding(.top, 20) }
                ForEach(engine.devices) { device in
                    DeviceRow(device: device, online: engine.onlineIDs.contains(device.id))
                        .padding(.horizontal, 24).padding(.top, 16)
                }
            }
            Spacer(minLength: 32)
            HStack(spacing: 7) {
                ForEach(0..<4) { index in
                    Capsule().fill(index == page ? Color.accentColor : Color.secondary.opacity(0.25))
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }.padding(.bottom, 28)
            Button(page == 0 ? "Get Started" : page == 3 ? "Scan Pairing Code" : "Continue") {
                if page == 3 { showScanner = true } else { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { page += 1 } }
            }
            .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
            if page == 3 {
                Button(engine.devices.isEmpty ? "Set up later" : "Continue to Inbox") { onboarded = true }
                    .padding(.top, 16)
            }
        }
        .padding(28)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showScanner) { PairingScannerView() }
        .onChange(of: engine.pairingMessage) { _, message in
            if message?.hasPrefix("Connected") == true {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }
}

private struct DeviceIllustration: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.primary, lineWidth: 5)
                .frame(width: 170, height: 108)
                .overlay(alignment: .bottom) { Rectangle().fill(.primary).frame(height: 5).offset(y: 8) }
            RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 5)
                .frame(width: 53, height: 100).background(.background, in: RoundedRectangle(cornerRadius: 14))
                .offset(x: 16, y: 10)
        }.frame(width: 220, height: 130)
    }
}
