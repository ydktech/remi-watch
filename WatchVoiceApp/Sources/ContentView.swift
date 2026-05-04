import SwiftUI
import ImageIO

private func loadCGImage(_ name: String) -> CGImage {
    let url = Bundle.main.url(forResource: name, withExtension: "png")!
    let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(src, 0, nil)!
}

struct ContentView: View {
    @StateObject private var remi = RemiManager()
    @State private var breathScale: CGFloat = 1.0

    private let faceNeutral   = Image(decorative: loadCGImage("face_neutral"),   scale: 1)
    private let faceHappy     = Image(decorative: loadCGImage("face_happy"),     scale: 1)
    private let faceSad       = Image(decorative: loadCGImage("face_sad"),       scale: 1)
    private let faceAngry     = Image(decorative: loadCGImage("face_angry"),     scale: 1)
    private let faceSurprised = Image(decorative: loadCGImage("face_surprised"), scale: 1)
    private let faceFearful   = Image(decorative: loadCGImage("face_fearful"),   scale: 1)
    private let faceDisgust   = Image(decorative: loadCGImage("face_disgust"),   scale: 1)
    private let faceShy       = Image(decorative: loadCGImage("face_shy"),       scale: 1)
    private let faceConfident = Image(decorative: loadCGImage("face_confident"), scale: 1)

    private var currentFace: Image {
        switch remi.emotion {
        case "happy":     return faceHappy
        case "sad":       return faceSad
        case "angry":     return faceAngry
        case "surprised": return faceSurprised
        case "fearful":   return faceFearful
        case "disgust":   return faceDisgust
        case "shy":       return faceShy
        case "confident": return faceConfident
        default:          return faceNeutral
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()

            ZStack {
                faceNeutral  .resizable().scaledToFill().opacity(remi.emotion == "neutral"   ? 1 : 0)
                faceHappy    .resizable().scaledToFill().opacity(remi.emotion == "happy"     ? 1 : 0)
                faceSad      .resizable().scaledToFill().opacity(remi.emotion == "sad"       ? 1 : 0)
                faceAngry    .resizable().scaledToFill().opacity(remi.emotion == "angry"     ? 1 : 0)
                faceSurprised.resizable().scaledToFill().opacity(remi.emotion == "surprised" ? 1 : 0)
                faceFearful  .resizable().scaledToFill().opacity(remi.emotion == "fearful"   ? 1 : 0)
                faceDisgust  .resizable().scaledToFill().opacity(remi.emotion == "disgust"   ? 1 : 0)
                faceShy      .resizable().scaledToFill().opacity(remi.emotion == "shy"       ? 1 : 0)
                faceConfident.resizable().scaledToFill().opacity(remi.emotion == "confident" ? 1 : 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .scaleEffect(breathScale)
            .animation(.easeInOut(duration: 0.4), value: remi.emotion)
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
