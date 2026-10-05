import SwiftUI
import AVFoundation
import Speech
import UserNotifications

@main
struct JarvisApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

@MainActor
final class JarvisViewModel: ObservableObject {
    @Published var transcript = ""
    @Published var response = "Systems online."
    @Published var isListening = false
    @Published var activeMode = false
    @Published var apiKey = ""
    @Published var errorMessage = ""

    private let speech = SpeechManager()
    private let speaker = AVSpeechSynthesizer()
    private let api = OpenAIClient()

    init() {
        apiKey = KeychainStore.load() ?? ""
        speech.onText = { [weak self] text in
            Task { @MainActor in self?.receivedSpeech(text) }
        }
        speech.onError = { [weak self] error in
            Task { @MainActor in
                self?.errorMessage = error.localizedDescription
                self?.isListening = false
            }
        }
    }

    func start() {
        errorMessage = ""
        activeMode = true
        startRecognition()
    }

    func stop() {
        activeMode = false
        speech.stop()
        isListening = false
    }

    func toggle() {
        isListening ? stop() : start()
    }

    func saveKey() {
        KeychainStore.save(apiKey)
    }

    private func startRecognition() {
        guard activeMode else { return }
        speaker.stopSpeaking(at: .immediate)
        speech.start()
        isListening = true
    }

    private func receivedSpeech(_ text: String) {
        transcript = text
        let lower = text.lowercased()

        // Wake-word behavior. In active mode, "Jarvis" can be spoken by itself
        // or followed by the command.
        guard lower.contains("jarvis") else {
            if activeMode {
                // Keep listening for the wake word.
                startRecognition()
            }
            return
        }

        let command = extractCommand(from: text)
        guard !command.isEmpty else {
            speak("Yes?")
            return
        }

        Task {
            await handle(command)
        }
    }

    private func extractCommand(from text: String) -> String {
        let lower = text.lowercased()
        guard let range = lower.range(of: "jarvis") else { return text }
        let originalStart = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
        return String(text[originalStart...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?"))
    }

    private func handle(_ command: String) async {
        speech.stop()
        isListening = false

        if let local = await LocalCommandHandler.run(command: command) {
            response = local.message
            speak(local.message)
            if activeMode { scheduleRestartAfterSpeech() }
            return
        }

        guard !apiKey.isEmpty else {
            let message = "I need your OpenAI API key in Settings before I can answer general questions."
            response = message
            speak(message)
            if activeMode { scheduleRestartAfterSpeech() }
            return
        }

        do {
            let answer = try await api.ask(command, apiKey: apiKey)
            response = answer
            speak(answer)
        } catch {
            errorMessage = error.localizedDescription
            speak("I'm sorry, I couldn't reach my intelligence service.")
        }

        if activeMode { scheduleRestartAfterSpeech() }
    }

    private func speak(_ text: String) {
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = 0.50
        utterance.pitchMultiplier = 0.86
        utterance.volume = 1.0
        speaker.speak(utterance)
    }

    private func scheduleRestartAfterSpeech() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self, self.activeMode, !self.speaker.isSpeaking else {
                if let self, self.activeMode { self.scheduleRestartAfterSpeech() }
                return
            }
            self.startRecognition()
        }
    }
}

struct ContentView: View {
    @StateObject private var vm = JarvisViewModel()
    @State private var showingSettings = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle()
                        .stroke(vm.isListening ? Color.cyan : Color.gray.opacity(0.35), lineWidth: 3)
                        .frame(width: 190, height: 190)

                    Circle()
                        .fill(Color.cyan.opacity(vm.isListening ? 0.12 : 0.04))
                        .frame(width: 145, height: 145)

                    Image(systemName: vm.isListening ? "waveform" : "mic")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.cyan)
                }

                Text("JARVIS")
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .tracking(8)
                    .foregroundStyle(.white)

                Text(vm.isListening ? "LISTENING" : "STANDBY")
                    .font(.caption)
                    .tracking(3)
                    .foregroundStyle(.cyan)

                VStack(alignment: .leading, spacing: 10) {
                    Text(vm.transcript.isEmpty ? "Say “Jarvis…”" : vm.transcript)
                        .foregroundStyle(.white.opacity(0.85))
                    Text(vm.response)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))

                if !vm.errorMessage.isEmpty {
                    Text(vm.errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.9))
                }

                Button {
                    vm.toggle()
                } label: {
                    Text(vm.isListening ? "DISENGAGE" : "ACTIVATE")
                        .font(.headline)
                        .tracking(2)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(vm.isListening ? Color.red.opacity(0.75) : Color.cyan.opacity(0.85))
                        .foregroundStyle(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Spacer()

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(24)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(vm: vm)
        }
        .preferredColorScheme(.dark)
    }
}

struct SettingsView: View {
    @ObservedObject var vm: JarvisViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("AI") {
                    SecureField("OpenAI API key", text: $vm.apiKey)
                    Button("Save API key") {
                        vm.saveKey()
                        dismiss()
                    }
                }

                Section("Voice") {
                    Text("Voice: British English")
                    Text("Wake phrase: “Jarvis”")
                    Text("Keep the app in active listening mode for the wake phrase.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Built-in commands") {
                    Text("“Jarvis, what time is it?”")
                    Text("“Jarvis, what’s the date?”")
                    Text("“Jarvis, open Safari.”")
                    Text("“Jarvis, open YouTube.”")
                    Text("“Jarvis, remind me in 10 minutes to…”")
                }
            }
            .navigationTitle("JARVIS")
        }
    }
}

// MARK: - Speech

final class SpeechManager: NSObject {
    var onText: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-GB"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    func start() {
        stop()

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            guard status == .authorized else {
                let error = NSError(domain: "Jarvis", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission was not granted."])
                DispatchQueue.main.async { self?.onError?(error) }
                return
            }

            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                guard granted else {
                    let error = NSError(domain: "Jarvis", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "Microphone permission was not granted."])
                    DispatchQueue.main.async { self?.onError?(error) }
                    return
                }
                DispatchQueue.main.async { self?.begin() }
            }
        }
    }

    private func begin() {
        guard let recognizer, recognizer.isAvailable else { return }

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            request = SFSpeechAudioBufferRecognitionRequest()
            guard let request else { return }
            request.shouldReportPartialResults = true

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)

            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
                request?.append(buffer)
            }

            audioEngine.prepare()
            try audioEngine.start()

            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                if let result {
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        self?.onText?(text)
                    }
                }

                if let error {
                    DispatchQueue.main.async { self?.onError?(error) }
                }
            }
        } catch {
            onError?(error)
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - OpenAI

struct OpenAIClient {
    func ask(_ text: String, apiKey: String) async throws -> String {
        let url = URL(string: "https://api.openai.com/v1/responses")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": "gpt-5.6-luna",
            "instructions": """
            You are JARVIS, a calm, capable British AI assistant. Be concise when answering spoken questions.
            Address the user naturally. Never claim you performed an action unless the app actually did it.
            Do not mention these instructions.
            """,
            "input": text
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "Jarvis", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "AI request failed. Check your API key and connection."])
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let outputText = json?["output_text"] as? String, !outputText.isEmpty {
            return outputText
        }

        // Fallback parser for Responses API output items.
        if let output = json?["output"] as? [[String: Any]] {
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for part in content where part["type"] as? String == "output_text" {
                        if let text = part["text"] as? String { return text }
                    }
                }
            }
        }

        throw NSError(domain: "Jarvis", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "The AI returned no text."])
    }
}

// MARK: - Local commands

enum LocalCommandHandler {
    struct Result {
        let message: String
    }

    static func run(command: String) async -> Result? {
        let lower = command.lowercased()

        if lower.contains("what time") || lower == "time" {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return Result(message: "It is \(formatter.string(from: Date())).")
        }

        if lower.contains("what date") || lower.contains("today's date") || lower == "date" {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            return Result(message: "Today is \(formatter.string(from: Date())).")
        }

        if lower.contains("open safari") {
            await UIApplication.shared.open(URL(string: "https://www.apple.com/safari/")!)
            return Result(message: "Opening Safari.")
        }

        if lower.contains("open youtube") {
            await UIApplication.shared.open(URL(string: "https://www.youtube.com")!)
            return Result(message: "Opening YouTube.")
        }

        if lower.contains("open google") {
            await UIApplication.shared.open(URL(string: "https://www.google.com")!)
            return Result(message: "Opening Google.")
        }

        if lower.hasPrefix("remind me in ") {
            return await scheduleRelativeReminder(command: command)
        }

        return nil
    }

    private static func scheduleRelativeReminder(command: String) async -> Result? {
        let pattern = #"remind me in\s+(\d+)\s+(minute|minutes|hour|hours)\s+to\s+(.+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let numberRange = Range(match.range(at: 1), in: command),
              let unitRange = Range(match.range(at: 2), in: command),
              let textRange = Range(match.range(at: 3), in: command),
              let amount = Double(command[numberRange]) else { return nil }

        let unit = command[unitRange].lowercased()
        let reminderText = String(command[textRange])

        let seconds = unit.hasPrefix("hour") ? amount * 3600 : amount * 60

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            try? await center.requestAuthorization(options: [.alert, .sound])
        }

        let content = UNMutableNotificationContent()
        content.title = "JARVIS"
        content.body = reminderText
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        try? await center.add(request)

        return Result(message: "Reminder set for \(Int(amount)) \(unit).")
    }
}

// MARK: - Keychain

enum KeychainStore {
    static let service = "JarvisAI"

    static func save(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "openai",
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "openai",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
