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
    @State private var breathScale: CGFloat = 1.0
    @State private var recordPulse: CGFloat = 1.0

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
                    remi.prepareAudioSession()
                }

            // partial STT text during recording
            if let partial = remi.partialText {
                Text(partial)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 85)
            } else if let line = remi.currentLine {
                Text(line)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 6)
                    .padding(.bottom, 85)
            }

            Button(action: {
                if remi.isRecording {
                    remi.commitRecording()
                } else {
                    remi.startRecording()
                }
            }) {
                ZStack {
                    Circle()
                        .fill(remi.isRecording
                              ? Color.red.opacity(0.85)
                              : Color.black.opacity(0.75))
                        .scaleEffect(remi.isRecording ? recordPulse : 1.0)
                    if remi.isLoading {
                        ProgressView()
                            .tint(.white)
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
            .padding(.bottom, 23)
        }
        .onOpenURL { url in
            guard url.scheme == "watchvoiceapp" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.remi.startRecording()
            }
        }
    }
}
