import SwiftUI
import UIKit

struct ContentView: View {
    private let systemVersion = UIDevice.current.systemVersion
    private let model = UIDevice.current.model

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [.indigo, .teal, .orange],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "cloud.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.white)

                Text("Running in the cloud")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)

                VStack(spacing: 6) {
                    Text("iOS \(systemVersion)")
                        .font(.title2.weight(.semibold))
                    Text("\(model) Simulator on a GitHub macOS runner")
                        .font(.subheadline)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                // Liquid Glass: an iOS 26 SDK API, so this only compiles on the latest Xcode.
                .glassEffect(.regular, in: .rect(cornerRadius: 24))

                Text("Built \(Date.now.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding()
        }
    }
}

#Preview {
    ContentView()
}
