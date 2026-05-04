import SwiftUI
import ImageIO

private func loadBundleImage(_ name: String) -> Image? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return Image(decorative: cg, scale: 1.0)
}

struct ContentView: View {
    @StateObject private var remi = RemiManager()
    @State private var buttonLocked = false
    @State private var breathScale: CGFloat = 1.0

    private let faceImage: Image =
        loadBundleImage("remi-face-dafult") ?? Image(systemName: "person.fill")

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            faceImage
                .resizable()
                .scaledToFill()
                .scaleEffect(breathScale)
                .ignoresSafeArea()
                .onAppear {
                    withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                        breathScale = 1.03
                    }
                }

            if let line = remi.currentLine {
                Text(line)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 4)
            }

            Button(action: {
                buttonLocked = true
                remi.speak()
            }) {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.75))
                    if remi.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: remi.isPlaying ? "speaker.wave.2.fill" : "mic.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(buttonLocked || remi.isLoading || remi.isPlaying)
            .onChange(of: remi.isLoading) { _, loading in
                if !loading && !remi.isPlaying { buttonLocked = false }
            }
            .onChange(of: remi.isPlaying) { _, playing in
                if !playing { buttonLocked = false }
            }
            .padding(.bottom, 23)
        }
        .onOpenURL { url in
            guard url.scheme == "watchvoiceapp" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.buttonLocked = true
                self.remi.speak()
            }
        }
    }
}
