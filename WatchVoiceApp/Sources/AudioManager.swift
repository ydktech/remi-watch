import Foundation
import AVFoundation

private final class SpeechGate: @unchecked Sendable { var active = false }

@MainActor
class RemiManager: ObservableObject {
    @Published var isRecording = false
    @Published var isLoading  = false
    @Published var isPlaying  = false
    @Published var partialText: String?
    @Published var currentLine: String?

    private let cerebrasKey   = Secrets.cerebrasKey
    private let openRouterKey = Secrets.openRouterKey
    private let fishApiKey    = Secrets.fishApiKey
    private let fishVoiceId   = Secrets.fishVoiceId
    private let elevenLabsKey = Secrets.elevenLabsKey

    private var audioEngine:  AVAudioEngine?
    private var playerNode:   AVAudioPlayerNode?
    private var recordEngine: AVAudioEngine?
    private var wsTask:       URLSessionWebSocketTask?
    private var sttTask:      Task<Void, Never>?
    private var chatHistory:  [[String: String]] = []

    private let systemPrompt = """
    あなたはレミ、典型的なツンデレAIアシスタントです。ユーザーの話し相手です。
    必ず以下の形式のみで返答してください（絶対に逸脱しないこと）：
    [tag1] 日本語文1。[tag2] 日本語文2。
    ルール：必ず2文、各文は15文字以内、改行なし、余分なテキストなし。
    タグ一覧：[angry][annoyed][sarcastic][confident][embarrassed][happy][excited][sad][sighing][laughing]
    レミのキャラクター：
    - 素直になれないが本当は優しい
    - 「べ、別に心配してるわけじゃないし！」のような言い方をする
    - 敬語は使わない、タメ口
    - 語尾に「わよ」「じゃない」「でしょ」「わね」などを使う
    - 照れると否定してごまかす
    例：[embarrassed] べ、別にあんたのことが好きなわけじゃないし！[annoyed] もう、黙ってよね。
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
                let t0 = Date()
                let transcript = try await self.runSTTSession()
                let sttTime = Date().timeIntervalSince(t0)
                await MainActor.run {
                    self.isRecording = false
                    self.partialText = nil
                }
                guard let text = transcript, !text.isEmpty else {
                    await MainActor.run { self.isLoading = false }
                    return
                }
                print("⏱ STT: \(String(format: "%.2f", sttTime))s → \"\(text)\"")
                await MainActor.run { self.isLoading = true }
                let t1 = Date()
                let remiText = try await self.fetchRemiLine(userInput: text)
                print("⏱ LLM: \(String(format: "%.2f", Date().timeIntervalSince(t1)))s → \"\(remiText)\"")
                await MainActor.run { self.currentLine = remiText }
                let t2 = Date()
                try await self.streamTTS(text: remiText)
                print("⏱ TTS: \(String(format: "%.2f", Date().timeIntervalSince(t2)))s | total: \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            } catch is CancellationError {
                // user pressed cancel — silent exit
            } catch {
                print("STS error: \(error)")
            }
            await MainActor.run { self.resetState() }
        }
    }

    func commitRecording() {
        // Close WS to trigger lastPartial processing — task keeps running
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
        stopMicEngine()
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
        // Activate audio session (watchOS async API unlocks NECP WebSocket policy)
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

        // Gate: silence only counts after ElevenLabs confirms speech (partial_transcript)
        let gate = SpeechGate()

        let targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000, channels: 1, interleaved: false)!
        let silenceNeeded = max(6, Int(0.7 * tapFormat.sampleRate / 4096))
        var silentBufs = 0
        var committed  = false
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buf, _ in
            guard !committed else { return }
            if gate.active, let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[0][i] * ch[0][i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                if rms < 0.012 { silentBufs += 1 } else { silentBufs = 0 }
            }
            let outFrames = AVAudioFrameCount(Double(buf.frameLength) * 16000 / tapFormat.sampleRate)
            guard outFrames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outFrames) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData; return buf
            }
            guard err == nil, let data = Self.toInt16Data(out) else { return }
            let b64 = data.base64EncodedString()
            if silentBufs >= silenceNeeded {
                committed = true
                ws.cancel(with: .normalClosure, reason: nil)
                return
            }
            let msg = #"{"message_type":"input_audio_chunk","audio_base_64":"\#(b64)","commit":false}"#
            ws.send(.string(msg)) { _ in }
        }

        try engine.start()

        // Receive loop
        return try await withTaskCancellationHandler {
            try await self.receiveUntilCommit(ws: ws, gate: gate)
        } onCancel: {
            ws.cancel(with: .normalClosure, reason: nil)
        }
    }

    nonisolated private func receiveUntilCommit(ws: URLSessionWebSocketTask, gate: SpeechGate) async throws -> String? {
        let g = gate
        var lastPartial: String? = nil
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await ws.receive()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                await MainActor.run { self.stopMicEngine() }
                return lastPartial
            }
            guard case .string(let text) = message,
                  let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["message_type"] as? String else { continue }

            print("WS [\(type)]: \(json["text"] ?? "")")

            switch type {
            case "partial_transcript":
                if let t = json["text"] as? String, !t.isEmpty {
                    g.active = true
                    lastPartial = t
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
            userMessage = input
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

        let history = await MainActor.run { chatHistory }
        var messages: [[String: String]] = [["role": "system", "content": systemPrompt]]
        messages.append(contentsOf: history)
        messages.append(["role": "user", "content": userMessage])

        var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(openRouterKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "google/gemini-2.0-flash-001",
            "messages": messages,
            "max_tokens": 80,
            "temperature": 1.1
        ])
        req.timeoutInterval = 30
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let content = ((json?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        let reply = (content ?? "[annoyed] もう。[sighing] しょうがないわね。")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        await MainActor.run {
            chatHistory.append(["role": "user",      "content": userMessage])
            chatHistory.append(["role": "assistant",  "content": reply])
            if chatHistory.count > 12 { chatHistory.removeFirst(2) }
        }
        return reply
    }
}
