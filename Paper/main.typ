#import "ieee-template.typ": ieee-conf
#import "@preview/equate:0.3.3": equate

#show: ieee-conf.with(
  title: [การพัฒนาระบบซื้อขายพลังงานแสงอาทิตย์แบบ Peer-to-Peer ผ่าน Smart Contract บน Solana Consortium Blockchain],
  authors: (
    (
      name: "จันทร์ธวัฒ กิริยาดี",
      ref: "1",
      affiliation: [
        สาขาวิศวกรรมคอมพิวเตอร์และปัญญาประดิษฐ์ (Computer Engineering and Artificial Intelligence) \
        มหาวิทยาลัยหอการค้าไทย (University of the Thai Chamber of Commerce) \
        กรุงเทพมหานคร, ประเทศไทย
      ],
      email: "2410717302003@live4.utcc.ac.th",
    ),
  ),
  abstract: [การเติบโตของการผลิตไฟฟ้าพลังงานแสงอาทิตย์บนหลังคา นำมาซึ่งพลังงานส่วนเกินที่เหลือจากการใช้ และยังไม่สามารถซื้อขายไฟฟ้าแบบ Peer-to-Peer (P2P) ได้โดยตรง เนื่องจากข้อจำกัดด้านโครงข่าย DSO และการขาดกลไกราคาที่เหมาะสม บทความนี้นำเสนอการพัฒนาระบบซื้อขายพลังงาน P2P ภายใต้เทคโนโลยีบล็อกเชน (Blockchain) โดยใช้กลไกตลาดประมูลสองทางแบบต่อเนื่อง (Continuous Double Auction: CDA) ขับเคลื่อนผ่าน Smart Contract บนเครือข่าย Consortium Blockchain พร้อมทั้งใช้ฉันทามติแบบ Proof of Authority (PoA) เพื่อตอบโจทย์ด้านการกำกับดูแล (Governance) และความรวดเร็วในการยืนยันธุรกรรม เพื่อรองรับการขยายตัวของผู้ใช้งาน ระบบถูกพัฒนาขึ้นบนสถาปัตยกรรม Microservices โดยมี NATS JetStream บริหารจัดการลำดับข้อมูลในสภาวะที่มีปริมาณการใช้งานหนาแน่น จุดเด่นของงานนี้คือการออกแบบระบบแบบลดการพึ่งพากัน (Decoupling) โดยแยกกระบวนการตรวจสอบข้อมูลนอกเชน (Off-chain) ผ่าน Aggregator Bridge ที่ทำงานร่วมกับสมาร์ทมิเตอร์ ออกจาก Settlement Layer บนบล็อกเชน ส่งผลให้ Smart Contract บันทึกเฉพาะธุรกรรมที่ผ่านการยืนยันแล้วเท่านั้น ผลการจำลองเพื่อประเมินเส้นทางรับข้อมูลมาตรวัดด้วยสมาร์ทมิเตอร์จำนวน 80 เครื่อง ที่บีบอัดเวลาประมาณ 60 เท่าเมื่อเทียบกับรอบการส่งข้อมูลของมาตรวัดจริง (60x Compressed Real-time) พบว่า Aggregator Bridge รับและตรวจสอบลายเซ็นค่าอ่านได้อย่างต่อเนื่องที่อัตราเชิงออกแบบ 5.33 รายการต่อวินาที (readings/s) โดยไม่มีการสูญหายของข้อมูล ผลลัพธ์นี้แสดงให้เห็นว่าเส้นทางรับข้อมูลรองรับภาระที่กำหนดของมาตรวัด 80 เครื่องได้โดยไม่มีการสูญหายในการรันหนึ่งรอบ ทั้งนี้ขอบเขตความจุสูงสุดของระบบและการประเมินประสิทธิภาพของเส้นทาง settlement บนบล็อกเชนเป็นงานในลำดับถัดไป ซึ่งเป็นรากฐานสำคัญสำหรับการต่อยอดสู่อุตสาหกรรมพลังงานในอนาคต],
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
#include "sections/discussion_limitations.typ"
#include "sections/conclusion.typ"

#bibliography("references.bib", style: "ieee", title: [REFERENCES])
