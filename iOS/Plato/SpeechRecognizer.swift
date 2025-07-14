//
//  SpeechRecognizer.swift
//  Plato
//
//  Created by Daniel Riaz on 7/13/25.
//

import Foundation
import Speech
import AVFoundation

class SpeechRecognizer: ObservableObject {
    @Published var isRecording = false
    @Published var transcribedText = ""
    
    private var audioEngine = AVAudioEngine()
    private var speechRecognizer = SFSpeechRecognizer()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    
    func requestPermissions() {
        // Request speech recognition permission
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                print("Speech recognition permission: \(status)")
            }
        }
        
        // Request microphone permission (iOS 17+ compatible)
        if #available(iOS 17.0, *) {
            AVAudioApplication.requestRecordPermission { granted in
                DispatchQueue.main.async {
                    print("Microphone permission: \(granted)")
                }
            }
        } else {
            // Fallback for iOS 16 and earlier
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                DispatchQueue.main.async {
                    print("Microphone permission: \(granted)")
                }
            }
        }
    }
    
    func startRecording() {
        guard !isRecording else { return }
        
        do {
            // Configure audio session
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            
            // Create recognition request
            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest = recognitionRequest else {
                print("Unable to create recognition request")
                return
            }
            recognitionRequest.shouldReportPartialResults = true
            
            // Start recognition task
            recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
                DispatchQueue.main.async {
                    if let result = result {
                        self.transcribedText = result.bestTranscription.formattedString
                        print("Transcribed: \(self.transcribedText)")
                    }
                    
                    if let error = error {
                        print("Recognition error: \(error)")
                        self.stopRecording()
                    }
                    
                    if result?.isFinal == true {
                        self.stopRecording()
                    }
                }
            }
            
            // Start audio engine
            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
                recognitionRequest.append(buffer)
            }
            
            audioEngine.prepare()
            try audioEngine.start()
            
            isRecording = true
            transcribedText = ""
            print("Started recording...")
            
        } catch {
            print("Recording setup error: \(error)")
            stopRecording()
        }
    }
    
    func stopRecording() {
        guard isRecording else { return }
        
        print("Stopping recording...")
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        
        isRecording = false
        
        // Deactivate audio session
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("Error deactivating audio session: \(error)")
        }
    }
}
