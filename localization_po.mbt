///|
pub(all) struct LocalizationImport {
  document : Localization
  issues : Array[LocalizationIssue]
} derive(Eq, Debug)

///|
pub extend LocalizationImport with Eq::{equal, not_equal}

///|
pub extend LocalizationImport with @debug.Debug::{to_repr}

///|
/// Valve token names are PO contexts. Equal source strings remain distinct
/// messages, and translators may reorder entries without changing token identity.
pub fn Localization::to_po(
  self : Localization,
  translated? : Localization,
) -> POCatalog raise {
  localization_validate(self)
  let translations : Map[String, String] = Map([])
  if translated is Some(target) {
    localization_validate(target)
    for token in target.tokens {
      translations[token.name.to_lower()] = token.text
    }
  }
  let entries : Array[POEntry] = [
    {
      context: None,
      id: "",
      plural: None,
      translations: [
        "Project-Id-Version: MoonValve\nMIME-Version: 1.0\nContent-Type: text/plain; charset=UTF-8\nContent-Transfer-Encoding: 8bit\nLanguage: " +
        translated.map(t => t.language).unwrap_or("") +
        "\n",
      ],
      comments: ["# MoonValve localization catalog"],
      flags: [],
      obsolete: false,
    },
  ]
  for token in self.tokens {
    entries.push({
      context: Some(token.name),
      id: token.text,
      plural: None,
      translations: [translations.get(token.name.to_lower()).unwrap_or("")],
      comments: [],
      flags: [],
      obsolete: false,
    })
  }
  { entries, trailing_comments: [], }
}

///|
/// Update a PO/POT from a new source catalog. Changed text keeps the old
/// translation marked fuzzy; removed messages become obsolete.
pub fn update_po(template : POCatalog, previous : POCatalog) -> POCatalog raise {
  po_validate(template)
  po_validate(previous)
  let old : Map[String, POEntry] = Map([])
  for entry in previous.entries {
    if !entry.obsolete {
      let key = match entry.context {
        Some(context) => "c:" + context
        None => "i:" + entry.id
      }
      if old.contains(key) {
        raise InvalidDocument("Ambiguous PO update context")
      }
      old[key] = entry
    }
  }
  let used : Map[String, Bool] = Map([])
  let entries : Array[POEntry] = []
  for entry in template.entries {
    if entry.obsolete {
      continue
    }
    let key = match entry.context {
      Some(context) => "c:" + context
      None => "i:" + entry.id
    }
    if used.contains(key) {
      raise InvalidDocument("Ambiguous PO template context")
    }
    used[key] = true
    if old.get(key) is Some(prior) {
      let changed = entry.id != prior.id || entry.plural != prior.plural
      let flags = prior.flags.copy()
      if changed && !flags.contains("fuzzy") {
        flags.push("fuzzy")
      }
      let comments = prior.comments.copy()
      if changed {
        comments.push("#| msgid " + po_quote(prior.id))
      }
      entries.push({
        ..entry,
        translations: if entry.plural == prior.plural {
          prior.translations.copy()
        } else {
          entry.translations.copy()
        },
        comments,
        flags,
      })
    } else {
      entries.push(entry)
    }
  }
  for entry in previous.entries {
    let key = match entry.context {
      Some(context) => "c:" + context
      None => "i:" + entry.id
    }
    if entry.obsolete || !used.contains(key) {
      entries.push({ ..entry, obsolete: true, })
    }
  }
  let catalog = {
    entries,
    trailing_comments: previous.trailing_comments.copy(),
  }
  catalog.stringify() |> ignore
  catalog
}

///|
/// Import reviewed translations. Empty, fuzzy, stale, plural or unsafe entries
/// produce issues and retain source text; unknown contexts are also reported.
pub fn Localization::import_po(
  self : Localization,
  catalog : POCatalog,
  language : String,
  syntax? : String = "valve",
  allow_fuzzy? : Bool = false,
) -> LocalizationImport raise {
  localization_validate(self)
  po_validate(catalog)
  let targets : Map[String, POEntry] = Map([])
  let issues : Array[LocalizationIssue] = []
  let known : Map[String, Bool] = Map([])
  for token in self.tokens {
    known[token.name.to_lower()] = true
  }
  for entry in catalog.entries {
    if entry.obsolete || (entry.context is None && entry.id.is_empty()) {
      continue
    }
    guard entry.context is Some(context) else {
      issues.push({
        token: "",
        code: "missing_context",
        message: "Valve PO messages require a token name as msgctxt",
      })
      continue
    }
    let key = context.to_lower()
    if targets.contains(key) {
      raise InvalidDocument("Duplicate Valve PO token context")
    }
    targets[key] = entry
    if !known.contains(key) {
      issues.push({
        token: context,
        code: "extra_token",
        message: "PO context is absent from the source localization",
      })
    }
  }
  let tokens = self.tokens.map(token => {
    let issue = if targets.get(token.name.to_lower()) is Some(entry) {
      if entry.id != token.text {
        Some(("stale_source", "PO msgid differs from the current source text"))
      } else if entry.plural is Some(_) {
        Some(
          (
            "plural_unsupported", "Valve tokens require a singular PO translation",
          ),
        )
      } else if entry.flags.contains("fuzzy") && !allow_fuzzy {
        Some(("fuzzy_translation", "PO translation requires review"))
      } else if entry.translations[0].is_empty() && !token.text.is_empty() {
        Some(("untranslated", "PO msgstr is empty"))
      } else {
        let valid = try
          localization_placeholders(token.text, syntax~) ==
          localization_placeholders(entry.translations[0], syntax~)
        catch {
          _ => false
        }
        if valid {
          return LocalizationToken::{ ..token, text: entry.translations[0], }
        } else {
          Some(
            (
              "placeholder_mismatch", "Translation changes or invalidates placeholders",
            ),
          )
        }
      }
    } else {
      Some(("missing_token", "No PO translation for this token"))
    }
    if issue is Some((code, message)) {
      issues.push({ token: token.name, code, message, })
    }
    token
  })
  let document = { ..self, language, tokens, }
  localization_validate(document)
  { document, issues, }
}
