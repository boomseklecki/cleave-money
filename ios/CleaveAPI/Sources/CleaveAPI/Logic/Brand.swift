import Foundation
import FoundationModels

/// A resolved brand for a subscription: a display name and (when known) a domain that drives the logo
/// URL. The logo is served by our own backend (`/logos/{domain}`), so merchant domains never leave the
/// self-hosted server.
struct Brand {
    let name: String
    let domain: String?

    var logoURL: String? {
        guard let domain, !domain.isEmpty else { return nil }
        return APIConfig.baseURL.appendingPathComponent("logos/\(domain)").absoluteString
    }
}

/// A small map of common subscription brands → domain, for an instant logo without the model.
///
/// `builtins` is the set compiled into the app: the instant/offline fallback, *and* the seed the server-managed
/// catalog (migration 0054) is initialized from. Once the app loads that server catalog (`BrandCatalogStore`),
/// `lookup` resolves against it instead - so an admin can add / edit / delete any entry, defaults included.
enum BrandCatalog {
    static let builtins: [(pattern: String, brand: Brand)] = [
        ("netflix", .init(name: "Netflix", domain: "netflix.com")),
        ("spotify", .init(name: "Spotify", domain: "spotify.com")),
        ("hulu", .init(name: "Hulu", domain: "hulu.com")),
        ("disney", .init(name: "Disney+", domain: "disneyplus.com")),
        ("hbo", .init(name: "Max", domain: "max.com")),
        ("youtube", .init(name: "YouTube", domain: "youtube.com")),
        ("audible", .init(name: "Audible", domain: "audible.com")),
        ("amazon", .init(name: "Amazon", domain: "amazon.com")),
        ("prime", .init(name: "Amazon Prime", domain: "amazon.com")),
        ("adobe", .init(name: "Adobe", domain: "adobe.com")),
        ("dropbox", .init(name: "Dropbox", domain: "dropbox.com")),
        ("microsoft", .init(name: "Microsoft", domain: "microsoft.com")),
        ("xbox", .init(name: "Xbox", domain: "xbox.com")),
        ("playstation", .init(name: "PlayStation", domain: "playstation.com")),
        ("nintendo", .init(name: "Nintendo", domain: "nintendo.com")),
        ("paramount", .init(name: "Paramount+", domain: "paramountplus.com")),
        ("peacock", .init(name: "Peacock", domain: "peacocktv.com")),
        ("espn", .init(name: "ESPN+", domain: "espn.com")),
        ("crunchyroll", .init(name: "Crunchyroll", domain: "crunchyroll.com")),
        ("twitch", .init(name: "Twitch", domain: "twitch.tv")),
        ("patreon", .init(name: "Patreon", domain: "patreon.com")),
        ("github", .init(name: "GitHub", domain: "github.com")),
        ("notion", .init(name: "Notion", domain: "notion.so")),
        ("openai", .init(name: "OpenAI", domain: "openai.com")),
        ("chatgpt", .init(name: "ChatGPT", domain: "openai.com")),
        ("anthropic", .init(name: "Claude", domain: "claude.ai")),
        ("claude", .init(name: "Claude", domain: "claude.ai")),
        ("peloton", .init(name: "Peloton", domain: "onepeloton.com")),
        ("slack", .init(name: "Slack", domain: "slack.com")),
        ("zoom", .init(name: "Zoom", domain: "zoom.us")),
        ("verizon", .init(name: "Verizon", domain: "verizon.com")),
        ("comcast", .init(name: "Xfinity", domain: "xfinity.com")),
        ("xfinity", .init(name: "Xfinity", domain: "xfinity.com")),
        ("apple", .init(name: "Apple", domain: "apple.com")),
        ("google", .init(name: "Google", domain: "google.com")),
        // Everyday brands (groceries, dining, fuel, retail, travel) so real spending resolves a logo without
        // the on-device model. Kept in lockstep with backend migration 0058. Ambiguous short tokens use a
        // /\bword\b/ regex so they don't match inside unrelated merchant strings.
        ("whole foods", .init(name: "Whole Foods Market", domain: "wholefoodsmarket.com")),
        ("trader joe", .init(name: "Trader Joe's", domain: "traderjoes.com")),
        ("safeway", .init(name: "Safeway", domain: "safeway.com")),
        ("costco", .init(name: "Costco", domain: "costco.com")),
        ("chipotle", .init(name: "Chipotle", domain: "chipotle.com")),
        ("starbucks", .init(name: "Starbucks", domain: "starbucks.com")),
        ("blue bottle", .init(name: "Blue Bottle Coffee", domain: "bluebottlecoffee.com")),
        ("sweetgreen", .init(name: "Sweetgreen", domain: "sweetgreen.com")),
        ("shake shack", .init(name: "Shake Shack", domain: "shakeshack.com")),
        ("panera", .init(name: "Panera Bread", domain: "panerabread.com")),
        ("home depot", .init(name: "The Home Depot", domain: "homedepot.com")),
        ("ikea", .init(name: "IKEA", domain: "ikea.com")),
        ("target", .init(name: "Target", domain: "target.com")),
        ("best buy", .init(name: "Best Buy", domain: "bestbuy.com")),
        ("nike", .init(name: "Nike", domain: "nike.com")),
        ("shell", .init(name: "Shell", domain: "shell.com")),
        ("chevron", .init(name: "Chevron", domain: "chevron.com")),
        ("exxon", .init(name: "Exxon", domain: "exxon.com")),
        ("uber", .init(name: "Uber", domain: "uber.com")),
        ("lyft", .init(name: "Lyft", domain: "lyft.com")),
        ("delta air", .init(name: "Delta Air Lines", domain: "delta.com")),
        ("airbnb", .init(name: "Airbnb", domain: "airbnb.com")),
        ("marriott", .init(name: "Marriott", domain: "marriott.com")),
        ("/\\bamc\\b/", .init(name: "AMC Theatres", domain: "amctheatres.com")),
        ("/\\bsteam\\b/", .init(name: "Steam", domain: "steampowered.com")),
        // Abbreviated descriptors real card/Plaid feeds emit (kept in lockstep with backend migration 0059).
        ("wholefds", .init(name: "Whole Foods Market", domain: "wholefoodsmarket.com")),
        ("amzn", .init(name: "Amazon", domain: "amazon.com")),
        ("sbux", .init(name: "Starbucks", domain: "starbucks.com")),
    ]

    /// Resolves against the loaded catalog (server-managed once fetched, else the built-ins / cached copy).
    /// The first rule whose pattern matches wins, so order matters. Main-actor because it reads
    /// `BrandCatalogStore`; every caller is already `@MainActor` (`BrandModel`).
    @MainActor
    static func lookup(_ text: String) -> Brand? {
        let t = text.lowercased()
        return BrandCatalogStore.shared.entries.first { $0.matches(t) }?.brand
    }
}

/// Compiles a brand pattern into a predicate over an already-lowercased haystack. Three syntaxes, checked in
/// order: a value wrapped in slashes (`/aldi|lidl/`) is a regular expression; a value containing `*` or `?`
/// is a glob (`*` = any run of characters, `?` = exactly one); anything else is a plain case-insensitive
/// substring (the original behaviour, so the seeded catalog keeps working unchanged). All are unanchored, so
/// `apple*bill` matches "APPLE.COM/BILL" and `giant?eagle` matches "GIANT EAGLE".
enum BrandMatcher {
    static func compile(_ raw: String) -> (String) -> Bool {
        let p = raw.trimmingCharacters(in: .whitespaces)
        if let body = regexBody(p) {
            guard let re = try? NSRegularExpression(pattern: body, options: [.caseInsensitive]) else {
                return { _ in false }   // a malformed /regex/ never matches (the editor flags it)
            }
            return { re.firstMatch(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)) != nil }
        }
        let lower = p.lowercased()
        if lower.contains("*") || lower.contains("?") {
            guard let re = try? NSRegularExpression(pattern: globToRegex(lower), options: [.caseInsensitive]) else {
                return { _ in false }
            }
            return { re.firstMatch(in: $0, range: NSRange($0.startIndex..<$0.endIndex, in: $0)) != nil }
        }
        return { $0.contains(lower) }
    }

    /// True when `raw` is a syntactically usable pattern (only a malformed `/regex/` is not).
    static func isValid(_ raw: String) -> Bool {
        guard let body = regexBody(raw.trimmingCharacters(in: .whitespaces)) else { return true }
        return (try? NSRegularExpression(pattern: body)) != nil
    }

    /// The inner source of a `/regex/` pattern, or nil when `p` is not slash-wrapped.
    private static func regexBody(_ p: String) -> String? {
        guard p.count >= 2, p.hasPrefix("/"), p.hasSuffix("/") else { return nil }
        return String(p.dropFirst().dropLast())
    }

    private static func globToRegex(_ glob: String) -> String {
        var out = ""
        for ch in glob {
            switch ch {
            case "*": out += ".*"
            case "?": out += "."
            default: out += NSRegularExpression.escapedPattern(for: String(ch))
            }
        }
        return out
    }
}

/// Cheap, pure parsing of raw merchant strings, used before the on-device model is ever consulted.
enum MerchantParse {
    /// Common public suffixes we accept as a real domain; the allowlist is what stops "ST.LOUIS" or "NO.5"
    /// from looking like domains.
    private static let commonTLDs: Set<String> = [
        "com", "net", "org", "io", "co", "app", "ai", "tv", "us", "uk", "ca", "de", "fr", "eu",
        "gov", "edu", "me", "info", "biz", "shop", "store", "online", "site", "xyz",
    ]

    /// US state abbreviations, stripped as trailing noise ("NETFLIX ... CA").
    private static let states: Set<String> = [
        "al", "ak", "az", "ar", "ca", "co", "ct", "de", "fl", "ga", "hi", "id", "il", "in", "ia", "ks",
        "ky", "la", "me", "md", "ma", "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm", "ny",
        "nc", "nd", "oh", "ok", "or", "pa", "ri", "sc", "sd", "tn", "tx", "ut", "vt", "va", "wa", "wv", "wi", "wy",
    ]

    private static let domainRegex = try? NSRegularExpression(
        pattern: "([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\\.)+([a-z]{2,})",
        options: [.caseInsensitive]
    )

    /// The first embedded domain in `text` (e.g. "APPLE.COM/BILL" -> "apple.com", "WWW.SHOP.COM" -> "shop.com"),
    /// or nil. Requires the suffix to be a known TLD. A leading "www." is dropped.
    static func embeddedDomain(in text: String) -> String? {
        let lower = text.lowercased()
        let range = NSRange(lower.startIndex..<lower.endIndex, in: lower)
        guard let re = domainRegex else { return nil }
        var found: String?
        re.enumerateMatches(in: lower, range: range) { match, _, stop in
            guard let match, match.numberOfRanges >= 3,
                  let full = Range(match.range, in: lower),
                  let tldRange = Range(match.range(at: 2), in: lower) else { return }
            guard commonTLDs.contains(String(lower[tldRange])) else { return }  // keep scanning otherwise
            var domain = String(lower[full])
            if domain.hasPrefix("www.") { domain.removeFirst(4) }
            found = domain
            stop.pointee = true
        }
        return found
    }

    /// Strip payment-processor prefixes ("SQ *", "TST*", "PAYPAL *") and trailing store/ref/phone/state noise,
    /// leaving the readable brand portion. Falls back to the trimmed original if cleaning empties it. Used to
    /// feed the on-device model (and its relatedness guard) a de-noised string.
    static func cleaned(_ merchant: String) -> String {
        var s = merchant.trimmingCharacters(in: .whitespaces)
        // A processor prefix is a short leading token ending in '*' (SQ *, TST*, PP*, CKE*, DD *, PAYPAL *).
        if let star = s.firstIndex(of: "*"), s.distance(from: s.startIndex, to: star) <= 8,
           s[s.startIndex..<star].allSatisfy({ $0.isLetter || $0.isNumber || $0.isWhitespace }) {
            s = String(s[s.index(after: star)...]).trimmingCharacters(in: .whitespaces)
        }
        // Drop store-reference tokens (a long digit run like "J625141"/"#1234"/a phone, or pure punctuation)
        // wherever they appear - a mid-string ref ("KFC J625141 STEUBENVILLE") would otherwise survive.
        var words = s.split(whereSeparator: { $0 == " " }).map(String.init).filter { !isInteriorNoise($0) }
        // Then drop trailing store numbers / phone / location codes from the tail ("... 55", "... CA", "... USA").
        while let last = words.last, isTrailingNoise(last) { words.removeLast() }
        let cleaned = words.joined(separator: " ")
        return cleaned.isEmpty ? merchant.trimmingCharacters(in: .whitespaces) : cleaned
    }

    /// A token that is store-ref noise anywhere in the string: a long digit run (>= 3 digits, e.g. "J625141",
    /// "#1234", a phone) or pure punctuation. Short brand numbers ("5 Guys", "7-Eleven") are kept.
    private static func isInteriorNoise(_ token: String) -> Bool {
        let letters = token.filter(\.isLetter).count
        let digits = token.filter(\.isNumber).count
        if digits >= 3 { return true }
        return letters == 0 && digits == 0
    }

    /// A trailing token that is store-number / location noise rather than part of the brand name.
    private static func isTrailingNoise(_ token: String) -> Bool {
        let t = token.lowercased()
        if token.filter(\.isLetter).isEmpty { return true }     // trailing pure number: "... 55"
        if t == "usa" || t == "us" { return true }
        return token.count == 2 && states.contains(t)
    }
}

/// A compiled catalog entry: the raw `pattern` (kept for persistence/display), the `brand` it maps to, and a
/// precompiled `matches` predicate so resolving a row on the render path costs no regex compilation.
struct BrandRule {
    let pattern: String
    let brand: Brand
    let matches: (String) -> Bool

    init(pattern: String, brand: Brand) {
        self.pattern = pattern
        self.brand = brand
        self.matches = BrandMatcher.compile(pattern)
    }
}

/// Holds the merchant to logo catalog the app resolves favicons against. Seeded synchronously from the last
/// cached server copy (or the compiled-in built-ins) so the first render has data offline, then replaced by
/// the server-managed catalog once `load` fetches `GET /brand-overrides`. Authoritative once loaded - deleting
/// a built-in server-side removes it here too. All eight per-view `BrandModel`s read this one shared source.
@MainActor
@Observable
final class BrandCatalogStore {
    static let shared = BrandCatalogStore()

    private(set) var entries: [BrandRule]

    private init() {
        entries = BrandCatalogStore.cached()
            ?? BrandCatalog.builtins.map { BrandRule(pattern: $0.pattern, brand: $0.brand) }
    }

    /// Best-effort refresh from the server (called at launch); leaves the cached/built-in set on failure.
    func load(_ client: Client) async {
        guard let items = try? await BrandOverridesRepository(client: client).get() else { return }
        apply(items)
    }

    /// Adopt a freshly fetched/saved catalog and cache it for the next cold start.
    func apply(_ items: [Components.Schemas.BrandOverrideItem]) {
        entries = items.map { BrandRule(pattern: $0.pattern, brand: BrandCatalogStore.brand(from: $0)) }
        BrandCatalogStore.cache(items)
    }

    private static func brand(from item: Components.Schemas.BrandOverrideItem) -> Brand {
        Brand(name: item.name, domain: item.domain?.isEmpty == false ? item.domain : nil)
    }

    // UserDefaults cache so a cold start uses the last-known server catalog, not the stale compiled-in one.
    // v2: the "keyword" field became "pattern"; a bumped key ignores any stale v1 rows.
    private static let cacheKey = "brandCatalog.v2"

    private static func cache(_ items: [Components.Schemas.BrandOverrideItem]) {
        let rows = items.map { ["pattern": $0.pattern, "name": $0.name, "domain": $0.domain ?? ""] }
        UserDefaults.standard.set(rows, forKey: cacheKey)
    }

    private static func cached() -> [BrandRule]? {
        guard let rows = UserDefaults.standard.array(forKey: cacheKey) as? [[String: String]],
              !rows.isEmpty else { return nil }
        return rows.compactMap { r in
            guard let pattern = r["pattern"], let name = r["name"] else { return nil }
            let domain = r["domain"] ?? ""
            return BrandRule(pattern: pattern, brand: Brand(name: name, domain: domain.isEmpty ? nil : domain))
        }
    }
}

/// The on-device model's guess of the brand behind a merchant string.
@Generable
struct BrandGuess {
    @Guide(description: "The clean consumer brand name, e.g. 'Netflix'")
    var name: String
    @Guide(description: "The brand's primary website domain, e.g. 'netflix.com'. Empty if unknown.")
    var domain: String
}

/// Resolves a display name + logo domain for each subscription: the offline catalog first, then Apple's
/// on-device model for the rest (cached). Mirrors `ReceiptScanModel`'s `@MainActor @Observable` shape; a
/// graceful no-op when Apple Intelligence is unavailable (names fall back to the cleaned merchant, no logo).
@MainActor
@Observable
final class BrandModel {
    /// The best brand known *right now*, for synchronous render. Precedence: the user's personal override, then
    /// server catalog patterns, then a domain embedded in the merchant, then a remembered on-device guess, then
    /// a plain-name fallback. The personal override wins (a deliberate user choice); catalog and embedded are
    /// still checked before the guess cache so a newly added/edited pattern beats a stale guess.
    func brand(key: String, displayName: String, amount: Decimal? = nil) -> Brand {
        if let o = MerchantPreferences.shared.override(forText: displayName, amount: amount,
                                                       resolveNote: Self.coreResolve) {
            return o
        }
        return Self.coreBrand(key: key, displayName: displayName) ?? Brand(name: displayName, domain: nil)
    }

    /// Resolution WITHOUT the personal override: catalog patterns, then a domain embedded in the merchant, then
    /// a remembered on-device guess (positive or negative). Nil only when none of those exist. Shared by
    /// `brand` and by `MerchantPreferences.override` (to resolve a note-only override's logo).
    static func coreBrand(key: String, displayName: String) -> Brand? {
        if let c = BrandCatalog.lookup(key) ?? BrandCatalog.lookup(displayName) {
            return c
        }
        if let domain = MerchantParse.embeddedDomain(in: displayName) {
            return Brand(name: displayName, domain: domain)
        }
        return BrandGuessCache.shared.brand(forKey: key)
    }

    /// `coreBrand` keyed by a raw text (normalizing it to a merchant key). The resolver injected into
    /// `MerchantPreferences.override` so a note-only override resolves its note through the normal pipeline.
    static func coreResolve(_ text: String) -> Brand? {
        coreBrand(key: MerchantText.key(text), displayName: text)
    }

    func brand(for sub: Subscription) -> Brand {
        brand(key: sub.id, displayName: sub.displayName, amount: sub.latestAmount)
    }

    /// Note-first favicon URL for a transaction/expense row: the first of `[note, merchant]` that resolves to
    /// a brand domain wins, else `nil` (→ the row's category icon). A per-user note override ("Duolingo" on an
    /// `APPLE.COM/BILL` charge) therefore beats the merchant string. A synchronous read over the current cache
    /// (warmed by `resolve(merchantTexts:)`) + the offline catalog - safe to call from a row's `body`.
    func logoURL(note: String?, merchant: String, amount: Decimal? = nil) -> String? {
        for text in [note, merchant] {
            guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let url = brand(key: MerchantText.key(text), displayName: text, amount: amount).logoURL {
                return url
            }
        }
        return nil
    }

    /// Fills the cache for the given (key, displayName) merchants: catalog hits immediately, then one
    /// on-device lookup per unknown.
    func resolve(_ merchants: [(key: String, displayName: String, category: String?)]) async {
        // Only the model guess is cached (catalog + embedded are cheap, authoritative, and re-checked each
        // render), so skip merchants already guessed. Catalog/embedded hits need no model call.
        for m in merchants where !BrandGuessCache.shared.contains(m.key) {
            if MerchantPreferences.shared.override(forText: m.displayName, amount: nil, resolveNote: Self.coreResolve) != nil { continue }  // personal override covers it
            if BrandCatalog.lookup(m.key) != nil || BrandCatalog.lookup(m.displayName) != nil { continue }
            if MerchantParse.embeddedDomain(in: m.displayName) != nil { continue }
            if let guessed = await guess(m.displayName, category: m.category) { BrandGuessCache.shared.record(m.key, guessed) }
        }
    }

    func resolve(_ subs: [Subscription]) async { await resolve(subs.map { ($0.id, $0.displayName, String?.none) }) }

    /// Warm the cache for a list of raw merchant strings (a row's note override + its merchant description),
    /// each with its resolved category (a hint for the guess). Deduped by merchant key so identical strings
    /// resolve once; nil/blank texts are skipped. Used by the lists to pre-resolve favicons off the render path.
    func resolve(merchantTexts items: [(text: String?, category: String?)]) async {
        var byKey: [String: (displayName: String, category: String?)] = [:]
        for item in items {
            guard let text = item.text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            let key = MerchantText.key(text)
            if byKey[key] == nil { byKey[key] = (text, item.category) }
        }
        await resolve(byKey.map { (key: $0.key, displayName: $0.value.displayName, category: $0.value.category) })
    }

    private func guess(_ merchant: String, category: String?) async -> Brand? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        // De-noise the POS string first ("SQ *BLUE BOTTLE 0123" -> "BLUE BOTTLE") so both the model and the
        // relatedness guard work on the real brand text, not processor prefixes and store numbers.
        let cleaned = MerchantParse.cleaned(merchant)
        let instructions = """
        You identify the consumer brand behind a bank subscription charge. Reply with the clean brand name \
        and its primary website domain. If you don't recognize it, use the merchant text as the name and \
        leave the domain empty.
        """
        // The bank category is a hint (e.g. "KFC" + "Dining" -> kfc.com), not authoritative.
        let hint = (category?.isEmpty == false) ? " The bank category is \"\(category!)\"." : ""
        let session = LanguageModelSession(instructions: instructions)
        guard let out = try? await session.respond(
            to: "Merchant: \"\(cleaned)\".\(hint) Brand name and domain:",
            generating: BrandGuess.self).content else { return nil }
        let domain = out.domain.trimmingCharacters(in: .whitespaces).lowercased()
        let name = out.name.trimmingCharacters(in: .whitespaces)
        // Only trust a guessed domain when the brand plausibly appears in the merchant text. Left unchecked,
        // the on-device model invents a brand (and logo) for a generic charge - e.g. "MONTHLY INSTALLMENTS"
        // resolves to Netflix. A real brand charge almost always carries the brand's name in the string.
        let formatted = domain.contains(".") && !domain.contains(" ")
        let valid = (formatted && Self.brandRelatesToMerchant(domain: domain, name: name, merchant: cleaned))
            ? domain : nil
        return Brand(name: name.isEmpty ? cleaned : name, domain: valid)
    }

    /// True when a guessed brand plausibly relates to the merchant string - a precision guard against the model
    /// hallucinating a brand for a generic charge ("MONTHLY INSTALLMENTS" -> Netflix), while still allowing the
    /// abbreviated storefronts POS systems produce. Two signals:
    ///   1. a distinctive brand token (the domain's first label, or a word of the name) appears verbatim in the
    ///      merchant - covers "SPOTIFY P0AB", "APPLE.COM/BILL", "TST* CHIPOTLE".
    ///   2. the merchant's leading word is the brand name's acronym - covers "KFC J625141" when the model
    ///      expands the name to "Kentucky Fried Chicken" (nothing overlaps the abbreviated merchant otherwise).
    private static func brandRelatesToMerchant(domain: String, name: String, merchant: String) -> Bool {
        let hay = merchant.lowercased().filter { $0.isLetter || $0.isNumber }
        guard !hay.isEmpty else { return false }

        var brandTokens: [String] = []
        if let label = domain.split(separator: ".").first { brandTokens.append(String(label)) }
        let nameWords = name.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        brandTokens += nameWords
        if brandTokens.contains(where: { $0.count >= 3 && hay.contains($0) }) { return true }

        let lead = String(merchant.lowercased().prefix { $0.isLetter })
        guard lead.count >= 2 else { return false }
        let acronym = nameWords.compactMap(\.first).map(String.init).joined()
        return acronym.count >= 2 && lead == acronym
    }
}
