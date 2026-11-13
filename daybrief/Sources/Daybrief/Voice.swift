#if os(iOS)
import SwiftUI
import Speech
import AVFoundation
import DaybriefCore

/// Listens through the microphone and reports what was said.
/// Kept off the main actor: iOS calls back on its own threads.
final class SpeechListener: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    static func allowed() async -> Bool {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    /// Starts listening. `heard` gets the words so far, each time they change.
    func start(heard: @escaping @Sendable (String) -> Void, failed: @escaping @Sendable () -> Void) throws {
        // The iPhone's language; English when that language isn't supported.
        guard let recognizer = SFSpeechRecognizer() ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw BriefError("Speech recognition isn't available right now.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result { heard(result.bestTranscription.formattedString) }
            else if error != nil { failed() }
        }
    }

    func stop() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The sheet behind the microphone button: listen, show what was understood, add it.
struct VoiceSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case listening
        case adding
        case added(AppleSource.Added)
        case failed(String)
    }

    @State private var stage = Stage.listening
    @State private var words = ""
    @State private var listener = SpeechListener()
    @State private var quiet: Task<Void, Never>?
    /// True while the microphone is meant to be on (false once you start typing).
    @State private var micOn = false
    @State private var typed = ""
    @FocusState private var typing: Bool

    /// What will be added: the typed text if there is any, else the spoken words.
    private var current: String {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? words : t
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                switch stage {
                case .listening:
                    Image(systemName: "mic.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.white)
                        .frame(width: 96, height: 96)
                        .background(Circle().fill(micOn ? Color.red : Color.gray))
                        .symbolEffect(.pulse, isActive: micOn)
                    Text(words.isEmpty ? (micOn ? "Say what you need to do" : "Type what you need to do") : words)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(words.isEmpty ? Color.secondary : Color.primary)
                    TextField("Or type it here", text: $typed)
                        .textFieldStyle(.roundedBorder)
                        .focused($typing)
                        .submitLabel(.done)
                        .onSubmit { finish() }
                    if current.isEmpty {
                        Text("For example: “Remind me to hand in the essay on Friday at 8” or “Zajtra o 15:00 zubár”.")
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    } else {
                        preview(SpokenParser.parse(current, now: Date()))
                        Button("Add now") { finish() }.buttonStyle(.borderedProminent)
                    }
                case .adding:
                    ProgressView()
                case .added(let added):
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                    Text("Added to \(added.isEvent ? "Calendar" : "Reminders")").font(.headline)
                    preview(added.task)
                    HStack {
                        Button("Undo", role: .destructive) {
                            model.undo(added)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                        Button("Add another") { listen() }.buttonStyle(.bordered)
                    }
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
                    Text(message).multilineTextAlignment(.center)
                    Button("Try again") { listen() }.buttonStyle(.bordered)
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity)
            .navigationTitle("New task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(stage == .listening ? "Cancel" : "Done") { dismiss() }
                }
            }
            .onAppear { listen() }
            .onChange(of: typing) { _, on in
                // Typing takes over from the microphone.
                if on { stopMic() }
            }
            .onDisappear { stopMic() }
        }
        .presentationDetents([.medium, .large])
    }

    private func preview(_ task: SpokenTask) -> some View {
        VStack(spacing: 4) {
            Text(task.title).font(.headline)
            Text(when(task)).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }

    private func when(_ task: SpokenTask) -> String {
        let kind = task.isEvent ? "Event" : "Reminder"
        guard let date = task.date else { return "\(kind) · no date" }
        let day = date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        return task.hasTime ? "\(kind) · \(day), \(date.formatted(date: .omitted, time: .shortened))" : "\(kind) · \(day)"
    }

    private func stopMic() {
        micOn = false
        quiet?.cancel()
        listener.stop()
    }

    private func listen() {
        words = ""
        typed = ""
        typing = false
        stage = .listening
        Task {
            guard await SpeechListener.allowed() else {
                stage = .failed("Daybrief needs the microphone and speech recognition. Turn both on in Settings → Apps → Daybrief.")
                return
            }
            do {
                try listener.start(heard: { text in
                    Task { @MainActor in heard(text) }
                }, failed: {
                    Task { @MainActor in
                        // Ending without words is the only real failure; with words, add them.
                        if micOn, stage == .listening {
                            if words.isEmpty { fail("I didn't catch that.") } else { finish() }
                        }
                    }
                })
                micOn = true
            } catch {
                fail((error as? BriefError)?.message ?? "The microphone couldn't be started.")
            }
        }
    }

    private func heard(_ text: String) {
        guard micOn, stage == .listening, text != words else { return }
        words = text
        // Two seconds without new words means you're done.
        quiet?.cancel()
        quiet = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { finish() }
        }
    }

    private func fail(_ message: String) {
        stopMic()
        stage = .failed(message)
    }

    private func finish() {
        let text = current
        guard stage == .listening, !text.isEmpty else { return }
        stopMic()
        typing = false
        stage = .adding
        let task = SpokenParser.parse(text, now: Date())
        Task {
            do {
                stage = .added(try await model.add(task))
            } catch {
                stage = .failed((error as? BriefError)?.message ?? error.localizedDescription)
            }
        }
    }
}
#endif
