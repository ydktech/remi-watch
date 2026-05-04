import Foundation
import AVFoundation
import Combine

struct PhonemeEvent: Decodable {
    let t: Double
    let end: Double
    let mouth: Float
}

struct Timeline: Decodable {
    let duration: Double
    let events: [PhonemeEvent]
}

@MainActor
class AnimationController: ObservableObject {
    @Published var eyeWeight:   Float = 0.0
    @Published var mouthWeight: Float = 0.0

    private var player: AVAudioPlayer?
    private var timeline: [PhonemeEvent] = []
    private var timer: Timer?
    private var blinkOffset: Double = 0

    // Blink timing: random intervals 3-5s
    private var nextBlink: Double = 2.5
    private var blinkPeriod: Double = 4.0

    func load(audioURL: URL, timelineURL: URL) {
        let data = try! Data(contentsOf: timelineURL)
        let tl = try! JSONDecoder().decode(Timeline.self, from: data)
        self.timeline = tl.events
        self.player = try? AVAudioPlayer(contentsOf: audioURL)
    }

    func play() {
        player?.currentTime = 0
        player?.play()
        blinkOffset = player?.currentTime ?? 0
        scheduleNextBlink()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        player?.stop()
        timer?.invalidate()
        timer = nil
        eyeWeight   = 0.0
        mouthWeight = 0.0
    }

    private func tick() {
        guard let t = player?.currentTime, player?.isPlaying == true else {
            stop(); return
        }
        mouthWeight = getMouth(at: t)
        eyeWeight   = getBlink(at: t)
    }

    private func getMouth(at t: Double) -> Float {
        let attack = 0.025, decay = 0.04
        var best: Float = 0.0
        for ev in timeline {
            var w: Double = 0
            if t < ev.t - attack { continue }
            else if t < ev.t               { w = (t - (ev.t - attack)) / attack }
            else if t <= ev.end - decay    { w = 1.0 }
            else if t <= ev.end            { w = (ev.end - t) / decay }
            else { continue }
            let val = ev.mouth * Float(w*w*(3-2*w))
            if val > best { best = val }
        }
        return best
    }

    private func getBlink(at t: Double) -> Float {
        if t >= nextBlink && t < nextBlink + 0.15 {
            let x = (t - nextBlink) / 0.15
            return Float(sin(.pi * x))
        }
        if t >= nextBlink + 0.15 { scheduleNextBlink() }
        return 0.0
    }

    private func scheduleNextBlink() {
        let current = player?.currentTime ?? 0
        blinkPeriod = Double.random(in: 3.0...5.0)
        nextBlink   = current + blinkPeriod
    }
}
