// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

// The script a language is likely written in, for the platforms where there
// is no `Locale.Language` to ask (FoundationEssentials has none). Apple's
// platforms ask `Locale.Language`, which reads the same CLDR data.

/// The likely script of a language, as ISO 15924 (`Latn`), for the five
/// scripts the engine's label text tells apart: Latin, Cyrillic, Greek,
/// Armenian and Georgian.
///
/// The tables are the answers of `Locale.Language(identifier:).script` from
/// the ICU data of Swift 6.4.2's Foundation on Linux, cut down: every two
/// letter code written in one of the five scripts, the three letter codes
/// written in the four that are not Latin, and the regions that move a
/// language to another script (`sr-ME` is Latin, `az-IR` Arabic). A three
/// letter code written in Latin is not listed, which leaves thousands of
/// minor languages out: for those this says nil where `Locale.Language`
/// says Latin. `PortableFoundationParityTests` checks every entry against
/// `Locale.Language`.
public enum LikelyScript {
    /// The script of a BCP 47 language identifier (`sr`, `sr-Latn`,
    /// `pt-BR`, `az_IR`), in any case. A script subtag the identifier names
    /// wins over the language's likely one. Nil when the script is none of
    /// the five, or the language is not known.
    public static func of(languageIdentifier identifier: String) -> String? {
        let subtags = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let language = subtags.first else { return nil }
        if subtags.count > 1, subtags[1].count == 4, subtags[1].allSatisfy(\.isLetter) {
            let named = subtags[1].prefix(1).uppercased() + subtags[1].dropFirst()
            return knownScripts.contains(named) ? named : nil
        }
        if subtags.count > 1, let region = subtags.dropFirst().first(where: { $0.count == 2 || $0.count == 3 }),
           let script = regionOverrides[language + "-" + region] {
            return knownScripts.contains(script) ? script : nil
        }
        return languages[language]
    }

    private static let knownScripts: Set<String> = ["Latn", "Cyrl", "Grek", "Armn", "Geor"]

    private static let languages: [String: String] = {
        var table: [String: String] = [:]
        for (script, codes) in byScript {
            for code in codes.split(separator: " ") {
                table[String(code)] = script
            }
        }
        return table
    }()

    private static let byScript: [(String, String)] = [
        ("Latn",
        "aa af ak an ay az bi bm br bs ca ch co cs cy da de ee en eo es et eu ff fi fj fo fr fy " +
        "ga gd gl gn gv ha ho hr ht hu hz ia id ie ig ik in io is it jv jw kg ki kj kl kr ku kw " +
        "la lb lg li ln lt lu lv mg mh mi mo ms mt na nb nd ng nl nn no nr nv ny oc om pl pt qu " +
        "rm rn ro rw sc se sg sk sl sm sn so sq ss st su sv sw tk tl tn to tr ts ty uz ve vi vo " +
        "wa wo xh yo za zu "),
        ("Cyrl",
        "ab abk ady agx akv alr alt ani aqc atv av ava ba bak be bel bg bhh bph bua bul bxm ce " +
        "che chm chu chv cji ckt clw crh cu cv dar ddo dlg dng enf enh eve evn gdo gin gld huz " +
        "inh itl jct jdt kaa kap kaz kbd kca ket khv kim kir kjh kk koi kom kpt kpy krc krk kum " +
        "kv kva ky lbe lez mdf mk mkd mn mns mon mrj mtm mud myv ndf neg nio niv nog oaa oac omk " +
        "orv os oss paq rsk ru rue rus rut sah sel sgh sia sjd sjt sr srp sty tab tat tg tgk tin " +
        "tt tyv ude udi udm ugh uk ukr ulc xal xas xdq xpm xrm xrn xwo yai ykg ykh ynk yrk ysr " +
        "yug yux zko zkz "),
        ("Grek",
        "aat bgx cpg ecr el ell pnt scx tsd uum xpg yej "),
        ("Armn",
        "axm hy hye hyw rmi "),
        ("Geor",
        "bbl jge ka kat oav sva xmf ")
    ]

    /// A language and region whose likely script is not the language's own,
    /// as `language-region:Script`.
    private static let regionOverrides: [String: String] = {
        var table: [String: String] = [:]
        let entries = 
            "az-iq:Arab az-ir:Arab az-ru:Cyrl ha-cm:Arab ha-sd:Arab kaz-af:Arab kaz-cn:Arab " +
            "kaz-ir:Arab kaz-mn:Arab kir-cn:Arab kir-tr:Latn kk-af:Arab kk-cn:Arab kk-ir:Arab " +
            "kk-mn:Arab ku-lb:Arab ky-cn:Arab ky-tr:Latn mn-cn:Mong mon-cn:Mong ms-cc:Arab sr-me:Latn " +
            "sr-ro:Latn sr-ru:Latn sr-tr:Latn srp-me:Latn srp-ro:Latn srp-ru:Latn srp-tr:Latn " +
            "tg-pk:Arab tgk-pk:Arab ug-kz:Cyrl ug-mn:Cyrl uz-af:Arab uz-cn:Cyrl "
        for entry in entries.split(separator: " ") {
            let parts = entry.split(separator: ":")
            table[String(parts[0])] = String(parts[1])
        }
        return table
    }()
}
