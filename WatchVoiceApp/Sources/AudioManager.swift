import Foundation
import AVFoundation

private final class CommitSignal: @unchecked Sendable {
    private var cont: CheckedContinuation<Void, Never>?
    private var fired = false
    func set(_ c: CheckedContinuation<Void, Never>) { cont = c }
    func commit() { guard !fired else { return }; fired = true; cont?.resume(); cont = nil }
}

@MainActor
class RemiManager: ObservableObject {
    @Published var isRecording = false
    @Published var isLoading  = false
    @Published var isPlaying  = false
    @Published var partialText: String?
    @Published var currentLine: String?

    private let xaiKey      = Secrets.xaiKey
    private let fishApiKey  = Secrets.fishApiKey
    private let fishVoiceId = Secrets.fishVoiceId

    private var audioEngine:   AVAudioEngine?
    private var playerNode:    AVAudioPlayerNode?
    private var recordEngine:  AVAudioEngine?
    private var commitSignal:  CommitSignal?
    private var sttTask:       Task<Void, Never>?
    private var chatHistory:   [[String: String]] = []

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

    // MARK: - Audio session

    private func activateAudioSession() async throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.activate(options: []) { _, error in
                if let e = error { cont.resume(throwing: e) } else { cont.resume() }
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

        sttTask = Task(priority: .userInitiated) { [weak self] in
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
            } catch {
                print("pipeline error: \(error)")
            }
            await MainActor.run { self.resetState() }
        }
    }

    func commitRecording() {
        commitSignal?.commit()
        commitSignal = nil
        stopMicEngine()
    }

    func cancelRecording() {
        sttTask?.cancel()
        sttTask = nil
        commitSignal?.commit()
        commitSignal = nil
        stopMicEngine()
        resetState()
    }

    // MARK: - Grok REST STT

    nonisolated private func runSTTSession() async throws -> String? {
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

        let signal = CommitSignal()
        await MainActor.run { self.commitSignal = signal }

        let targetFmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: 16000, channels: 1, interleaved: false)!

        final class Buf: @unchecked Sendable { var data = Data() }
        let accumulated = Buf()

        let silenceNeeded = max(10, Int(1.2 * tapFormat.sampleRate / 4096))
        var silentBufs = 0
        var speechStarted = false

        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { buf, _ in
            let outFrames = AVAudioFrameCount(Double(buf.frameLength) * 16000 / tapFormat.sampleRate)
            guard outFrames > 0,
                  let out = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: outFrames) else { return }
            var err: NSError?
            converter.convert(to: out, error: &err) { _, status in
                status.pointee = .haveData; return buf
            }
            guard err == nil, let pcm = Self.toInt16Data(out) else { return }
            accumulated.data.append(pcm)

            if let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[0][i] * ch[0][i] }
                let rms = sqrt(sum / Float(max(n, 1)))
                if rms > 0.015 { speechStarted = true; silentBufs = 0 }
                else if speechStarted { silentBufs += 1 }
                if silentBufs >= silenceNeeded { signal.commit() }
            }
        }

        try engine.start()

        try await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                signal.set(cont)
            }
        } onCancel: {
            signal.commit()
        }

        try Task.checkCancellation()
        await MainActor.run { self.stopMicEngine() }

        guard accumulated.data.count > 3200 else { return nil }
        return try await postGrokSTT(accumulated.data)
    }

    nonisolated private func postGrokSTT(_ pcmData: Data) async throws -> String? {
        let boundary = "B\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(xaiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30

        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }
        func field(_ name: String, _ value: String) {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        let wavData = Self.makeWAV(pcm: pcmData)
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")
        field("language", "ja")
        append("--\(boundary)--\r\n")
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            print("Grok STT error: \(String(data: data, encoding: .utf8) ?? "")")
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return json?["text"] as? String
    }

    @MainActor
    private func stopMicEngine() {
        recordEngine?.inputNode.removeTap(onBus: 0)
        recordEngine?.stop()
        recordEngine = nil
    }

    nonisolated private static func makeWAV(pcm: Data, sampleRate: UInt32 = 16000, channels: UInt16 = 1) -> Data {
        let dataSize = UInt32(pcm.count)
        var h = Data(count: 44)
        func u32le(_ offset: Int, _ v: UInt32) {
            h[offset]=UInt8(v&0xFF); h[offset+1]=UInt8((v>>8)&0xFF)
            h[offset+2]=UInt8((v>>16)&0xFF); h[offset+3]=UInt8((v>>24)&0xFF)
        }
        func u16le(_ offset: Int, _ v: UInt16) { h[offset]=UInt8(v&0xFF); h[offset+1]=UInt8((v>>8)&0xFF) }
        h[0]=0x52; h[1]=0x49; h[2]=0x46; h[3]=0x46          // "RIFF"
        u32le(4, dataSize + 36)                               // ChunkSize
        h[8]=0x57; h[9]=0x41; h[10]=0x56; h[11]=0x45        // "WAVE"
        h[12]=0x66; h[13]=0x6D; h[14]=0x74; h[15]=0x20      // "fmt "
        u32le(16, 16)                                         // Subchunk1Size
        u16le(20, 1)                                          // AudioFormat PCM
        u16le(22, channels)
        u32le(24, sampleRate)
        u32le(28, sampleRate * UInt32(channels) * 2)          // ByteRate
        u16le(32, channels * 2)                               // BlockAlign
        u16le(34, 16)                                         // BitsPerSample
        h[36]=0x64; h[37]=0x61; h[38]=0x74; h[39]=0x61      // "data"
        u32le(40, dataSize)
        return h + pcm
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
                    if pending.count >= 5 {
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

        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(xaiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "grok-3",
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
