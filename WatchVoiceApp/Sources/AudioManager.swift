import Foundation
import AVFoundation

@MainActor
class RemiManager: ObservableObject {
    @Published var isLoading = false
    @Published var isPlaying = false
    @Published var currentLine: String?

    private let cerebrasKey = Secrets.cerebrasKey
    private let fishApiKey  = Secrets.fishApiKey
    private let fishVoiceId = Secrets.fishVoiceId

    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var speakTask: Task<Void, Never>?

    private let systemPrompt = """
    You are Remi, a tsundere AI assistant. Reply ONLY in this exact format with no deviation:
    [tag1] 日本語文1。[tag2] 日本語文2。
    Rules: exactly 2 sentences, each under 12 Japanese characters, no newlines, no extra text.
    Tags: [angry][annoyed][sarcastic][confident][embarrassed][happy][excited][sad][sighing][laughing]
    Example: [angry] また逃げたの？[sighing] はあ、もう。
    """

    private let contextVariants: [[String]] = [
        ["運動について一言。", "英語学習について一言。", "仕事について一言。"],
        ["今日の目標を確認して。", "サボり防止の一言。", "モチベを上げる一言。"],
        ["ツンデレっぽく褒めて。", "叱咤激励して。", "呆れた感じで一言。"]
    ]

    func speak() {
        guard !isLoading, !isPlaying else { return }
        isLoading = true
        currentLine = nil

        speakTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await self.fetchRemiLine(context: self.makeTimeContext())
                await MainActor.run { self.currentLine = text }
                try await self.streamTTS(text: text)
            } catch {
                print("Error: \(error)")
            }
            await MainActor.run { self.stopPlayback() }
        }
    }

    // MARK: - Streaming TTS

    nonisolated private func streamTTS(text: String) async throws {
        let sampleRate: Double = 44100
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

        var req = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(fishApiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("s2-pro", forHTTPHeaderField: "model")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "reference_id": fishVoiceId,
            "format": "pcm",
            "normalize": true,
            "latency": "low",
            "speed": 1.2,
            "chunk_length": 100
        ])
        req.timeoutInterval = 60

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        try engine.start()

        await MainActor.run {
            self.audioEngine = engine
            self.playerNode = player
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let bytesPerChunk = Int(sampleRate * 0.1) * 2  // 100ms × 2 bytes/sample (int16 mono)
        let minChunksBeforePlay = 3                     // buffer 300ms before starting
        var rawData = Data()
        rawData.reserveCapacity(bytesPerChunk * 4)
        var pendingBuffers: [AVAudioPCMBuffer] = []
        var started = false

        for try await byte in asyncBytes {
            rawData.append(byte)

            while rawData.count >= bytesPerChunk {
                let chunk = rawData.prefix(bytesPerChunk)
                rawData.removeFirst(bytesPerChunk)

                guard let buf = makeFloatBuffer(from: chunk, format: format) else { continue }

                if !started {
                    pendingBuffers.append(buf)
                    if pendingBuffers.count >= minChunksBeforePlay {
                        for b in pendingBuffers {
                            player.scheduleBuffer(b, completionCallbackType: .dataConsumed, completionHandler: nil)
                        }
                        pendingBuffers = []
                        player.play()
                        started = true
                        await MainActor.run {
                            self.isLoading = false
                            self.isPlaying = true
                        }
                    }
                } else {
                    player.scheduleBuffer(buf, completionCallbackType: .dataConsumed, completionHandler: nil)
                }
            }
        }

        // flush pending pre-buffer + tail if stream ended before minChunksBeforePlay
        if !started {
            for b in pendingBuffers {
                player.scheduleBuffer(b, completionCallbackType: .dataConsumed, completionHandler: nil)
            }
            if rawData.count >= 2, let buf = makeFloatBuffer(from: rawData, format: format) {
                player.scheduleBuffer(buf, completionCallbackType: .dataConsumed, completionHandler: nil)
            }
            player.play()
            await MainActor.run {
                self.isLoading = false
                self.isPlaying = true
            }
        } else if rawData.count >= 2, let buf = makeFloatBuffer(from: rawData, format: format) {
            player.scheduleBuffer(buf, completionCallbackType: .dataConsumed, completionHandler: nil)
        }

        let sentinel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        sentinel.frameLength = 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { _ in
                cont.resume()
            }
        }
    }

    nonisolated private func makeFloatBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { return nil }
        buf.frameLength = AVAudioFrameCount(frameCount)
        let out = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frameCount { out[i] = Float(src[i]) / 32768.0 }
        }
        return buf
    }

    private func stopPlayback() {
        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        isPlaying = false
        isLoading = false
    }

    // MARK: - Network

    nonisolated private func makeTimeContext() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let timeBase: String
        switch hour {
        case 5..<9:   timeBase = "朝"
        case 9..<12:  timeBase = "午前"
        case 12..<14: timeBase = "昼"
        case 14..<18: timeBase = "午後"
        case 18..<21: timeBase = "夕方"
        case 21..<24: timeBase = "夜"
        default:      timeBase = "深夜"
        }
        return "\(timeBase)。\(contextVariants.randomElement()!.randomElement()!)"
    }

    nonisolated private func stripTags(_ text: String) -> String {
        text.replacingOccurrences(of: "\\([^)]+\\)\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func fetchRemiLine(context: String) async throws -> String {
        var req = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cerebrasKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "llama3.1-8b",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": context]
            ],
            "max_tokens": 60
        ])
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return (content ?? "[annoyed] もう。[sighing] しょうがないわね。").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
