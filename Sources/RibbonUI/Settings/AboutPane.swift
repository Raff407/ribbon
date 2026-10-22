import SwiftUI

struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.split.3x1.fill")
                .font(.system(size: 54))
                .foregroundColor(.accentColor)
            Text("Ribbon").font(.largeTitle.weight(.semibold))
            Text(version).foregroundStyle(.secondary)
            Text("A scrolling window manager for macOS. Every window sits side by side on one endless strip, the way PaperWM and niri work on Linux. Nothing overlaps, and opening one more app never shrinks the rest — you just scroll.")
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
