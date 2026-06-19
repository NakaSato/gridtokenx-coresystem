/// ieee-conf.typ — IEEE Conference Template (Thai + English)
/// ─────────────────────────────────────────────────────────
/// fixes:
///   - margin left/right: 1in → 15.9mm  ← columns ชิดขอบกระดาษ
///   - justify: false                    ← ป้องกัน Thai over-stretch ใน column แคบ
///   - hyphenate: auto                   ← English hyphenates ที่ขอบ, Thai ไม่กระทบ
///   - number-align: center              ← page number กลางหน้า
///   - abstract inset: 1em              ← แคบกว่าเดิม (เดิม 2em)
///   - abstract justify: true (scoped)  ← full-width ไม่ over-stretch
///   - Thai references "เอกสารอ้างอิง"
///   - author .at("field", default:"")  ← ป้องกัน crash
///   - set list / set enum indent
///   - show raw — code block styling

#let ieee-conf(
  title: [],
  authors: (),
  abstract: [],
  keywords: (),
  body,
) = {

  // ── PAGE ──────────────────────────────────────────────────────────────────
  set page(
    paper: "a4",
    margin: (top: 19mm, bottom: 1in, left: 15.9mm, right: 15.9mm),
    numbering: "1",
    number-align: center,
  )

  // ── GLOBAL TEXT ───────────────────────────────────────────────────────────
  set text(
    font: ("TH Sarabun New", "Times New Roman"),
    size: 12pt,
    lang: "th",
    region: "TH",
    hyphenate: auto,   // English hyphenates ที่ขอบ column, Thai ไม่กระทบ
  )

  set par(
    justify: true,
    first-line-indent: 1em,
    leading: 0.55em,
    spacing: 0.75em,
  )

  // ── HEADING NUMBERING ─────────────────────────────────────────────────────
  set heading(numbering: "I.A.1.")

  // ── BIBLIOGRAPHY ──────────────────────────────────────────────────────────
  show bibliography: set text(size: 12pt)
  show bibliography: it => {
    v(1.5em, weak: true)
    it
  }

  // ── LISTS ─────────────────────────────────────────────────────────────────
  set list(indent: 1em, body-indent: 0.5em)
  set enum(indent: 1em, body-indent: 0.5em)

  // ── CODE BLOCKS ───────────────────────────────────────────────────────────
  show raw: set text(font: ("Courier New", "Courier"), size: 9pt)
  show raw.where(block: true): it => block(
    fill: luma(245),
    inset: (x: 8pt, y: 6pt),
    radius: 2pt,
    width: 100%,
    it,
  )

  // ── HEADING L1 ── Roman numerals, centered, bold smallcaps ────────────────
  show heading.where(level: 1): it => [
    #set par(justify: false, first-line-indent: 0pt)
    #v(1em, weak: true)
    #align(center)[
      #text(size: 12pt, weight: "bold", font: ("Times New Roman"))[
        #if (
          it.body == [References]
          or it.body == [REFERENCES]
          or it.body == [เอกสารอ้างอิง]
        ) [
          #smallcaps(it.body)
        ] else [
          #if it.numbering != none [
            #numbering("I.", counter(heading).get().first())
            #h(0.5em)
          ]
          #smallcaps(it.body)
        ]
      ]
    ]
    #v(1em, weak: true)
  ]

  // ── HEADING L2 ── Capital letters, italic ─────────────────────────────────
  show heading.where(level: 2): it => [
    #v(1em, weak: true)
    #text(
      size: 12pt, weight: "regular", style: "italic",
      font: ("TH Sarabun New", "Times New Roman"),
    )[
      #if it.numbering != none [
        #numbering("A.", counter(heading).get().at(1))
        #h(0.5em)
      ]
      #it.body
    ]
    #v(0.8em, weak: true)
  ]

  // ── HEADING L3 ── Arabic, italic, smaller ─────────────────────────────────
  show heading.where(level: 3): it => [
    #v(0.8em, weak: true)
    #text(
      size: 12pt, weight: "regular", style: "italic",
      font: ("TH Sarabun New", "Times New Roman"),
    )[
      #if it.numbering != none [
        #numbering("1)", counter(heading).get().at(2))
        #h(0.5em)
      ]
      #it.body
    ]
    #v(0.5em, weak: true)
  ]

  // ── FIGURES ───────────────────────────────────────────────────────────────
  set figure(numbering: "1")
  show figure.where(kind: image): set figure(supplement: [Fig.])
  show figure.where(kind: table): set figure(numbering: "I")
  show figure.where(kind: table): set figure.caption(position: top)

  show figure.where(kind: table): it => [
    #v(1em, weak: true)
    #align(center)[
      #text(size: 12pt)[
        #smallcaps([Table #it.counter.display(it.numbering)]) \
        #v(0.5em, weak: true)
        #smallcaps(it.caption.body)
        #v(0.8em, weak: true)
        #it.body
      ]
    ]
    #v(1em, weak: true)
  ]

  show figure.where(kind: image): it => [
    #v(1em, weak: true)
    #align(center)[
      #it.body
      #v(0.8em, weak: true)
      #text(size: 12pt)[
        #it.caption.supplement #it.counter.display(it.numbering). #it.caption.body
      ]
    ]
    #v(1em, weak: true)
  ]

  // ── EQUATIONS ─────────────────────────────────────────────────────────────
  set math.equation(numbering: "(1)")
  show math.equation: set block(spacing: 1.2em)

  // ─────────────────────────────────────────────────────────────────────────
  // TITLE
  // ─────────────────────────────────────────────────────────────────────────
  v(1em)
  align(center)[
    #set par(justify: false, first-line-indent: 0pt)
    #text(
      size: 24pt, weight: "bold",
      font: ("TH Sarabun New", "Times New Roman"),
    )[#title]
  ]

  // ── AUTHORS ───────────────────────────────────────────────────────────────
  v(1.5em)
  align(center)[
    #set par(justify: false, first-line-indent: 0pt)
    #grid(
      columns: (1fr,) * calc.min(authors.len(), 3),
      column-gutter: 1em,
      row-gutter: 1.5em,
      ..authors.map(author => [
        #text(size: 12pt)[
          #author.name
          #let r = author.at("ref", default: "")
          #if r != "" [#super[#r]]
        ] \
        #text(size: 11pt, style: "italic")[#author.affiliation] \
        #let e = author.at("email", default: "")
        #if e != "" [
          #text(size: 10pt)[#e]
        ]
      ])
    )
  ]

  v(1.5em)

  // ── ABSTRACT & KEYWORDS ───────────────────────────────────────────────────
  // inset: 1em (แคบกว่าเดิม 2em) + justify:true scoped เฉพาะส่วนนี้
  if abstract != [] [
    #set par(first-line-indent: 0pt, justify: true)
    #block(inset: (x: 3em))[
      #set text(size: 12pt, weight: "regular")
      #h(1em) _บทคัดย่อ (Abstract)_ --- #abstract
      #if keywords.len() > 0 [
        #v(0.5em)
        #h(1em) _คำสำคัญ (Index Terms)_ --- #keywords.join(", ")
      ]
    ]
  ]

  v(1.5em)

  // ── TWO-COLUMN BODY ───────────────────────────────────────────────────────
  show: rest => columns(2, gutter: 4.22mm, rest)
  body
}
