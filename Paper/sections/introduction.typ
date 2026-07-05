= INTRODUCTION <sec:introduction>

การขยายตัวของพลังงานหมุนเวียน (Renewable Energy: RE) ทำให้ผู้ใช้ไฟฟ้าจำนวนมากเปลี่ยนบทบาทจากผู้บริโภคเพียงอย่างเดียวไปสู่การเป็นผู้ผลิตและผู้บริโภคพลังงานในเวลาเดียวกัน (Prosumer) การเปลี่ยนแปลงนี้สร้างความท้าทายต่อโครงข่ายไฟฟ้าแบบดั้งเดิม ซึ่งออกแบบมาสำหรับการจ่ายไฟจากศูนย์กลางไปยังผู้ใช้ปลายทางเป็นหลัก งานวิจัยด้านตลาดพลังงานแบบ Peer-to-Peer จึงให้ความสำคัญกับกลไกซื้อขายที่รักษาทั้งข้อจำกัดของโครงข่ายและความน่าเชื่อถือของระบบไฟฟ้า @tushar2020p2p @morstyn2019bilateral @paudel2019peer

การเปลี่ยนผ่านไปสู่ระบบ Smart Grid บริบทประเทศไทยตามแผนแม่บทการพัฒนาโครงข่ายไฟฟ้าประเทศไทย มีการใช้โครงสร้างพื้นฐานมาตรวัดขั้นสูง (Advanced Metering Infrastructure: AMI) ทำให้ข้อมูลการผลิตและการใช้พลังงานมีความละเอียดมากขึ้น การบูรณาการทรัพยากรพลังงานแบบกระจายศูนย์ (Distributed Energy Resources: DER) เช่น ระบบผลิตไฟฟ้าพลังงานแสงอาทิตย์บนหลังคา สถานีอัดประจุยานยนต์ไฟฟ้า (EV) และระบบกักเก็บพลังงานด้วยแบตเตอรี่ (Battery Energy Storage System: BESS) ต้องคำนึงถึงข้อกำหนดด้านการเชื่อมต่อ DER, Microgrid controller, Islanding และข้อจำกัดของโครงข่ายแรงดันต่ำ @ieee1547_2018 @ieee2030_7 @guerrero2019decentralized

บทความนี้มีส่วนสนับสนุนหลักสามประการ ประการแรก การออกแบบสถาปัตยกรรมแบบลดการพึ่งพากัน (decoupled) ที่แยกการตรวจสอบข้อมูลนอกเชนผ่าน Aggregator Bridge ได้แก่ การตรวจลายเซ็น Ed25519 ของข้อมูลมาตรวัดตามมาตรฐาน DLMS/COSEM และการประเมินเงื่อนไข Grid stability ร่วมกับการจับคู่คำสั่งด้วย Continuous Double Auction (CDA) ออกจากการชำระธุรกรรมบนเชน (on-chain settlement) อย่างชัดเจน ประการที่สอง การออกแบบขอบเขตความเชื่อถือ (trust boundary) ของการชำระธุรกรรมบนเครือข่าย Anchor/Solana-compatible แบบ Proof of Authority (PoA) consortium โดยบล็อกเชนตรวจสอบลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขาย การกันส่งซ้ำผ่าน order nullifier และสถานะ escrow ขณะที่เงื่อนไขปริมาณพลังงานและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ทำให้บล็อกเชนทำหน้าที่เป็นชั้น settlement และ audit อย่างชัดเจน (ดู@sec:settlement-model) และประการที่สาม การพัฒนาชุดจำลอง AMI ที่อาศัยแบบจำลองโครงข่ายด้วย pandapower และ Smart Meter Simulator เพื่อสร้างข้อมูลมาตรวัดแบบ deterministic พร้อมการวัดอัตราการรับข้อมูลของเส้นทาง telemetry ingest เบื้องต้น จุดต่างหลักจากงานก่อนหน้า (ดู@sec:related-work) ไม่ได้อยู่ที่องค์ประกอบเดี่ยว (consortium blockchain, CDA หรือ off-chain oracle ซึ่งล้วนมีในงานก่อนหน้า) แต่อยู่ที่การผสานองค์ประกอบเหล่านี้เข้าด้วยกันผ่านขอบเขตความเชื่อถือที่นิยามชัด คือ CDA แบบแบ่งโซนบนเครือข่าย consortium PoA ที่แยกชั้นตรวจสอบ telemetry (Ed25519/DLMS) นอกเชนออกจากชั้น settlement อย่างชัดเจน โดยกลไกการชำระบนเชนที่เป็นแกนของงานนี้คือการส่งมอบพร้อมชำระเงินแบบ atomic (DvP) ที่รวมการตรวจลายเซ็น Ed25519 ของทั้งสองฝ่าย การกันส่งซ้ำแบบ partial-fill ผ่าน order nullifier และเพดานการไหลข้ามโซนไว้เป็นชุดเงื่อนไขความถูกต้องเดียวที่บังคับใช้ในธุรกรรมเดียว ซึ่งงานก่อนหน้ามิได้ระบุไว้อย่างเป็นระบบ ทั้งนี้ขอบเขตของงานเป็นการออกแบบและประเมินเชิงสถาปัตยกรรมบนระบบจำลอง ไม่ใช่การวัดจากเครือข่ายไฟฟ้าภาคสนามหรือเครือข่าย Solana production ส่วนสนับสนุนเชิงประจักษ์ของงานจึงเป็นการบ่งชี้คุณลักษณะ (characterization) ของระบบเดี่ยวแบบทำซ้ำได้ ได้แก่ อัตราการรับข้อมูล ต้นทุน compute-unit และปริมาณงานของเส้นทางชำระ มิใช่การเปรียบเทียบเชิงปริมาณแบบ head-to-head กับแพลตฟอร์มอื่น ซึ่งเป็นงานในอนาคต

ในด้านกลไกเชิงเศรษฐศาสตร์ ระบบใช้โทเคนพลังงาน (energy token) ที่ออกจากการผลิตจริงและรับรองด้วย Renewable Energy Certificate (REC; ระบบบนเชนใช้ตัวระบุชื่อ erc) ร่วมกับเหรียญ stablecoin ที่ตรึงค่ากับเงินบาท (THBG) สำหรับการตั้งราคาและชำระธุรกรรม และโทเคน GRX สำหรับการ stake และการกำกับดูแล (governance) โดยรายละเอียดแบบจำลองราคาอธิบายไว้ใน@sec:pricing-market-mechanism และรายละเอียดของโปรแกรมที่เกี่ยวข้องอธิบายไว้ใน@sec:smart-contract-programs

บทความนี้จัดเรียงเนื้อหาดังนี้@sec:related-work ทบทวนงานวิจัยที่เกี่ยวข้องด้านบล็อกเชนและตลาดพลังงานแบบ Peer-to-Peer @sec:threat-model กำหนดแบบจำลองระบบ ความเชื่อถือ และผู้โจมตี@sec:settlement-model อธิบายแบบจำลองการชำระธุรกรรมของระบบ@sec:pricing-market-mechanism อธิบายกลไกราคา CDA และการคำนวณ settlement @sec:system-architecture อธิบายสถาปัตยกรรม การเชื่อมต่อ และรายละเอียด implementation หลัก@sec:experimental-setup ระบุรายละเอียดการทดลองและภาระงาน@sec:evaluation สรุปการประเมินเชิงสถาปัตยกรรม และ@sec:discussion_limitations อภิปรายผล ข้อจำกัด และแนวทางพัฒนาระบบในอนาคต ตัวย่อที่ใช้บ่อยในบทความสรุปไว้ใน@tbl:acronyms

#import "../glossary.typ": glossary-entries

#figure(
  kind: table,
  {
    set par(first-line-indent: 0pt, leading: 0.45em)
    let sorted = glossary-entries.sorted(key: e => lower(e.short))
    table(
      columns: (auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + top, left + top),
      table.header([ตัวย่อ], [ความหมาย]),
      ..sorted
        .map(e => (
          strong(e.short),
          if "description" in e [#e.long (#e.description)] else [#e.long],
        ))
        .flatten()
    )
  },
  caption: [Abbreviations used in this paper.],
) <tbl:acronyms>
