import Foundation

struct MealFingerprintAnalysis {
    let fingerprint: MealFingerprint
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

struct GeneratedExerciseImage {
    let imageData: Data
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

struct ExerciseMuscleClassification {
    let primary: [MuscleGroup]
    let secondary: [MuscleGroup]
    let model: String
    let inputTokens: Int
    let outputTokens: Int
    let costUSD: Double
}

enum OpenRouterError: LocalizedError {
    case missingAPIKey
    case consentRequired
    case http(Int, String)
    case malformedResponse(String)
    case noContent

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OpenRouter API key not set. Add it in Settings."
        case .consentRequired:
            return "Sharing with AI is off. Allow it in Settings to use AI features."
        case .http(let code, let body):
            return "OpenRouter \(code): \(body)"
        case .malformedResponse(let m):
            return "Malformed response: \(m)"
        case .noContent:
            return "Model returned an empty response."
        }
    }
}

@Observable
final class OpenRouterClient {
    var lastError: String?

    /// The user's permission to send data to OpenRouter. Every request checks it.
    let consent: AIDataConsent

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let apiKeyProvider: () -> String?

    init(
        consent: AIDataConsent = .shared,
        session: URLSession = .shared,
        apiKeyProvider: @escaping () -> String? = { Keychain.get(.openRouterAPIKey) }
    ) {
        self.consent = consent
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    var hasAPIKey: Bool { apiKeyProvider()?.isEmpty == false }
    /// Always OpenRouter's Auto Router — it picks the model per request.
    let model = HealthThresholds.OpenRouter.autoModel

    func setAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            Keychain.delete(.openRouterAPIKey)
        } else {
            Keychain.set(trimmed, for: .openRouterAPIKey)
        }
    }

    // MARK: - Request

    private struct ChatResponse {
        let message: [String: Any]
        let model: String
        let inputTokens: Int
        let outputTokens: Int
        let costUSD: Double
    }

    /// The only place that talks to OpenRouter. Refuses to send anything
    /// without an API key or without the user's AI-sharing consent.
    private func complete(_ body: [String: Any]) async throws -> ChatResponse {
        guard let key = apiKeyProvider(), !key.isEmpty else {
            throw OpenRouterError.missingAPIKey
        }
        guard consent.isGranted else {
            throw OpenRouterError.consentRequired
        }

        var request = URLRequest(url: HealthThresholds.OpenRouter.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)",                         forHTTPHeaderField: "Authorization")
        request.setValue("application/json",                       forHTTPHeaderField: "Content-Type")
        request.setValue(HealthThresholds.OpenRouter.httpReferer,  forHTTPHeaderField: "HTTP-Referer")
        request.setValue(HealthThresholds.OpenRouter.appTitle,     forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenRouterError.malformedResponse("No HTTPURLResponse")
        }
        if !(200...299).contains(http.statusCode) {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw OpenRouterError.http(http.statusCode, bodyText)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenRouterError.malformedResponse("Top-level JSON")
        }
        let usage = json["usage"] as? [String: Any] ?? [:]

        guard
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let message = first["message"] as? [String: Any]
        else {
            throw OpenRouterError.malformedResponse("choices/message")
        }

        return ChatResponse(
            message: message,
            model: (json["model"] as? String) ?? model,
            inputTokens: (usage["prompt_tokens"] as? Int) ?? 0,
            outputTokens: (usage["completion_tokens"] as? Int) ?? 0,
            costUSD: reportedCost(usage)
        )
    }

    private func messageText(_ message: [String: Any]) -> String {
        if let s = message["content"] as? String { return s }
        if let arr = message["content"] as? [[String: Any]] {
            return arr.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    // MARK: - Fingerprint analysis (vision)

    func analyzeMealFingerprint(imageJPEG: Data) async throws -> MealFingerprintAnalysis {
        let b64 = imageJPEG.base64EncodedString()
        let content: [[String: Any]] = [
            ["type": "text", "text": userPrompt],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(b64)"]],
        ]

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": content],
            ],
            "response_format": ["type": "json_object"],
            // Allergens and up to 15 ingredient names add roughly 200 output tokens.
            "max_tokens": 900,
            "temperature": 0.1,
        ]

        let response = try await complete(body)
        let contentString = messageText(response.message)
        guard !contentString.isEmpty else { throw OpenRouterError.noContent }

        let parsed = try Self.parseFingerprint(contentString)
        return MealFingerprintAnalysis(
            fingerprint: parsed,
            model: response.model,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            costUSD: response.costUSD
        )
    }

    // MARK: - Exercise icon image generation

    func generateExerciseImage(exerciseName: String) async throws -> GeneratedExerciseImage {
        let prompt = """
        Generate an exercise-diagram illustration for the strength/fitness exercise: "\(exerciseName)", in the style used by professional gym exercise guides.
        Style requirements (apply to every image so the icon set looks uniform):
        - A smooth, featureless grey 3D mannequin figure (like a posable artist's dummy / 3D stickman), NOT a detailed skin-stripped anatomical body — no visible muscle fibers, tendons, or dissection detail
        - The figure is shown mid-repetition, from whichever side/angle best reveals the movement
        - Highlight ONLY the specific muscle actually worked by this exercise in vivid red — a single localized region, not the whole limb, not the whole body part, and never the entire figure. The rest of the mannequin stays plain grey
        - Any gym equipment (machine, bench, bar, dumbbells) rendered as simple light-grey/white 3D geometry with minimal detail
        - Plain flat white background, even flat lighting, NO shadows, NO reflections, NO gradients, NO lighting effects
        - Subject centered with generous padding, square format
        - No text, no labels, no logos, no watermarks, no brand names
        - Consistent mannequin style and proportions across every exercise so the full icon set looks like one cohesive reference set
        """

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt],
            ],
            "modalities": ["image", "text"],
        ]

        let response = try await complete(body)

        guard let dataURL = extractImageDataURL(from: response.message) else {
            throw OpenRouterError.malformedResponse("No image in response")
        }
        guard let imageData = decodeDataURL(dataURL) else {
            throw OpenRouterError.malformedResponse("Image data URL decode")
        }

        return GeneratedExerciseImage(
            imageData: imageData,
            model: response.model,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            costUSD: response.costUSD
        )
    }

    private func extractImageDataURL(from message: [String: Any]) -> String? {
        if let images = message["images"] as? [[String: Any]] {
            for img in images {
                if let urlObj = img["image_url"] as? [String: Any], let url = urlObj["url"] as? String {
                    return url
                }
                if let url = img["url"] as? String { return url }
            }
        }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if let urlObj = part["image_url"] as? [String: Any], let url = urlObj["url"] as? String {
                    return url
                }
            }
        }
        return nil
    }

    private func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        let b64 = String(dataURL[dataURL.index(after: comma)...])
        return Data(base64Encoded: b64) ?? Data(base64Encoded: b64, options: .ignoreUnknownCharacters)
    }

    // MARK: - Exercise muscle-group classification (text)

    /// Ask the chat model which muscle groups an exercise trains, constrained to
    /// the fixed `MuscleGroup` vocabulary. A cheap text call (~a few hundred
    /// tokens) fired once per exercise — deterministic buckets, no manual tagging.
    func classifyExerciseMuscles(exerciseName: String) async throws -> ExerciseMuscleClassification {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": muscleClassifierSystemPrompt],
                ["role": "user",   "content": "Exercise: \"\(exerciseName)\". Return the JSON object."],
            ],
            "response_format": ["type": "json_object"],
            "max_tokens": 200,
            "temperature": 0.0,
        ]

        let response = try await complete(body)
        let contentString = messageText(response.message)
        guard !contentString.isEmpty else { throw OpenRouterError.noContent }

        let (primary, secondary) = try parseMuscleClassification(contentString)
        return ExerciseMuscleClassification(
            primary: primary,
            secondary: secondary,
            model: response.model,
            inputTokens: response.inputTokens,
            outputTokens: response.outputTokens,
            costUSD: response.costUSD
        )
    }

    /// Parse `{ "primary": [...], "secondary": [...] }`, map to the fixed
    /// vocabulary (dropping anything unrecognized), dedupe, and ensure a muscle
    /// never appears in both lists (primary wins).
    private func parseMuscleClassification(_ raw: String) throws -> (primary: [MuscleGroup], secondary: [MuscleGroup]) {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw OpenRouterError.malformedResponse("muscle JSON: \(cleaned.prefix(200))")
        }

        func groups(_ keyValue: Any?) -> [MuscleGroup] {
            let strings = (keyValue as? [String]) ?? []
            var seen = Set<MuscleGroup>()
            var out: [MuscleGroup] = []
            for s in strings {
                guard let g = MuscleGroup.from(loose: s), !seen.contains(g) else { continue }
                seen.insert(g)
                out.append(g)
            }
            return out
        }

        let primary = groups(obj["primary"])
        let primarySet = Set(primary)
        let secondary = groups(obj["secondary"]).filter { !primarySet.contains($0) }
        return (primary, secondary)
    }

    // MARK: - Cost

    /// OpenRouter reports the actual charge (USD credits) in `usage.cost`, priced
    /// for whichever model the Auto Router picked. Missing → 0.
    private func reportedCost(_ usage: [String: Any]) -> Double {
        (usage["cost"] as? NSNumber)?.doubleValue ?? 0
    }

    // MARK: - Parsing

    /// Decodes the model's JSON. Allergens outside the EU list are dropped and
    /// ingredient names trimmed, deduplicated and capped at 15.
    static func parseFingerprint(_ raw: String) throws -> MealFingerprint {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8) else {
            throw OpenRouterError.malformedResponse("UTF-8 encoding")
        }
        do {
            let decoder = JSONDecoder()
            var fingerprint = try decoder.decode(MealFingerprint.self, from: data)
            fingerprint.allergens = fingerprint.allergens.map { EUAllergen.parse($0).map(\.rawValue) }
            fingerprint.ingredients = fingerprint.ingredients.map(cleanedIngredientNames)
            return fingerprint
        } catch {
            throw OpenRouterError.malformedResponse("JSON decode: \(error.localizedDescription)\nRaw: \(cleaned.prefix(400))")
        }
    }

    private static func cleanedIngredientNames(_ names: [String]) -> [String] {
        var out: [String] = []
        for name in names {
            let trimmed = IngredientTaxonomy.normalize(name)
            guard !trimmed.isEmpty, !out.contains(trimmed) else { continue }
            out.append(trimmed)
        }
        return Array(out.prefix(15))
    }

    // MARK: - Prompts

    private var systemPrompt: String {
        let allergenIDs = EUAllergen.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: ", ")
        return """
        You are a meal photo classifier for a longevity app. Given a photo, return a JSON object describing the meal in terms of food categories, plant ingredients, and macro estimates.

        Schema (return only this JSON object, no markdown, no prose):
        {
          "title": <string>,
          "items": [ { "category": <category>, "plateFraction": <0.0..1.0> }, ... ],
          "plantIngredients": [ <string>, ... ],
          "aiNotes": <string|null>,
          "confidence": "low"|"medium"|"high",
          "estimatedKcalPer100g": <number|null>,
          "proteinPer100g": <number|null>,
          "carbsPer100g": <number|null>,
          "fatPer100g": <number|null>,
          "fiberPer100g": <number|null>,
          "typicalServingGrams": <number|null>,
          "allergens": [ <allergen>, ... ],
          "ingredients": [ <string>, ... ]
        }

        Allowed category values (use exactly these strings):
        - leafyGreens     — spinach, kale, lettuce, arugula, chard, etc.
        - cruciferous     — broccoli, cauliflower, cabbage, brussels sprouts
        - otherVeg        — peppers, tomato, carrot, mushrooms, zucchini, onion, etc.
        - fruit           — any whole fruit, fresh or dried
        - legumes         — beans, lentils, chickpeas, peas, tofu, edamame
        - wholeGrains     — oats, brown rice, quinoa, whole wheat, barley
        - refinedCarbs    — white bread, white rice, regular pasta, croissants, pastries
        - nutsAndSeeds    — almonds, walnuts, flax, chia, sesame, etc.
        - omega3Source    — oily fish (salmon, sardines, mackerel, herring, trout), or substantial walnuts/flax/chia/algae
        - leanProtein     — chicken, eggs, white fish, tofu, low-fat dairy protein
        - redMeat         — beef, pork, lamb (unprocessed)
        - processedMeat   — sausage, bacon, ham, salami, hot dog, deli meats
        - dairyOrAlt      — milk, cheese, plain yogurt, plant milks (excluding fermented)
        - fermented       — yogurt with live cultures, kefir, kimchi, sauerkraut, miso, kombucha
        - ultraProcessed  — packaged snacks, chips, fast food, instant noodles, soda, candy
        - fried           — deep-fried foods regardless of base
        - sugaryDrinks    — sodas, fruit juice, sweetened drinks

        Rules:
        - title is a short human-readable meal name (2–6 words), e.g. "Grilled salmon with rice & broccoli" or "Chicken caesar salad". No emojis, no trailing punctuation.
        - A single food may belong to multiple categories (e.g., fried chicken → leanProtein AND fried; salmon → leanProtein AND omega3Source).
        - plateFraction is the visual fraction of the plate this category occupies. The sum across all items should be ≤ 1.0; small overlaps are fine.
        - plantIngredients is a short list of distinct *plant* ingredient names visible in the meal (e.g. ["kale","tomato","lentils","walnuts"]). Use simple lowercase singular names. Do not include animal products. Empty list is fine.
        - estimatedKcalPer100g, proteinPer100g, carbsPer100g, fatPer100g: Estimate macronutrients per 100 g of the dish as typically prepared, using your knowledge of standard recipes for the identified dish. If the dish is too ambiguous to estimate reliably, return null for all four fields.
        - fiberPer100g: Estimate dietary fibre per 100 g of the dish the same way. Return null when the macro fields are null.
        - typicalServingGrams: Your best-guess typical serving weight in grams for this dish (e.g. a restaurant plate of pasta ≈ 450 g, a side salad ≈ 150 g, a full meal salad ≈ 350 g). Return null if genuinely uncertain.
        - allergens: use only these exact strings: \(allergenIDs). List an allergen only when it is visible or part of the standard recipe of the dish you identified (e.g. pasta → "en:gluten", cheese → "en:milk"). Never list one as a precaution. If unsure, omit it. Empty list is fine.
        - ingredients: the main and standard-recipe ingredients of the dish, at most 15, plant and animal alike. Use plain English, singular, lowercase names as in the Open Food Facts ingredient taxonomy, e.g. "onion", "garlic", "wheat flour", "milk", "butter". Empty list is fine.
        - Never claim a free-from property (lactose-free, gluten-free, alcohol-free, decaf); a photo cannot show it.
        - If the photo is ambiguous, pick the most likely interpretation and put your assumption in aiNotes.
        - Do not output anything other than the JSON object.
        """
    }

    private var userPrompt: String {
        "Classify this meal and return the JSON object as specified."
    }

    private var muscleClassifierSystemPrompt: String {
        let vocab = MuscleGroup.allCases.map(\.rawValue).joined(separator: ", ")
        return """
        You are a strength-training assistant. Given the name of a resistance/fitness exercise, identify which muscle groups it trains.

        Return ONLY this JSON object, no markdown, no prose:
        {
          "primary":   [ <muscle>, ... ],
          "secondary": [ <muscle>, ... ]
        }

        Allowed muscle values (use these EXACT strings, nothing else):
        \(vocab)

        Rules:
        - "primary" = the muscles the exercise is chiefly designed to work (usually 1–3).
        - "secondary" = assisting / stabilizing muscles that get meaningful work (0–4). A muscle must never appear in both lists.
        - Use "fullBody" only for whole-body movements (e.g. burpees, clean & jerk) and "cardio" only for conditioning work (e.g. running, rowing, cycling) — otherwise list specific muscles.
        - If the exercise name is unclear, pick the most likely standard interpretation.
        - Output nothing except the JSON object.
        """
    }
}
