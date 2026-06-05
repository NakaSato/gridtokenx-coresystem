#set page(paper: "a4", margin: 2.5cm)
#set text(font: ("Libertinus Serif", "Sarabun", "TH Sarabun New", "Noto Serif Thai"), size: 11pt)
#set heading(numbering: "1.")

#show link: set text(fill: blue)
#show cite: set text(fill: green.darken(20%))

#let title = [GridTokenX: เครือข่ายโครงสร้างพื้นฐานทางกายภาพแบบกระจายศูนย์สำหรับการซื้อขายพลังงานแบบเรียลไทม์]
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
  #text(0.95em, [โครงการ GridTokenX Core System])
  #linebreak()
  #text(0.9em, [เวอร์ชัน: มิถุนายน 2026])
  #v(0.75em)
  #text(0.9em, [คำสำคัญ: Decentralized Physical Infrastructure Networks; peer-to-peer energy trading; Solana; smart meters; renewable energy certificates; grid-aware markets])
]

#v(2em)

#block(
  inset: (x: 2em),
  align(center)[
    #text(weight: 700, [บทคัดย่อ])     #v(0.5em)
    #include "sections_th/abstract.typ"
  ]
)

#v(2em)

#include "sections_th/01_introduction.typ"
#include "sections_th/02_related_work.typ"
#include "sections_th/02_methodology.typ"
#include "sections_th/02_blockchain.typ"
#include "sections_th/03_iot_edge.typ"
#include "sections_th/04_market_settlement.typ"
#include "sections_th/05_governance_iam.typ"
#include "sections_th/06_tokenomics.typ"
#include "sections_th/08_security_analysis.typ"
#include "sections_th/09_grid_awareness.typ"
#include "sections_th/10_evaluation.typ"
#include "sections_th/07_conclusion.typ"

= หมายเหตุผู้เขียน

ต้นฉบับนี้อธิบายโปรโตคอลและ reference implementation แบบโอเพนซอร์ส เว้นแต่ข้อความใดจะระบุอย่างชัดเจนว่าเป็นผลการวัดจริง ค่าตัวเลขเชิงปริมาณควรถูกตีความเป็นเป้าหมายการออกแบบ การประมาณเชิงวิเคราะห์ หรือระเบียบวิธีประเมินผล ผู้เขียนมีส่วนเกี่ยวข้องกับโครงการ GridTokenX และมีผลประโยชน์โดยตรงในโปรโตคอลที่อธิบายในบทความนี้

#v(2em)
#bibliography("refs.bib", style: "apa")
