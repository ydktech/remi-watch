import SwiftUI
import ImageIO

private func loadCGImage(_ name: String) -> CGImage {
    let url = Bundle.main.url(forResource: name, withExtension: "png")!
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

struct ContentView: View {
    @StateObject private var remi = RemiManager()
    @State private var recordPulse: CGFloat = 1.0
    @State private var breathScale: CGFloat = 1.0

    private let face = Image(decorative: loadCGImage("remi-face-dafult"), scale: 1)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            face
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(breathScale)
                .ignoresSafeArea()

            Button(action: {
                if remi.isRecording { remi.commitRecording() }
                else { remi.startRecording() }
            }) {
                ZStack {
                    Circle()
                        .fill(remi.isRecording
                              ? Color.red.opacity(0.85)
                              : Color.black.opacity(0.75))
                        .scaleEffect(remi.isRecording ? recordPulse : 1.0)
                    if remi.isLoading {
                        ProgressView().tint(.white)
                    } else if remi.isRecording {
                        Image(systemName: "xmark")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: remi.isPlaying ? "speaker.wave.2.fill" : "mic.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 56, height: 56)
            }
            .buttonStyle(.plain)
            .disabled(remi.isLoading || remi.isPlaying)
            .onChange(of: remi.isRecording) { _, recording in
                if recording {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        recordPulse = 1.12
                    }
                } else {
                    withAnimation(.default) { recordPulse = 1.0 }
                }
            }
            .padding(.bottom, 6)
        }
        .onAppear {
            remi.prepareAudioSession()
            withAnimation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true)) {
                breathScale = 1.025
            }
        }
        .onOpenURL { url in
            guard url.scheme == "watchvoiceapp" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.remi.startRecording()
            }
        }
    }
}
