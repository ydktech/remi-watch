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
    @State private var eyeWeight: Double = 0.0

    private let base      = Image(decorative: loadCGImage("th_base"),      scale: 1)
    private let mouthOpen = Image(decorative: loadCGImage("th_mouth_open"), scale: 1)
    private let eyeClosed = Image(decorative: loadCGImage("th_eye_closed"), scale: 1)

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 1.0/15.0, paused: false)) { _ in
                Canvas { ctx, size in
                    let rect = CGRect(origin: .zero, size: size)
                    ctx.draw(base, in: rect)
                    if remi.mouthAmplitude > 0.02 {
                        var c = ctx
                        c.opacity = Double(min(1, remi.mouthAmplitude))
                        c.draw(mouthOpen, in: rect)
                    }
                    if eyeWeight > 0.01 {
                        var c = ctx
                        c.opacity = eyeWeight
                        c.draw(eyeClosed, in: rect)
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
