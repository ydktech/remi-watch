import Foundation
import AVFoundation

@MainActor
class RemiManager: ObservableObject {
    @Published var isRecording = false
    @Published var isLoading  = false
    @Published var isPlaying  = false
    @Published var partialText: String?
    @Published var currentLine: String?

    private let cerebrasKey   = Secrets.cerebrasKey
    private let fishApiKey    = Secrets.fishApiKey
    private let fishVoiceId   = Secrets.fishVoiceId
    private let elevenLabsKey = Secrets.elevenLabsKey

    private var audioEngine:  AVAudioEngine?
    private var playerNode:   AVAudioPlayerNode?
    private var recordEngine: AVAudioEngine?
    private var wsTask:       URLSessionWebSocketTask?
    private var sttTask:      Task<Void, Never>?

    private let systemPrompt = """
    You are Remi, a tsundere AI assistant. The user spoke to you — respond to what they said.
    Reply ONLY in this exact format with no deviation:
    [tag1] 日本語文1。[tag2] 日本語文2。
    Rules: exactly 2 sentences, each under 15 Japanese characters, no newlines, no extra text.
    Tags: [angry][annoyed][sarcastic][confident][embarrassed][happy][excited][sad][sighing][laughing]
    Example: [embarrassed] そ、そうじゃないし！[annoyed] もう、黙ってよ。
    """

    // MARK: - Session setup (once, reused throughout)

    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { _, error in
                if let e = error { cont.resume(throwing: e) }
                else { cont.resume() }
            }
        }
    }

    // MARK: - Public interface

    func prepareAudioSession() {
        Task { try? await activateAudioSession() }
    }

    func startRecording() {
        guard !isRecording, !isLoading, !isPlaying else { return }
        isRecording = true
        partialText = "..."
        currentLine = nil

        sttTask = Task { [weak self] in
            guard let self else { return }
            do {
                let transcript = try await self.runSTTSession()
                await MainActor.run {
                    self.isRecording = false
                    self.partialText = nil
                }
                guard let text = transcript, !text.isEmpty else {
                    await MainActor.run { self.isLoading = false }
                    return
                }
                await MainActor.run { self.isLoading = true }
                let remiText = try await self.fetchRemiLine(userInput: text)
                await MainActor.run { self.currentLine = remiText }
                try await self.streamTTS(text: remiText)
            } catch {
                print("STS error: \(error)")
            }
            await MainActor.run { self.resetState() }
        }
    }

    func cancelRecording() {
        sttTask?.cancel()
        sttTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        stopMicEngine()
        resetState()
    }

    // MARK: - ElevenLabs Realtime STT

    nonisolated private func runSTTSession() async throws -> String? {
        // Activate session on MainActor, get format (do NOT start engine yet)
        // Activate audio session first (watchOS async API unlocks NECP WebSocket policy)
        try await activateAudioSession()

        let (engine, converter, tapFormat) = try await MainActor.run { [self] in
            let eng = AVAudioEngine()
            let nativeFmt = eng.inputNode.outputFormat(forBus: 0)
            let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000, channels: 1, interleaved: false)!
            guard let conv = AVAudioConverter(from: nativeFmt, to: target) else {
                throw URLError(.cannotConnectToHost)
            }
            self.recordEngine = eng
            return (eng, conv, nativeFmt)
        }

        // Open WebSocket
        var comps = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        comps.queryItems = [
            URLQueryItem(name: "model_id",        value: "scribe_v2_realtime"),
            URLQueryItem(name: "language_code",   value: "ja"),
            URLQueryItem(name: "audio_format",    value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "no_verbatim",     value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(elevenLabsKey, forHTTPHeaderField: "xi-api-key")
        req.networkServiceType = .avStreaming
        let ws = URLSession.shared.webSocketTask(with: req)
        await MainActor.run { self.wsTask = ws }
        ws.resume()

        // Install mic tap — converts native format → 16kHz Int16 → WebSocket
        let targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000, channels: 1, interleaved: false)!
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buf, _ in
            let outFrames = AVAudioFrameCount(Double(buf.frameLength) * 16000 / tapFormat.sampleRate)
            guard outFrames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outFrames) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData; return buf
            }
            guard err == nil, let data = Self.toInt16Data(out) else { return }
            let b64 = data.base64EncodedString()
            let msg = #"{"message_type":"input_audio_chunk","audio_base_64":"\#(b64)","commit":false}"#
            ws.send(.string(msg)) { _ in }
        }

        try engine.start()

        // Receive loop
        return try await withTaskCancellationHandler {
            try await self.receiveUntilCommit(ws: ws)
        } onCancel: {
            ws.cancel(with: .normalClosure, reason: nil)
        }
    }

    nonisolated private func receiveUntilCommit(ws: URLSessionWebSocketTask) async throws -> String? {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                print("WS closed: \(error)")
                return nil
            }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["message_type"] as? String else { continue }

            print("WS [\(type)]: \(json["text"] ?? "")")

            switch type {
            case "partial_transcript":
                if let t = json["text"] as? String, !t.isEmpty {
                    await MainActor.run { self.partialText = t }
                }
            case "committed_transcript":
                let transcript = json["text"] as? String ?? ""
                guard !transcript.isEmpty else { continue }
                ws.cancel(with: .normalClosure, reason: nil)
                await MainActor.run { self.stopMicEngine() }
                return transcript
            case "auth_error":
                print("ElevenLabs auth error — check API key")
                throw URLError(.userAuthenticationRequired)
            default: break
            }
        }
    }

    @MainActor
    private func stopMicEngine() {
        recordEngine?.inputNode.removeTap(onBus: 0)
        recordEngine?.stop()
        recordEngine = nil
    }

    nonisolated private static func toInt16Data(_ buf: AVAudioPCMBuffer) -> Data? {
        guard let ch = buf.floatChannelData else { return nil }
        let count = Int(buf.frameLength)
        guard count > 0 else { return nil }
        var data = Data(count: count * 2)
        data.withUnsafeMutableBytes { raw in
            let dst = raw.bindMemory(to: Int16.self)
            let src = UnsafeBufferPointer(start: ch[0], count: count)
            for i in 0..<count {
                dst[i] = Int16(max(-32768, min(32767, Int32(src[i] * 32767))))
            }
        }
        return data
    }

    // MARK: - Streaming TTS

    nonisolated private func streamTTS(text: String) async throws {
        let sampleRate: Double = 44100
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate, channels: 1, interleaved: false)!

        var req = URLRequest(url: URL(string: "https://api.fish.audio/v1/tts")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(fishApiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("s2-pro", forHTTPHeaderField: "model")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text, "reference_id": fishVoiceId,
            "format": "pcm", "normalize": true,
            "latency": "low", "speed": 1.2, "chunk_length": 100
        ])
        req.timeoutInterval = 60

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        // Session already active as playAndRecord — just start engine
        try engine.start()

        await MainActor.run {
            self.audioEngine = engine
            self.playerNode  = player
        }

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let bytesPerChunk = Int(sampleRate * 0.1) * 2
        var rawData = Data()
        rawData.reserveCapacity(bytesPerChunk * 4)
        var pending: [AVAudioPCMBuffer] = []
        var started = false

        for try await byte in asyncBytes {
            rawData.append(byte)
            while rawData.count >= bytesPerChunk {
                let chunk = rawData.prefix(bytesPerChunk)
                rawData.removeFirst(bytesPerChunk)
                guard let buf = floatBuffer(from: chunk, format: format) else { continue }
                if !started {
                    pending.append(buf)
                    if pending.count >= 3 {
                        for b in pending {
                            player.scheduleBuffer(b, completionCallbackType: .dataConsumed, completionHandler: nil)
                        }
                        pending = []
                        player.play()
                        started = true
                        await MainActor.run { self.isLoading = false; self.isPlaying = true }
                    }
                } else {
                    player.scheduleBuffer(buf, completionCallbackType: .dataConsumed, completionHandler: nil)
                }
            }
        }

        if !started {
            for b in pending {
                player.scheduleBuffer(b, completionCallbackType: .dataConsumed, completionHandler: nil)
            }
            if rawData.count >= 2, let buf = floatBuffer(from: rawData, format: format) {
                player.scheduleBuffer(buf, completionCallbackType: .dataConsumed, completionHandler: nil)
            }
            player.play()
            await MainActor.run { self.isLoading = false; self.isPlaying = true }
        } else if rawData.count >= 2, let buf = floatBuffer(from: rawData, format: format) {
            player.scheduleBuffer(buf, completionCallbackType: .dataConsumed, completionHandler: nil)
        }

        let sentinel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        sentinel.frameLength = 1
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            player.scheduleBuffer(sentinel, completionCallbackType: .dataPlayedBack) { _ in cont.resume() }
        }
    }

    nonisolated private func floatBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
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

    @MainActor
    private func resetState() {
        audioEngine?.stop()
        audioEngine = nil
        playerNode?.stop()
        playerNode = nil
        isRecording = false
        isLoading   = false
        isPlaying   = false
    }

    // MARK: - LLM

    nonisolated private func fetchRemiLine(userInput: String?) async throws -> String {
        let userMessage: String
        if let input = userInput, !input.isEmpty {
            userMessage = "User said: \"\(input)\""
        } else {
            let h = Calendar.current.component(.hour, from: Date())
            let base: String
            switch h {
            case 5..<9: base = "朝"; case 9..<12: base = "午前"; case 12..<14: base = "昼"
            case 14..<18: base = "午後"; case 18..<21: base = "夕方"; case 21..<24: base = "夜"
            default: base = "深夜"
            }
            let v = [["運動について一言。","英語学習について一言。","仕事について一言。"],
                     ["今日の目標を確認して。","サボり防止の一言。","モチベを上げる一言。"],
                     ["ツンデレっぽく褒めて。","叱咤激励して。","呆れた感じで一言。"]]
            userMessage = "\(base)。\(v.randomElement()!.randomElement()!)"
        }
        var req = URLRequest(url: URL(string: "https://api.cerebras.ai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(cerebrasKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "llama3.1-8b",
            "messages": [["role": "system", "content": systemPrompt],
                         ["role": "user",   "content": userMessage]],
            "max_tokens": 80
        ])
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        return (content ?? "[annoyed] もう。[sighing] しょうがないわね。")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
