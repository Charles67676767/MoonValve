///|
test "localization UTF8 BOM and both UTF16 byte orders roundtrip non BMP text" {
  let source : @moonvalve.Localization = {
    language: "English",
    encoding: "utf8",
    tokens: [
      { name: "Moon_Hello", text: "Hello %s1 😀", },
      { name: "Moon_Quote", text: "line\n\"quote\" \\", },
    ],
  }
  for encoding in ["utf8", "utf8-bom", "utf16le", "utf16be"] {
    let decoded = @moonvalve.read_localization(source.write(encoding~))
    assert_eq(decoded.tokens, source.tokens)
    assert_eq(decoded.encoding, encoding)
  }
  for
    bytes in [
      b"\xff\xfe\x00", b"\xff\xfe\x00\xd8", b"\xff", b"lang { Language English Tokens {a 1 A 2} }",
    ] {
    assert_true(
      try {
        @moonvalve.read_localization(bytes) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "localization placeholder identities multiplicity reorder and malformed syntax" {
  assert_eq(
    @moonvalve.localization_placeholders("%s1 %d2 %%"),
    @moonvalve.localization_placeholders("%d2 %s1 %%"),
  )
  assert_true(
    @moonvalve.localization_placeholders("%s1 %s1") !=
    @moonvalve.localization_placeholders("%s1"),
  )
  assert_eq(
    @moonvalve.localization_placeholders("%s has %d", syntax="printf"),
    @moonvalve.localization_placeholders("%2$d for %1$s", syntax="printf"),
  )
  assert_eq(
    @moonvalve.localization_placeholders("{{x}} {s:name} {0}", syntax="brace"),
    ["0", "s:name"],
  )
  for
    (text, syntax) in [
      ("%s0", "valve"),
      ("%s", "valve"),
      ("%1$s %d", "printf"),
      ("%*s", "printf"),
      ("{x", "brace"),
      ("}", "brace"),
    ] {
    assert_true(
      try {
        @moonvalve.localization_placeholders(text, syntax~) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "PO multiline contexts plurals comments fuzzy obsolete and canonical roundtrip" {
  let text = "# translator\n#, fuzzy, c-format\nmsgctxt \"token\"\nmsgid \"Hello \"\n\"world\\n\"\nmsgstr \"你好世界\\n\"\n\nmsgid \"one\"\nmsgid_plural \"many\"\nmsgstr[0] \"一个\"\nmsgstr[1] \"多个\"\n\n#~ msgctxt \"old\"\n#~ msgid \"removed\"\n#~ msgstr \"移除\"\n\n# trailing\n"
  let po = @moonvalve.parse_po(text)
  assert_eq(po.entries.length(), 3)
  assert_eq(po.entries[0].id, "Hello world\n")
  assert_eq(po.entries[1].translations, ["一个", "多个"])
  assert_eq(po.entries[2].obsolete, true)
  assert_eq(@moonvalve.parse_po(po.stringify()), po)
  for
    invalid in [
      "msgid \"x\"", "msgstr \"x\"", "msgid \"x\"\nmsgstr[0] \"x\"", "msgid \"x\"\nmsgid_plural \"xs\"\nmsgstr[1] \"x\"",
    ] {
    assert_true(
      try {
        @moonvalve.parse_po(invalid) |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "Valve PO context identity update fuzzy stale placeholders and safe import" {
  let source : @moonvalve.Localization = {
    language: "English",
    encoding: "utf16le",
    tokens: [
      { name: "A", text: "Hello %s1", },
      { name: "B", text: "Same", },
      { name: "C", text: "Same", },
    ],
  }
  let translation : @moonvalve.Localization = {
    ..source,
    language: "schinese",
    tokens: [
      { name: "A", text: "你好 %s1", },
      { name: "B", text: "相同", },
      { name: "C", text: "一样", },
    ],
  }
  let po = source.to_po(translated=translation)
  assert_eq(
    source.import_po(@moonvalve.parse_po(po.stringify()), "schinese").document.tokens,
    translation.tokens,
  )
  assert_eq(source.validate_translation(translation), [])
  let changed = {
    ..source,
    tokens: [
      { name: "A", text: "Hi %s1", },
      { name: "B", text: "Same", },
      { name: "D", text: "New", },
    ],
  }
  let updated = @moonvalve.update_po(changed.to_po(), po)
  assert_true(updated.entries[1].flags.contains("fuzzy"))
  assert_eq(updated.entries[1].translations, ["你好 %s1"])
  assert_eq(updated.entries[4].obsolete, true)
  let result = changed.import_po(updated, "schinese")
  assert_eq(result.issues.map(i => i.code), [
    "fuzzy_translation", "untranslated",
  ])
  assert_eq(result.document.tokens[0].text, "Hi %s1")
  let bad = { ..translation, tokens: [{ name: "A", text: "你好 %d1", }], }
  assert_eq(source.validate_translation(bad).map(i => i.code), [
    "placeholder_mismatch", "missing_token", "missing_token",
  ])
}

///|
test "constructed PO models and localization metadata reject NUL and injected lines" {
  let document : @moonvalve.Localization = {
    language: "English\nInjected: yes",
    encoding: "utf8",
    tokens: [],
  }
  assert_true(
    try {
      document.to_po() |> ignore
      false
    } catch {
      _ => true
    },
  )
  let entry : @moonvalve.POEntry = {
    context: Some("token"),
    id: "Hello",
    plural: None,
    translations: ["Moon"],
    comments: [],
    flags: [],
    obsolete: false,
  }
  for
    invalid in [
      { ..entry, comments: ["# bad\u0000comment"], },
      { ..entry, flags: ["bad\u0000flag"], },
      { ..entry, id: "bad\u0000id", },
    ] {
    let catalog : @moonvalve.POCatalog = {
      entries: [invalid],
      trailing_comments: [],
    }
    assert_true(
      try {
        catalog.stringify() |> ignore
        false
      } catch {
        _ => true
      },
    )
  }
}

///|
test "empty source localization text remains an intentional empty token" {
  let source : @moonvalve.Localization = {
    language: "English",
    encoding: "utf8",
    tokens: [{ name: "Moon_Empty", text: "", }],
  }
  let result = source.import_po(source.to_po(), "schinese")
  assert_eq(result.issues, [])
  assert_eq(result.document.tokens, source.tokens)
}
