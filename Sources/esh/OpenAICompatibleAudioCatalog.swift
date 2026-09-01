import EshCore
import TTSMLX

enum OpenAICompatibleAudioCatalog {
    static func ttsModels() throws -> [OpenAIAudioModel] {
        // Never advertise a model that cannot actually run (e.g. Marvis' RoPE-key load failure) —
        // the API must not present a broken model as usable.
        TTSMLX.supportedModels
            .filter { !AudioSpeechGenerator.isKnownIncompatibleTTSModel($0.id) }
            .map { model in
            OpenAIAudioModel(
                id: model.id,
                displayName: model.displayName,
                voices: model.suggestedVoices.map { voice in
                    OpenAIAudioModel.Voice(id: voice.identifier, displayName: voice.identifier)
                },
                languages: model.supportedLanguages.map { language in
                    OpenAIAudioModel.Language(id: language.identifier, displayName: language.identifier)
                }
            )
        }
    }
}
