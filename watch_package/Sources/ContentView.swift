import SwiftUI

struct ContentView: View {
    @StateObject private var controller = AnimationController()
    @State private var isPlaying = false

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()

            MetalView(
                eyeWeight:   controller.eyeWeight,
                mouthWeight: controller.mouthWeight
            )
            .aspectRatio(1, contentMode: .fit)

            VStack {
                Spacer()
                Button(isPlaying ? "■" : "▶") {
                    if isPlaying {
                        controller.stop()
                    } else {
                        controller.play()
                    }
                    isPlaying.toggle()
                }
                .font(.title2)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            let audio    = Bundle.main.url(forResource: "audio",    withExtension: "m4a")!
            let timeline = Bundle.main.url(forResource: "timeline", withExtension: "json")!
            controller.load(audioURL: audio, timelineURL: timeline)
        }
    }
}
