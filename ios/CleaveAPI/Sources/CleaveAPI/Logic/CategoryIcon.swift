import Foundation

/// SF Symbol for a category: the user's chosen local icon if set, otherwise a keyword match on the
/// name (Splitwise or self-hosted), falling back to a generic tag.
@MainActor
func categorySymbol(_ category: String?) -> String {
    guard let name = category, !name.isEmpty else { return "tag" }
    if let custom = CategoryCatalog.shared.icon(for: name) { return custom }
    let c = name.lowercased()
    let map: [(String, String)] = [
        ("settle", "arrow.left.arrow.right"),
        ("payment", "arrow.left.arrow.right"),
        ("reimburs", "arrow.uturn.backward.circle"),
        ("personal care", "comb"),  // before "car" - "personal care".contains("car")
        ("grocer", "cart.fill"),
        ("dining", "fork.knife"),
        ("restaurant", "fork.knife"),
        ("food", "fork.knife"),
        ("coffee", "cup.and.saucer.fill"),
        ("alcohol", "wineglass.fill"),
        ("liquor", "wineglass.fill"),
        ("bar", "wineglass.fill"),
        ("rent", "house.fill"),
        ("mortgage", "house.fill"),
        ("hous", "house.fill"),
        ("furnit", "sofa.fill"),
        ("electric", "bolt.fill"),
        ("util", "bolt.fill"),
        ("water", "drop.fill"),
        ("trash", "trash.fill"),
        ("internet", "wifi"),
        ("tv", "tv"),
        ("phone", "phone.fill"),
        ("fuel", "fuelpump.fill"),
        ("gas", "fuelpump.fill"),
        ("parking", "parkingsign"),
        ("taxi", "car.fill"),
        ("car", "car.fill"),
        ("transport", "bus.fill"),
        ("flight", "airplane"),
        ("travel", "airplane"),
        ("hotel", "bed.double.fill"),
        ("lodging", "bed.double.fill"),
        ("movie", "film.fill"),
        ("entertain", "film.fill"),
        ("game", "gamecontroller.fill"),
        ("music", "music.note"),
        ("cloth", "tshirt.fill"),
        ("shop", "bag.fill"),
        ("medical", "cross.case.fill"),
        ("health", "cross.case.fill"),
        ("pharma", "pills.fill"),
        ("insur", "shield.fill"),
        ("gift", "gift.fill"),
        ("donat", "gift.fill"),
        ("pet", "pawprint.fill"),
        ("educa", "book.fill"),
        ("servic", "wrench.and.screwdriver.fill"),
        ("bill", "doc.text.fill"),
    ]
    for (key, symbol) in map where c.contains(key) {
        return symbol
    }
    return "tag"
}

/// One selectable category icon: an SF Symbol plus extra search terms, so a search like "food" or "vehicle"
/// finds the right glyph even when the symbol name does not literally contain the word.
struct IconChoice: Identifiable {
    let symbol: String
    let terms: [String]
    var id: String { symbol }

    init(_ symbol: String, _ terms: String) {
        self.symbol = symbol
        self.terms = terms.split(separator: " ").map(String.init)
    }
}

/// The SF Symbols offered when picking a category icon, each tagged with related search words. Grouped by
/// theme for maintenance only; the picker shows them in this order and filters by `search`.
enum CategoryIconLibrary {
    static let all: [IconChoice] = [
        // Food & drink
        IconChoice("fork.knife", "food dining restaurant meal eat lunch dinner"),
        IconChoice("takeoutbag.and.cup.and.straw.fill", "takeout fastfood delivery food drink"),
        IconChoice("cup.and.saucer.fill", "coffee cafe tea drink"),
        IconChoice("mug.fill", "beer drink coffee mug"),
        IconChoice("wineglass.fill", "alcohol wine bar drink liquor"),
        IconChoice("cart.fill", "grocery groceries shopping supermarket food market"),
        IconChoice("basket.fill", "grocery shopping market basket produce"),
        IconChoice("carrot.fill", "vegetable produce grocery food healthy"),
        IconChoice("fish.fill", "seafood fish food"),
        IconChoice("birthday.cake.fill", "cake dessert birthday bakery sweets party"),
        IconChoice("popcorn.fill", "snack movie cinema entertainment"),
        // Home & utilities
        IconChoice("house.fill", "home rent mortgage housing property"),
        IconChoice("building.2.fill", "apartment building property office company"),
        IconChoice("sofa.fill", "furniture couch living room"),
        IconChoice("bed.double.fill", "furniture bedroom hotel lodging sleep"),
        IconChoice("lightbulb.fill", "light electricity utility bulb"),
        IconChoice("bolt.fill", "electricity power energy utility charge"),
        IconChoice("flame.fill", "gas heating fire fuel"),
        IconChoice("drop.fill", "water plumbing utility"),
        IconChoice("trash.fill", "garbage waste trash disposal"),
        IconChoice("wifi", "internet network broadband wireless"),
        IconChoice("tv", "television streaming tv media"),
        IconChoice("phone.fill", "phone mobile call cell"),
        IconChoice("refrigerator.fill", "appliance kitchen fridge home"),
        IconChoice("oven.fill", "appliance kitchen oven cooking"),
        IconChoice("washer.fill", "laundry appliance washing clothes"),
        IconChoice("wrench.and.screwdriver.fill", "repair maintenance tools service handyman"),
        IconChoice("hammer.fill", "repair tools construction diy build"),
        IconChoice("paintbrush.fill", "paint decor renovation improvement"),
        IconChoice("key.fill", "rent keys deposit security lock"),
        IconChoice("leaf.fill", "nature eco garden plant green lawn"),
        IconChoice("tree.fill", "garden nature outdoors tree plant"),
        // Transport
        IconChoice("fuelpump.fill", "gas fuel petrol gasoline"),
        IconChoice("car.fill", "car auto vehicle taxi ride drive"),
        IconChoice("bolt.car.fill", "ev electric car charging vehicle"),
        IconChoice("bus.fill", "bus transit transport public commute"),
        IconChoice("tram.fill", "train tram metro subway transit rail"),
        IconChoice("bicycle", "bike cycling transport vehicle"),
        IconChoice("parkingsign", "parking garage vehicle"),
        // Travel
        IconChoice("airplane", "flight travel air trip flying vacation"),
        IconChoice("suitcase.fill", "travel luggage trip vacation"),
        IconChoice("ferry.fill", "boat ferry ship cruise travel"),
        IconChoice("map.fill", "travel navigation map trip directions"),
        IconChoice("globe.americas.fill", "travel international world global"),
        IconChoice("beach.umbrella.fill", "vacation beach holiday summer"),
        IconChoice("tent.fill", "camping outdoors travel nature"),
        IconChoice("mountain.2.fill", "hiking outdoors nature mountains"),
        // Shopping & clothing
        IconChoice("bag.fill", "shopping retail store purchase"),
        IconChoice("handbag.fill", "purse bag accessory fashion"),
        IconChoice("tshirt.fill", "clothing apparel fashion clothes"),
        IconChoice("gift.fill", "gift present donation birthday"),
        IconChoice("giftcard.fill", "giftcard gift card store credit"),
        IconChoice("shippingbox.fill", "delivery package shipping mail box"),
        // Finance & work
        IconChoice("creditcard.fill", "card payment credit debit"),
        IconChoice("banknote.fill", "cash money bills currency"),
        IconChoice("dollarsign.circle.fill", "money cash income dollar"),
        IconChoice("building.columns.fill", "bank government tax institution"),
        IconChoice("chart.line.uptrend.xyaxis", "investment stocks savings growth finance"),
        IconChoice("chart.pie.fill", "budget finance investment allocation"),
        IconChoice("percent", "interest tax discount rate"),
        IconChoice("briefcase.fill", "work business job office career"),
        IconChoice("shield.fill", "insurance security protection safety"),
        IconChoice("lock.fill", "security savings safe lock"),
        IconChoice("calendar", "subscription bills recurring schedule date"),
        IconChoice("doc.text.fill", "bill document invoice paperwork"),
        IconChoice("envelope.fill", "mail bills post letter"),
        IconChoice("bell.fill", "reminder notification subscription alert"),
        // Health & personal care
        IconChoice("cross.case.fill", "medical doctor health clinic hospital"),
        IconChoice("pills.fill", "pharmacy medicine prescription drug"),
        IconChoice("heart.fill", "health wellness love fitness"),
        IconChoice("stethoscope", "doctor medical checkup health"),
        IconChoice("bandage.fill", "medical firstaid injury bandage"),
        IconChoice("syringe.fill", "vaccine shot medical injection"),
        IconChoice("mouth.fill", "dentist dental teeth mouth"),
        IconChoice("eyeglasses", "glasses optometry vision eyewear"),
        IconChoice("comb", "haircut salon grooming personalcare"),
        IconChoice("scissors", "haircut salon barber cut"),
        // Fitness & sport
        IconChoice("figure.run", "exercise fitness running gym sport workout"),
        IconChoice("dumbbell.fill", "gym fitness workout exercise weights"),
        IconChoice("sportscourt.fill", "sports recreation court gym fitness"),
        IconChoice("soccerball", "sports soccer football recreation"),
        IconChoice("basketball.fill", "sports basketball recreation"),
        // Entertainment & hobbies
        IconChoice("film.fill", "movie cinema entertainment streaming"),
        IconChoice("gamecontroller.fill", "games gaming videogames play"),
        IconChoice("music.note", "music songs streaming audio"),
        IconChoice("headphones", "music audio podcast headphones"),
        IconChoice("guitars.fill", "music instrument hobby band"),
        IconChoice("theatermasks.fill", "theater show arts entertainment play"),
        IconChoice("ticket.fill", "tickets events concert movie show"),
        IconChoice("paintpalette.fill", "art hobby painting crafts"),
        IconChoice("camera.fill", "photography camera photo"),
        IconChoice("puzzlepiece.fill", "games hobby toys puzzle"),
        IconChoice("dice.fill", "games gambling casino board"),
        // Education
        IconChoice("book.fill", "books reading education literature"),
        IconChoice("books.vertical.fill", "library books education study"),
        IconChoice("newspaper.fill", "news subscription magazine media"),
        IconChoice("graduationcap.fill", "education tuition school college university"),
        IconChoice("backpack.fill", "school kids education bag"),
        IconChoice("pencil", "school office supplies write"),
        // Pets & kids
        IconChoice("pawprint.fill", "pet dog cat animal vet"),
        IconChoice("dog.fill", "dog pet puppy animal"),
        IconChoice("cat.fill", "cat pet kitten animal"),
        IconChoice("teddybear.fill", "kids toys baby children"),
        IconChoice("stroller.fill", "baby kids childcare infant"),
        IconChoice("balloon.fill", "party kids celebration birthday"),
        IconChoice("figure.and.child.holdinghands", "childcare family kids parenting"),
        // Tech
        IconChoice("laptopcomputer", "computer tech electronics laptop"),
        IconChoice("desktopcomputer", "computer pc tech desktop"),
        IconChoice("iphone", "phone mobile device smartphone"),
        IconChoice("ipad", "tablet device ipad"),
        IconChoice("applewatch", "watch wearable device"),
        IconChoice("printer.fill", "office printing printer"),
        IconChoice("externaldrive.fill", "storage backup tech drive"),
        IconChoice("server.rack", "hosting server tech cloud hardware"),
        IconChoice("gearshape.fill", "settings service utility gear"),
        // Giving & misc
        IconChoice("hand.raised.fill", "donation charity help volunteer"),
        IconChoice("cross.fill", "church donation religious faith"),
        IconChoice("umbrella.fill", "insurance weather rainyday rain"),
        IconChoice("star.fill", "favorite rating special star"),
        IconChoice("sparkles", "misc clean new special"),
        IconChoice("flag.fill", "goal milestone flag"),
        IconChoice("clock.fill", "time hourly service clock"),
        IconChoice("tag.fill", "general label price sale"),
        IconChoice("tag", "general label misc default"),
    ]

    /// Filter by a query against each symbol name and its search terms. An empty query returns the full list.
    static func search(_ query: String) -> [IconChoice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.symbol.contains(q) || $0.terms.contains { $0.contains(q) } }
    }
}

/// Backwards-compatible flat list of the offered symbols (the library is the source of truth).
let categoryIconChoices: [String] = CategoryIconLibrary.all.map(\.symbol)
