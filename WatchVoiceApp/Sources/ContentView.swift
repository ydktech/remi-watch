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
    @State private var recordPulse: CGFloat = 1.0
    @State private var eyeWeight: Double = 0.0

    private let baseImg      = loadBundleImage("th_base")
    private let mouthOpenImg = loadBundleImage("th_mouth_open")
    private let eyeClosedImg = loadBundleImage("th_eye_closed")

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 1.0/15.0, paused: false)) { _ in
                Canvas { ctx, size in
                    let rect = CGRect(origin: .zero, size: size)
                    if let img = baseImg      { ctx.draw(img, in: rect) }
                    if let img = mouthOpenImg, remi.mouthAmplitude > 0.02 {
                        ctx.drawLayer { inner in
                            inner.opacity = Double(min(1.0, remi.mouthAmplitude))
                            inner.draw(img, in: rect)
                        }
                    }
                    if let img = eyeClosedImg, eyeWeight > 0.01 {
                        ctx.drawLayer { inner in
                            inner.opacity = eyeWeight
                            inner.draw(img, in: rect)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .onAppear {
                remi.prepareAudioSession()
                scheduleBlink()
            }

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
            .padding(.bottom, 23)
        }
        .onOpenURL { url in
            guard url.scheme == "watchvoiceapp" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.remi.startRecording()
            }
        }
    }

    private func scheduleBlink() {
        let delay = Double.random(in: 2.5...5.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            withAnimation(.linear(duration: 0.08)) { eyeWeight = 1.0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                withAnimation(.linear(duration: 0.08)) { eyeWeight = 0.0 }
                scheduleBlink()
            }
        }
    }
}
