//
//  ElevenLabsService.swift
//  Plato
//
//  Streaming PCM for low-latency playback; NSObject base for delegate conformance.
//

import Foundation
import AVFoundation


final class ElevenLabsService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate  {
    @Published var isSpeaking: Bool = false
    @Published var isGenerating: Bool = false
    
    private let cfg = ConfigManager.shared
    private let base = "https://api.elevenlabs.io/v1/text-to-speech"
    
    // playback
    private var player: StreamingPlayer?
    private var fallbackSynth: AVSpeechSynthesizer?
    
    private var mp3Player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    
    override init() {
        super.init()
    }
    
    // MARK: - Public
    
    /// Speak text using streaming ElevenLabs TTS when available; fallback to system TTS otherwise.
    /// Speak text (Phase 1 latency test mode: force Apple system TTS; skip ElevenLabs network).
    func speak(_ raw: String) async {
        stopSpeaking()
        let text = Self.cleanText(raw)

        // if streaming is OFF (current state), do blocking George
        if !cfg.useStreamingTTS {
            do {
                try await speakBlockingGeorge(text)
            } catch {
                print("⚠️ George blocking error: \(error) — fallback system TTS.")
                await fallbackSystemTTS(text)
            }
            return
        }

        // streaming path (we’ll finish this later)
        isGenerating = true
        do {
            try await streamPCM(text: text)   // will be replaced w/ MP3 stream decode soon
        } catch {
            print("⚠️ George streaming error: \(error) — fallback system TTS.")
            await fallbackSystemTTS(text)
        }
        isGenerating = false
    }


    
    /// Stop streaming / playback immediately.
    func stopSpeaking() {
        Task { @MainActor in
            playerNode?.stop()
            engine?.stop()
            engine = nil
            playerNode = nil
            isSpeaking = false
        }
    }


    
    var isConfigured: Bool { cfg.hasElevenLabs }
    
    // MARK: - Streaming core
    
    /// Open a streaming ElevenLabs request and feed raw PCM into StreamingPlayer.
    private func streamPCM(text: String) async throws {
        
        // Build request
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)/stream?optimize_streaming_latency=\(cfg.elevenLabsLatencyMode)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Ask for raw PCM container
        req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.6,
                "similarity_boost": 0.8,
                "style": 0.2,
                "use_speaker_boost": true
            ],
            "output_format": "pcm_22050"  // 16-bit LE mono @ 22.05kHz
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        // Perform streaming request (this await runs off-main in URLSession)
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ElevenLabsError.invalidResponse
        }
        
        // Prepare player when stream confirmed
        player = StreamingPlayer()
        isSpeaking = true
        
        // Buffer & schedule in batches to avoid tiny pops
        var pending = Data()
        
        for try await byte in bytes {
            try Task.checkCancellation()
            pending.append(byte)
            
            // schedule when we have enough buffered audio
            if pending.count >= 4096 {
                let send = pending
                pending.removeAll(keepingCapacity: true)
                player?.schedule(send)
                player?.play()
            }
        }

        
        // flush remainder
        if !pending.isEmpty {
            player?.schedule(pending)
            player?.play()
        }
        
        // done
        isSpeaking = false
    }
    
    // MARK: - Stream Request Builder (debug & reuse)
    private func makeStreamRequest(
        _ text: String,
        accept: String = "application/octet-stream",
        outputFormat: String = "pcm_22050"
    ) throws -> URLRequest {
        // ElevenLabs streaming endpoint
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)/stream?optimize_streaming_latency=\(cfg.elevenLabsLatencyMode)")!
        
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(accept, forHTTPHeaderField: "Accept")  // format hint
        
        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.6,
                "similarity_boost": 0.8,
                "style": 0.2,
                "use_speaker_boost": true
            ],
            "output_format": outputFormat
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }
    
    /// Debug helper: open a streaming ElevenLabs request, read the first ~512 bytes,
    /// and print a hex + ASCII dump so we can identify the audio container.
    /// Safe to call even when streaming TTS is disabled in config.
    func debugProbeStreamFormat(
        sampleText: String = "Testing ElevenLabs streaming.",
        accept: String = "application/octet-stream",
        outputFormat: String = "pcm_22050",
        maxBytes: Int = 512
    ) async {
        do {
            // Build request
            let req = try makeStreamRequest(sampleText, accept: accept, outputFormat: outputFormat)
            
            // Execute streaming request
            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            if let http = response as? HTTPURLResponse {
                print("🧪 Probe HTTP status:", http.statusCode)
                print("🧪 Probe Content-Type:", http.value(forHTTPHeaderField: "Content-Type") ?? "nil")
            }
            
            // Capture first N bytes
            var captured = Data()
            var count = 0
            for try await b in bytes {
                captured.append(b)
                count += 1
                if count >= maxBytes { break }
            }
            
            print("🧪 Probe captured \(captured.count) bytes.")
            hexDump(captured)
            identifyFormat(from: captured)
            
        } catch {
            print("🧪 Probe error:", error)
        }
    }

    
    // MARK: - System fallback
    
    private func fallbackSystemTTS(_ text: String) async {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        
        let synth = AVSpeechSynthesizer()
        synth.delegate = self
        fallbackSynth = synth
        
        isSpeaking = true
        synth.speak(utterance)
        
        // We don't await here; delegate callbacks update isSpeaking.
    }
    
    // MARK: - Delegate
    
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.fallbackSynth = nil
        }
    }
    
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.fallbackSynth = nil
        }
    }
    
    // MARK: - Utilities
    
    private static func cleanText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*",  with: "")
            .replacingOccurrences(of: "_",  with: "")
            .replacingOccurrences(of: "`",  with: "")
            .replacingOccurrences(of: "#",  with: "")
            .replacingOccurrences(of: "~",  with: "")
            .replacingOccurrences(of: "\n\n", with: ". ")
            .replacingOccurrences(of: "\n", with: " ")
    }
    
    // MARK: - Debug helpers
    private func hexDump(_ data: Data, bytesPerRow: Int = 16) {
        guard !data.isEmpty else {
            print("🧪 (no data)")
            return
        }
        data.withUnsafeBytes { raw in
            let ptr = raw.bindMemory(to: UInt8.self)
            for row in stride(from: 0, to: data.count, by: bytesPerRow) {
                let end = min(row + bytesPerRow, data.count)
                let slice = ptr[row..<end]
                let hex = slice.map { String(format: "%02X", $0) }.joined(separator: " ")
                let ascii = slice.map { c -> String in
                    (c >= 0x20 && c < 0x7F) ? String(UnicodeScalar(c)) : "."
                }.joined()
                print(String(format: "%04X  %-*s  |%@|",
                             row, bytesPerRow * 3, hex, ascii))
            }
        }
    }

    private func identifyFormat(from data: Data) {
        if data.count >= 4 {
            let prefix = data.prefix(4)
            if prefix == Data([0x52, 0x49, 0x46, 0x46]) { // "RIFF"
                print("🧪 Guess: WAV container (RIFF).")
                return
            }
            if prefix == Data([0x49, 0x44, 0x33]) { // "ID3" MP3 tag
                print("🧪 Guess: MP3 (ID3 header).")
                return
            }
            if prefix[0] == 0xFF && (prefix[1] & 0xE0) == 0xE0 {
                print("🧪 Guess: MP3 frame sync (no ID3).")
                return
            }
        }
        // Check for long runs of low-magnitude bytes (likely PCM)
        let avg = data.reduce(0.0) { $0 + Double($1) } / Double(max(data.count, 1))
        if avg < 5 {  // crude heuristic
            print("🧪 Guess: raw PCM (low magnitude).")
        } else {
            print("🧪 Guess: unknown / compressed.")
        }
    }
    
    // MARK: - Blocking George playback (MP3)
    private func speakBlockingGeorge(_ text: String) async throws {
        //------------------------------------------
        // 1) Make sure we’re in a speaker-friendly
        //    session category before we play.
        //------------------------------------------
        await MainActor.run {
            let s = AVAudioSession.sharedInstance()
            try? s.setCategory(.playAndRecord,
                               mode: .voiceChat,
                               options: [.defaultToSpeaker, .allowBluetooth])
            try? s.setActive(true)
            try? s.overrideOutputAudioPort(.speaker)
        }

        //------------------------------------------
        // 2) Build ElevenLabs request (MP3).
        //------------------------------------------
        let url = URL(string: "\(base)/\(cfg.elevenLabsVoiceId)")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(cfg.elevenLabsAPIKey, forHTTPHeaderField: "xi-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "text": text,
            "model_id": "eleven_turbo_v2_5",
            "voice_settings": [
                "stability": 0.6,
                "similarity_boost": 0.8,
                "style": 0.2,
                "use_speaker_boost": true
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        //------------------------------------------
        // 3) Fetch audio data.
        //------------------------------------------
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ElevenLabsError.invalidResponse
        }

        //------------------------------------------
        // 4) Play via AVAudioPlayer.
        //------------------------------------------
        await playMP3(data)
    }


    @MainActor
    private func playMP3(_ data: Data) async {
        // Dispose old graph
        engine?.stop()
        engine = nil
        playerNode = nil

        // Build graph (+12 dB EQ)
        let eng  = AVAudioEngine()
        let node = AVAudioPlayerNode()
        let eq   = AVAudioUnitEQ(numberOfBands: 1)
        eq.globalGain = 12.0

        eng.attach(node)
        eng.attach(eq)
        eng.connect(node, to: eq, format: nil)
        eng.connect(eq,  to: eng.mainMixerNode, format: nil)
        try? eng.start()

        engine     = eng
        playerNode = node

        // Temp MP3 file
        let tmpURL = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("george-\(UUID().uuidString).mp3")
        guard (try? data.write(to: tmpURL)) != nil,
              let file = try? AVAudioFile(forReading: tmpURL) else {
            print("George: temp-file or AVAudioFile failure"); return
        }

        // --------- Playback with proper STT pause/resume ---------
        // ----- PAUSE mic *always* -----
        ContentView.sharedSpeechRecognizer?.stopRecording()
        print("🎤 PAUSE STT")

        print("🔊 node.play() — engine running:", eng.isRunning)
        node.play()                                 // start engine clocks
        await node.scheduleFile(file, at: nil)      // ⏳ suspend until finished
        print("🟢 playback DONE")
        try? FileManager.default.removeItem(at: tmpURL)

        isSpeaking = false
        eng.stop()
        engine = nil
        playerNode = nil

        ContentView.sharedSpeechRecognizer?.startRecording()
        print("🎤 RESUME STT")
    }





    
    // MARK: - AVAudioPlayerDelegate
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // Reset speaking state on main thread
        Task { @MainActor in
            if self.mp3Player === player { self.mp3Player = nil }
            self.isSpeaking = false
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor in
            if self.mp3Player === player { self.mp3Player = nil }
            self.isSpeaking = false
        }
        if let error { print("George MP3 decode error: \(error)") }
    }

    

}

// MARK: - Error
enum ElevenLabsError: Error {
    case invalidResponse
}

