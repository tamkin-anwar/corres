import AVFoundation
import Observation
import Speech

/// Dictation for Compose, transcribed on this iPhone only
/// (`requiresOnDeviceRecognition`): the audio never leaves the device, the
/// same promise as the rest of Corres's intelligence. Live partial results
/// stream into `transcript` while listening.
@MainActor @Observable
final class DictationService {
    private(set) var isListening = false
    private(set) var transcript = ""
    var errorMessage: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// On-device recognition exists for this language on this iPhone.
    var isSupported: Bool { recognizer?.supportsOnDeviceRecognition == true }

    func start() async {
        guard !isListening else { return }
        guard await Self.authorize() else {
            errorMessage = "Dictation needs microphone and speech recognition access. You can allow it in the Settings app under Corres."
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            errorMessage = "On-device dictation isn't available for this language yet."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            self.request = request
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            transcript = ""
            isListening = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if error != nil || result?.isFinal == true { self.finish() }
                }
            }
        } catch {
            finish()
            errorMessage = "Dictation couldn't start. Please try again."
        }
    }

    /// Stops listening; the final text stays in `transcript`.
    func stop() {
        request?.endAudio()
        finish()
    }

    private func finish() {
        guard isListening || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        isListening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}
