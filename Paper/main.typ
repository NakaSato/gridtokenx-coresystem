#import "ieee-template.typ": ieee-conf
#import "@preview/equate:0.3.3": equate

#show: ieee-conf.with(
  title: [การออกแบบและประเมินเชิงสถาปัตยกรรมของระบบซื้อขายพลังงานแสงอาทิตย์แบบ Peer-to-Peer ผ่าน Smart Contract บนเครือข่าย Solana-compatible Consortium ในระบบจำลอง],
  authors: (
    (
      name: "จันทร์ธวัฒ กิริยาดี",
      affiliation: [
        สาขาวิศวกรรมคอมพิวเตอร์และปัญญาประดิษฐ์ (Computer Engineering and Artificial Intelligence) \
        มหาวิทยาลัยหอการค้าไทย (University of the Thai Chamber of Commerce) \
        กรุงเทพมหานคร, ประเทศไทย
      ],
      email: "2410717302003@live4.utcc.ac.th",
    ),
  ),
  abstract: [ระบบผลิตไฟฟ้าจากพลังงานแสงอาทิตย์บนหลังคาที่เพิ่มขึ้นทำให้ผู้ใช้ไฟฟ้าจำนวนมากมีพลังงานคงเหลือและต้องการซื้อขายกันเอง แต่การซื้อขายไฟฟ้าระหว่างกันโดยตรงแบบ Peer-to-Peer (P2P) ยังทำได้ยาก เพราะข้อจำกัดของโครงข่ายไฟฟ้าและการขาดกลไกตั้งราคาที่โปร่งใส บทความนี้เสนอการออกแบบและประเมินเชิงสถาปัตยกรรมของระบบซื้อขายพลังงาน P2P บนเครือข่าย consortium blockchain แบบ permissioned ที่กำกับดูแลได้และมีต้นทุนธุรกรรมคาดการณ์ได้ หัวใจของการออกแบบคือการแยกการตรวจสอบข้อมูลออกจากการชำระธุรกรรมอย่างชัดเจน โดยการตรวจสอบนอกเชนทำผ่าน Aggregator Bridge ที่ยืนยันลายเซ็น Ed25519 ของค่าอ่านมาตรวัด ก่อนจับคู่คำสั่งด้วยกลไก Continuous Double Auction (CDA) ขณะที่การชำระบนเชนบันทึกเฉพาะรายการที่ผ่านการตรวจสอบและบังคับเงื่อนไขความถูกต้องในทุกขั้นตอน คุณค่าของงานจึงไม่ได้อยู่ที่องค์ประกอบใดองค์ประกอบหนึ่ง แต่อยู่ที่การประสานองค์ประกอบทั้งหมดเข้าด้วยกัน การประเมินบนระบบจำลองให้ผลที่สอดคล้องกับแนวคิดนี้ กล่าวคือ เส้นทางรับข้อมูลรองรับมาตรวัด 80 เครื่องที่อัตราเชิงออกแบบ 5.33 รายการต่อวินาทีโดยไม่มีข้อมูลสูญหาย และเมื่อเพิ่มภาระแบบขั้นบันไดถึง 640 เครื่องยังคงสัดส่วนการสูญหายไม่เกิน 0.03% โดยอัตราการรับข้อมูลที่วัดได้เป็น lower bound ของไคลเอนต์ผู้ส่งเดียว เครื่องจับคู่คำสั่งประมวลผลได้ประมาณ 3.1 × 10#super[4] คู่คำสั่งต่อวินาที และการชำระบนเชนใช้ 96,707 compute units ต่อคู่คำสั่ง หรือราว 48% ของงบประมาณตั้งต้น ขณะที่ปริมาณงานของเส้นทางชำระจริงบน validator เดี่ยววัดได้ราว 0.5 ธุรกรรมต่อวินาที ซึ่งถูกผูกกับการเขียนบัญชีส่วนกลางโดยการออกแบบ แต่ยังรองรับได้ราว 450 การชำระต่อหน้าต่างเคลียร์ตลาด 900 วินาที เกินความต้องการของภาระงานที่ทดสอบ ผลเหล่านี้สนับสนุนการใช้บล็อกเชนเป็นชั้นชำระธุรกรรมแบบบาง ทั้งนี้เป็นการประเมินเชิงสถาปัตยกรรมบนระบบจำลอง ยังไม่ใช่การวัดจากระบบไฟฟ้าจริง],
  keywords: (
    "Consortium Blockchain",
    "Peer-to-Peer",
    "Continuous Double Auction",
    "Proof of Authority",
    "Microservices"
  ),
)

// Per-line equation numbering + shared alignment for grouped equation blocks.
#show: equate.with(breakable: true, sub-numbering: true)
#set math.equation(numbering: "(1.1)")

#include "sections/introduction.typ"
#include "sections/related-work.typ"
#include "sections/threat-model.typ"
#include "sections/settlement-model-invariants.typ"
#include "sections/pricing-market-mechanism.typ"
#include "sections/system-design.typ"
#include "sections/experimental-setup.typ"
#include "sections/evaluation.typ"
#include "sections/evaluation-bench.typ"
#include "sections/scale-onchain-validation.typ"
#include "sections/discussion_limitations.typ"
#include "sections/conclusion.typ"

#bibliography("references.bib", style: "ieee", title: [REFERENCES])
