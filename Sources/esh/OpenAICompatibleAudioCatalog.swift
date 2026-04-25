import EshCore
import TTSMLX

enum OpenAICompatibleAudioCatalog {
    static func ttsModels() throws -> [OpenAIAudioModel] {
        TTSMLX.supportedModels.map { model in
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
