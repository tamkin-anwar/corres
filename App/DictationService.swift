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
            errorMessage = String(localized: "Dictation needs microphone and speech recognition access. You can allow it in the Settings app under Corres.")
            return
        }
        guard let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            errorMessage = String(localized: "On-device dictation isn't available for this language yet.")
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
            // The tap runs on the audio thread and the results on Speech's
            // own queue: both made outside the main actor (`Callbacks`), or
            // Swift stops the app the moment the microphone starts.
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0),
                             block: Callbacks.feeding(request))
            engine.prepare()
            try engine.start()
            transcript = ""
            isListening = true
            task = recognizer.recognitionTask(with: request, resultHandler: Callbacks.results { [weak self] text, done in
                guard let self else { return }
                if let text { self.transcript = text }
                if done { self.finish() }
            })
        } catch {
            finish()
            errorMessage = String(localized: "Dictation couldn't start. Try again.")
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

    nonisolated private static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// Callbacks iOS calls off the main thread, made where they carry no
/// main-actor isolation; whatever they hand back reaches the main actor
/// through `onResult`.
private enum Callbacks {
    static func feeding(_ request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        nonisolated(unsafe) let request = request
        return { buffer, _ in request.append(buffer) }
    }

    static func results(_ onResult: @escaping @MainActor (String?, Bool) -> Void)
        -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let text = result?.bestTranscription.formattedString
            let done = error != nil || result?.isFinal == true
            Task { @MainActor in onResult(text, done) }
        }
    }
}
