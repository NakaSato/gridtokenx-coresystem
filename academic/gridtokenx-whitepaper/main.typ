#set page(paper: "a4", margin: 2.5cm)
#set text(font: "Libertinus Serif", size: 11pt)
#set heading(numbering: "1.")

#show link: set text(fill: blue)
#show cite: set text(fill: green.darken(20%))

#let title = [GridTokenX: A Decentralized Physical Infrastructure Network for Real-Time Energy Trading]
#let authors = (
  (name: "Chanthawat Kiriyadee", email: "chanthawat@gridtokenx.com"),
)

#align(center)[
  #block(text(weight: 700, 1.75em, title))
  #v(1em)
  #authors.map(a => [
    #text(1.2em, a.name)     #text(0.9em, a.email)
  ]).join(h(2em))
  #v(0.5em)
  #text(0.95em, [GridTokenX Core System Project])
  #linebreak()
  #text(0.9em, [Version: June 2026])
  #v(0.75em)
  #text(0.9em, [Keywords: decentralized physical infrastructure networks; peer-to-peer energy trading; Solana; smart meters; renewable energy certificates; grid-aware markets])
]

#v(2em)

#block(
  inset: (x: 2em),
  align(center)[
    #text(weight: 700, [Abstract])     #v(0.5em)
    #include "sections/abstract.typ"
  ]
)

#v(2em)

#include "sections/01_introduction.typ"
#include "sections/02_related_work.typ"
#include "sections/02_methodology.typ"
#include "sections/02_blockchain.typ"
#include "sections/03_iot_edge.typ"
#include "sections/04_market_settlement.typ"
#include "sections/05_governance_iam.typ"
#include "sections/06_tokenomics.typ"
#include "sections/08_security_analysis.typ"
#include "sections/09_grid_awareness.typ"
#include "sections/10_evaluation.typ"
#include "sections/07_conclusion.typ"

= Author Note

This manuscript describes an open-source protocol and reference implementation. Unless a deployment result is explicitly labeled as measured, quantitative values should be interpreted as design targets, analytical capacity estimates, or evaluation methodology. The author is affiliated with the GridTokenX project and has a direct interest in the protocol described in this paper.

#v(2em)
#bibliography("refs.bib", style: "apa")
