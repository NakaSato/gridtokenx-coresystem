#heading(level: 1)[RELATED WORK] <sec:related-work>

เทคโนโลยีบล็อกเชนถือกำเนิดจาก Bitcoin @nakamoto2008bitcoin ในฐานะระบบบัญชีแยกประเภทแบบกระจายศูนย์ที่ไม่ต้องอาศัยตัวกลาง และขยายขีดความสามารถสู่การประมวลผล Smart Contract ด้วย Ethereum @buterin2014ethereum @wood2014ethereum ภาพรวมของเทคโนโลยีและการจำแนกประเภทเครือข่ายแบบ permissionless และ permissioned ได้รับการสรุปไว้โดย NIST @yaga2018blockchain ซึ่งเป็นกรอบอ้างอิงในการเลือกสถาปัตยกรรมเครือข่ายให้เหมาะกับข้อกำหนดด้านการกำกับดูแล

ในบริบทของตลาดพลังงานแบบ Peer-to-Peer มีงานวิจัยจำนวนมากที่ศึกษากลไกตลาดและการออกแบบการประมูล Mengelkamp และคณะ @mengelkamp2018blockchain เปรียบเทียบการออกแบบตลาดพลังงานท้องถิ่นและกลยุทธ์การเสนอราคา ขณะที่ Munsing และคณะ @munsing2017blockchains เสนอการใช้บล็อกเชนเพื่อกระจายการหาค่าเหมาะที่สุด (decentralized optimization) ของทรัพยากรพลังงานในเครือข่ายไมโครกริด งานเหล่านี้ชี้ให้เห็นถึงศักยภาพของบล็อกเชนในการรองรับการซื้อขายพลังงานโดยตรงระหว่างผู้ใช้ แต่ส่วนใหญ่ยังประเมินบนเครือข่ายสาธารณะที่มีข้อจำกัดด้านต้นทุนธุรกรรมและความหน่วงในการยืนยันบล็อก

เพื่อตอบโจทย์ด้านการกำกับดูแลและความสามารถในการคาดการณ์ต้นทุน งานวิจัยจำนวนหนึ่งจึงหันมาใช้เครือข่ายแบบ Consortium หรือ permissioned Kang และคณะ @kang2017consortium ใช้ consortium blockchain สำหรับการซื้อขายไฟฟ้าแบบ Peer-to-Peer ระหว่างยานยนต์ไฟฟ้าแบบ plug-in และ Hyperledger Fabric @androulaki2018hyperledger เป็นตัวอย่างของระบบปฏิบัติการแบบกระจายสำหรับเครือข่าย permissioned ที่กำหนดสิทธิ์ผู้เข้าร่วมได้ชัดเจน ในด้านฉันทามติ ปัญหา Byzantine Generals @lamport1982byzantine และอัลกอริทึม Practical Byzantine Fault Tolerance @castro1999practical เป็นรากฐานเชิงทฤษฎีของการยืนยันธุรกรรมในเครือข่ายที่มีโหนดจำนวนจำกัด ซึ่งสอดคล้องกับสมมติฐานของฉันทามติแบบ Proof of Authority ที่ใช้ในงานนี้

งานทบทวนวรรณกรรมล่าสุดสะท้อนว่าหัวข้อนี้ยังเป็นพื้นที่วิจัยที่เปิดอยู่ โดย Tanis และคณะ @tanis2025p2preview ทบทวนโครงสร้างตลาด ชั้นการดำเนินงาน และระบบหลายพลังงานของการซื้อขายแบบ Peer-to-Peer อย่างครอบคลุม ขณะที่ Bhavana และคณะ @bhavana2024blockchain สำรวจการประยุกต์บล็อกเชนในตลาดพลังงานและห่วงโซ่อุปทานไฮโดรเจนสีเขียว และชี้ว่าความสามารถในการขยายขนาด (scalability) ต้นทุน และความสอดคล้องด้านการกำกับดูแลยังเป็นความท้าทายหลัก นอกจากนี้การประเมินเปรียบเทียบกลไกฉันทามติสำหรับการซื้อขายพลังงานแบบ Peer-to-Peer ในไมโครกริด @bhavana2025consensus สนับสนุนการเลือกฉันทามติแบบ permissioned ที่ควบคุมสิทธิ์ได้ ซึ่งสอดคล้องกับสมมติฐาน PoA ที่ใช้ในงานนี้

ต่างจากงานข้างต้น บทความนี้มุ่งเน้นการออกแบบและประเมินสถาปัตยกรรมของระบบจำลองที่แยกการตรวจสอบนอกเชน (off-chain verification) ผ่าน Aggregator Bridge ออกจากชั้น Settlement บนบล็อกเชนอย่างชัดเจน ขอบเขตของงานนี้จึงเป็นการออกแบบและประเมินสถาปัตยกรรม ไม่ใช่การรายงานผลวัดจากเครือข่ายไฟฟ้าภาคสนามหรือ Solana production network โดยข้อมูลพลังงานที่ใช้ในต้นแบบมาจาก AMI Simulator และผลที่บันทึกบนบล็อกเชนเป็น Settlement event ที่ผ่านการตรวจสอบจาก Backend/Aggregator Bridge แล้ว ซึ่งสอดคล้องกับแนวทางเบื้องต้นในการทดสอบระบบควบคุมไมโครกริด @ieee2030_8 ตำแหน่งของงานนี้เทียบกับงานที่ใช้บล็อกเชนสำหรับตลาดพลังงานแบบ Peer-to-Peer สรุปไว้ใน @tbl:comparison โดยจุดต่างหลักคือการผสาน CDA แบบแบ่งโซนบนเครือข่าย consortium แบบ PoA เข้ากับการแยกชั้นตรวจสอบข้อมูลมาตรวัด (Ed25519/DLMS) นอกเชนออกจากชั้น settlement อย่างชัดเจน ทั้งนี้ @tbl:comparison เป็นการเทียบเชิงคุณภาพ (qualitative positioning) เนื่องจากงานเหล่านี้รันบนเครือข่าย ชุดข้อมูล และสมมติฐานที่ต่างกัน จึงไม่มีตัวชี้วัดเชิงปริมาณร่วมที่เทียบกันได้โดยตรง

#figure(
  placement: top,
  scope: "parent",
  caption: [Positioning of this work vs prior blockchain-based P2P energy-trading studies.],
  table(
    columns: (auto, auto, auto, auto, auto),
    align: (left + horizon, left + horizon, left + horizon, left + horizon, left + horizon),
    table.header(
      [งาน], [เครือข่าย], [ฉันทามติ], [กลไกตลาด], [แยก off/on-chain],
    ),
    [Mengelkamp @mengelkamp2018blockchain], [Public (LEM)], [Public], [Local market / bidding], [ไม่แยกชัดเจน],
    [Munsing @munsing2017blockchains], [Public], [Public], [Decentralized optimization], [ไม่แยกชัดเจน],
    [Kang @kang2017consortium], [Consortium], [Consortium], [Iterative double auction], [บางส่วน],
    [Hyperledger Fabric @androulaki2018hyperledger], [Permissioned], [Pluggable (Raft/BFT)], [แพลตฟอร์ม (ไม่เจาะตลาด)], [—],
    [งานนี้ (This work)], [Consortium \ (Solana-compatible)], [PoA (governance)], [CDA price-time \ แบ่งโซน], [แยกชัดเจน + \ Ed25519/DLMS telemetry],
  ),
) <tbl:comparison>
