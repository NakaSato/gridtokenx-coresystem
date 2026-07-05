#import "@preview/cetz:0.5.2"

= SETTLEMENT MODEL <sec:settlement-model>

== Architecture Overview
ระบบแบ่งความรับผิดชอบออกเป็นสองโดเมนความเชื่อถือ (trust domain) ที่เชื่อมต่อกันผ่านจุดเดียว โดเมนนอกเชน (off-chain) ทำหน้าที่ตรวจสอบและจับคู่ ประกอบด้วยชั้นมาตรวัด (Smart Meter Simulator ตามมาตรฐาน AMI และ DLMS/COSEM) ที่ป้อนข้อมูลเข้าสู่ Aggregator Bridge เพื่อยืนยันลายเซ็น Ed25519 และคัดกรองข้อมูล ก่อนส่งต่อให้ Trading Service จับคู่คำสั่งด้วยอัลกอริทึม Continuous Double Auction (CDA) โดยมี IAM Service และ Notification Service สนับสนุนด้านการระบุตัวตนและการแจ้งเตือน ส่วนโดเมนบนเชน (on-chain) ทำหน้าที่ชำระธุรกรรมและบันทึกหลักฐาน ประกอบด้วยกลุ่มโปรแกรม Anchor (registry, trading, oracle, energy-token, governance และ treasury) บนเครือข่าย Solana-compatible แบบ permissioned (consortium) ที่บันทึกสถานะลงบัญชี PDA และ Event log

การข้ามจากโดเมนนอกเชนไปยังโดเมนบนเชนเกิดขึ้นผ่าน Chain Bridge เพียงทางเดียว ซึ่งเป็นบริการเดียวที่ติดต่อกับ Solana RPC โดยตรง โดยรับคำสั่งเขียนผ่าน NATS JetStream และให้บริการอ่านสถานะผ่าน ConnectRPC บนช่องทางที่ป้องกันด้วย mTLS โปรแกรมบนเชนเป็น Anchor program @anchorDocs ที่ทำงานบน Solana Virtual Machine (SVM) @yakovenkoSolanaWhitepaper และใช้ Program Derived Address (PDA) เพื่อสร้างบัญชีที่ตรวจสอบ ownership ได้แบบ deterministic การออกแบบที่แยกสองโดเมนเช่นนี้ทำให้การตรวจสอบเชิงวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์เกิดขึ้นก่อนการบันทึกธุรกรรม ขณะที่บล็อกเชนทำหน้าที่เป็นชั้นชำระธุรกรรมและตรวจสอบย้อนหลังที่บาง (thin settlement and audit layer) รายละเอียดของบริการ การเชื่อมต่อ และแผนภาพสถาปัตยกรรมทั้งหมดอยู่ใน@sec:system-architecture ทั้งนี้บทความนี้เป็นการประเมินเชิงสถาปัตยกรรมบนระบบจำลอง ไม่ใช่ผลวัดจากเครือข่าย Solana production

== Settlement Model
แบบจำลองการชำระธุรกรรมแยกความรับผิดชอบออกเป็นสองชั้นที่มีขอบเขตความเชื่อถือต่างกันอย่างชัดเจน ชั้นนอกเชน (off-chain) ทำหน้าที่ตรวจสอบและจับคู่ ประกอบด้วย Aggregator Bridge ที่ยืนยันลายเซ็น Ed25519 ของค่าอ่านมาตรวัด ตรวจรูปแบบข้อมูลตามมาตรฐาน DLMS/COSEM และประเมินเงื่อนไขปริมาณพลังงานคงเหลือ (available surplus) ร่วมกับ Grid stability และ Trading Service ที่จับคู่คำสั่งซื้อขายด้วยอัลกอริทึม Continuous Double Auction (CDA) ผลลัพธ์ของชั้นนี้คือคู่คำสั่งที่ผ่านการตรวจสอบแล้วพร้อม order payload ที่ลงนามโดยทั้งสองฝ่าย ส่วนชั้นบนเชน (on-chain) คือ Anchor program @anchorDocs ที่ทำหน้าที่เป็นชั้นชำระธุรกรรมและบันทึกหลักฐานแบบบาง (thin settlement and audit layer) โดยรับเฉพาะคู่คำสั่งที่ผ่านการตรวจสอบแล้วและบันทึกผลที่ตรวจสอบย้อนหลังได้

ก่อนบันทึก settlement โปรแกรมบนเชนบังคับใช้เฉพาะเงื่อนไขที่ตรวจสอบได้จาก payload และสถานะบัญชี ได้แก่ การตรวจ account ownership ลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload การกันส่งซ้ำผ่านบัญชี order nullifier และความถูกต้องของสถานะ escrow ส่วนเงื่อนไขที่ต้องอาศัยข้อมูลภายนอก เช่น ปริมาณพลังงานคงเหลือและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ก่อนการ submit และไม่ถูกตรวจซ้ำบนเชน การแบ่งหน้าที่เช่นนี้ทำให้บล็อกเชนไม่ต้องไว้วางใจข้อมูลภายนอกโดยตรง แต่ยืนยันได้ว่าทุกการชำระมาจากคู่คำสั่งที่ทั้งสองฝ่ายลงนามจริง โครงสร้างบัญชีทั้งหมดใช้ Program Derived Address (PDA) เพื่อแยก state ของแต่ละธุรกรรมและตรวจสอบ ownership ได้แบบ deterministic รายละเอียดของโปรแกรมและบัญชี PDA อธิบายใน@sec:smart-contract-programs @solanaPdaDocs

== Atomic Delivery-versus-Payment
คู่คำสั่งที่จับคู่แล้วถูกชำระผ่านคำสั่ง `settle_offchain_match` ของโปรแกรม trading ซึ่งทำงานแบบส่งมอบพร้อมชำระเงิน (Delivery-versus-Payment: DvP) ภายในธุรกรรมเดียว กล่าวคือการโอนเงินและการโอนพลังงานเกิดขึ้นพร้อมกันหรือไม่เกิดขึ้นเลย หากการโอนใดล้มเหลวธุรกรรมทั้งหมดจะถูกย้อนกลับ (revert) จึงไม่มีสถานะค้างที่ฝ่ายหนึ่งได้รับโดยอีกฝ่ายไม่ได้รับ ก่อนการโอน โปรแกรมตรวจลายเซ็น Ed25519 ของทั้งผู้ซื้อ (instruction sysvar ดัชนี 0) และผู้ขาย (ดัชนี 1) บนข้อความที่ผูกฟิลด์สำคัญของคำสั่ง ได้แก่ order_id, user, energy_amount, price_per_kwh, side, zone_id และ expires_at ทำให้ดัดแปลงปริมาณหรือราคาหลังการลงนามไม่ได้ จากนั้นตรวจเงื่อนไขการครอสราคา (price crossing) คือราคาจับคู่ต้องอยู่ในช่วง $p_s <= p^* <= p_b$ ตรวจ side ของทั้งสองฝั่ง และตรวจเวลาหมดอายุ

การชำระเป็นแบบ partial-fill โดยบัญชี order nullifier (seed `[nullifier, user, order_id]`) เก็บปริมาณที่ถูกเติมสะสม (filled_amount) แทนค่าบูลีน คำสั่งจึงถูกเติมได้หลายครั้งจนเต็มปริมาณที่ลงนามไว้ แต่ผลรวมจะไม่เกินปริมาณนั้น ($"match" <= "energy_amount" - "filled"$) ทั้งสองฝั่ง สำหรับธุรกรรมข้ามโซน (cross-zone) ที่ใช้สายส่งระหว่างโซน โปรแกรมยังบังคับเพดานการไหลสะสมบนเชน ($"committed_flow" + "match" <= "capacity"$) ส่วนธุรกรรมภายในโซนเดียวกันได้รับการยกเว้นเพราะไม่ใช้สายส่งระหว่างโซน เมื่อผ่านเงื่อนไขทั้งหมด มูลค่ารวมและส่วนแบ่งคำนวณดังนี้ โดยเงิน (currency) ไหลจาก buyer escrow ไปยังตัวเก็บค่าธรรมเนียม/wheeling/loss และ seller escrow ส่วนพลังงาน (energy token) ไหลจาก seller escrow ไปยัง buyer escrow การโอนออกจากบัญชี escrow ทั้งหมดลงนามโดย market_authority PDA ในฐานะเจ้าของบัญชี escrow (ลงนาม CPI การโอนโทเคน) ขณะที่การอนุมัติการชำระธุรกรรมมาจากลายเซ็น Ed25519 ของผู้ซื้อและผู้ขายตามที่อธิบายข้างต้น นอกจากคำสั่งจับคู่เดี่ยวแล้ว โปรแกรมยังมีคำสั่งชำระแบบกลุ่ม (`batch_settle_offchain_match`) ที่รวมได้สูงสุด 4 คู่ต่อหนึ่งธุรกรรมเพื่อลดต้นทุน โดยใช้เงื่อนไขตรวจสอบชุดเดียวกันทั้งหมด (ลายเซ็น Ed25519, order nullifier, การครอสราคา และเพดานการไหลข้ามโซน) และผูกบัญชีจาก payload ที่ลงนามด้วยการตรวจ Program Derived Address (PDA) ของทุกบัญชีที่ส่งเข้ามา

$ V &= "match" dot p^* #<eq:settle-value> \
  "fee" &= floor(V dot phi slash 10000) #<eq:settle-fee> \
  "net"_s &= V - "fee" - w - c_("loss") #<eq:settle-net> $

สมการชุดนี้เป็นรูปแบบจำนวนเต็มแบบปัดลง (fixed-point) บนเชนของ@eq:value ถึง@eq:net ใน@sec:pricing-model โดย $V$ คือมูลค่ารวมที่ออกจาก buyer escrow, $phi$ คือค่าธรรมเนียมตลาด (market_fee_bps), $w$ คือ wheeling charge, $c_("loss")$ คือต้นทุน loss (ดู@eq:loss-cost) และ $"net"_s$ คือยอดสุทธิที่ผู้ขายได้รับ ทั้งนี้การคำนวณทั้งหมดใช้ checked arithmetic แทนการ clamp ค่า กล่าวคือการคูณมูลค่าปฏิเสธกรณี overflow และการหักลบยอดสุทธิของผู้ขายจะ *ปฏิเสธ* ธุรกรรม (require! ด้วย error `ChargesExceedValue`) เมื่อผลรวมของค่าธรรมเนียม wheeling และ loss เกินมูลค่า $V$ แทนการปัดยอดลงเป็นศูนย์ พร้อมเพดานค่าธรรมเนียมเครือข่ายรวมไม่เกิน 20% ของ $V$ และเมื่อตลาดตั้งค่าให้ชำระด้วย THBG ระบบบังคับให้บันทึกมูลค่ารวม (gross) ผ่าน CPI `record_settlement` ไปยังโปรแกรม treasury เพื่อให้ตัวนับยอดชำระกระทบยอดกับกระแสเงินที่ออกจาก escrow จริง

== Consensus
สัญญาอัจฉริยะ (smart contract) ของระบบเป็นโปรแกรม Anchor ที่ทำงานบน Solana Virtual Machine (SVM) การจัดลำดับและการบรรลุฉันทามติของธุรกรรมจึงเป็นหน้าที่ของเครือข่าย Solana-compatible ที่นำโปรแกรมไป deploy มิได้ถูกนิยามหรือปรับแต่งในระดับโปรแกรม กลไกฉันทามติของแพลตฟอร์มแยกออกเป็นสองส่วนที่ทำงานร่วมกัน ได้แก่ Proof of History (PoH) ที่เป็นนาฬิกาเชิงรหัสวิทยา (verifiable clock) สำหรับเรียงลำดับเหตุการณ์ตามเวลาก่อนการลงมติ และ Tower BFT ซึ่งเป็นกลไกลงมติแบบ Byzantine Fault Tolerant ที่พัฒนาต่อยอดจากแนวคิด Practical BFT (PBFT) @castro1999practical สำหรับยืนยันบล็อกและประกาศสิ้นสุดบล็อก (finality) @yakovenkoSolanaWhitepaper

ในการประเมินของงานนี้ โปรแกรม Anchor ถูกรันบนสภาพแวดล้อมทดสอบระดับ SVM (LiteSVM) และ validator แบบโหนดเดียว (localnet) เพื่อตรวจความถูกต้องและวัดต้นทุน compute-unit ของเส้นทาง settlement (ดู@sec:settlement-cost) ดังนั้นคุณสมบัติด้านฉันทามติ เช่น การเลือก leader การลงมติของ validator และเวลา finality แบบหลายโหนด จึงเป็นคุณสมบัติของแพลตฟอร์มที่ไม่ได้ถูกวัดในงานนี้ ส่วนการควบคุมสิทธิ์การเข้าร่วมและการกำกับดูแลของ consortium เป็นชั้น governance ระดับโปรแกรมที่แยกต่างหากจากฉันทามติระดับเครือข่าย รายละเอียดอยู่ใน@sec:consortium-network

== โครงสร้างบล็อกและธุรกรรมการชำระ <sec:tx-structure>
เนื่องจากโปรแกรมทำงานบนเครือข่าย Solana-compatible โครงสร้างบล็อกและส่วนหัวบล็อก (block header) จึงเป็นไปตามนิยามของแพลตฟอร์ม มิได้ถูกปรับแต่งในระดับโปรแกรม แต่ละบล็อกผูกกับช่องเวลา (slot) ที่มีเป้าหมายประมาณ 400 มิลลิวินาที (ดู@sec:consortium-network) ลำดับของธุรกรรมภายในถูกกำหนดด้วยลำดับ Proof of History (PoH) ก่อนการลงมติด้วย Tower BFT ส่วนแต่ละธุรกรรมอ้างอิง blockhash ล่าสุดเพื่อกำหนดอายุและกันการเล่นซ้ำ (replay) ในระดับธุรกรรม โครงสร้างเหล่านี้เป็นคุณสมบัติของแพลตฟอร์ม @yakovenkoSolanaWhitepaper งานนี้จึงเน้นโครงสร้างของธุรกรรมการชำระที่โปรแกรมออกแบบเอง มากกว่ารูปแบบบล็อก ห่วงโซ่บล็อกที่เชื่อมต่อกันด้วย previous blockhash แสดงใน@fig:block-structure

#figure(
  text(size: 6.5pt)[
    #cetz.canvas(length: 1cm, {
      import cetz.draw: *
      let blue = rgb("#5b7aa8")
      let orange = rgb("#c77d3c")
      let gray = rgb("#888888")
      let hl = rgb("#3c6fa0")
      // top chain: five consecutive blocks, slots N−2 … N+2
      let bw = 1.1
      let xs = (0, 1.5, 3.0, 4.5, 6.0)
      let labels = ([N−2], [N−1], [N], [N+1], [N+2])
      for (i, x) in xs.enumerate() {
        let focus = i == 2
        rect((x, 2.0), (x + bw, 2.9), radius: 0.05,
          stroke: (if focus { 0.8pt + hl } else { 0.5pt + gray }),
          fill: (if focus { rgb("#eef3fb") } else { luma(247) }))
        content((x + bw / 2, 2.62), text(6pt, weight: "bold", fill: (if focus { hl } else { gray }))[slot #labels.at(i)])
        content((x + bw / 2, 2.31), text(4.6pt, fill: gray, raw("blockhash")))
      }
      // previous_blockhash links — each block references its predecessor
      for i in range(4) {
        line((xs.at(i + 1), 2.3), (xs.at(i) + bw, 2.3), mark: (end: ">", scale: 0.4), stroke: 0.4pt + gray)
      }
      content((3.55, 3.12), text(5pt, fill: gray, raw("previous_blockhash") + [ ←]))
      // zoom from focus block (slot N) down to its detailed view
      let dx0 = 0.8
      let dx1 = 5.3
      let cx = (dx0 + dx1) / 2
      line((3.0, 2.0), (dx0, 0.97), stroke: (paint: hl, dash: "dashed", thickness: 0.4pt))
      line((3.0 + bw, 2.0), (dx1, 0.97), stroke: (paint: hl, dash: "dashed", thickness: 0.4pt))
      rect((dx0, -2.5), (dx1, 0.97), radius: 0.08, stroke: 0.7pt + blue)
      rect((dx0, 0.0), (dx1, 0.97), stroke: 0.4pt + blue, fill: rgb("#eef3fb"))
      content((cx, 0.74), text(6.5pt, weight: "bold", fill: blue)[Block Header · slot N])
      content((cx, 0.46), text(5.2pt, raw("previous_blockhash") + [ · ] + raw("parent_slot")))
      content((cx, 0.18), text(5.2pt, raw("blockhash") + [ (PoH) · tick height]))
      content((cx, -0.22), text(6pt, weight: "bold")[Transactions — ordered by PoH])
      content((cx, -0.52), text(5.2pt, fill: gray)[• transfer / create-order tx …])
      rect((dx0 + 0.15, -1.02), (dx1 - 0.15, -0.62), radius: 0.04, stroke: 0.5pt + orange, fill: rgb("#fbf0e6"))
      content((cx, -0.82), text(5.2pt, fill: orange.darken(25%), raw("settle_offchain_match") + [ (การชำระ)]))
      content((cx, -1.24), text(5.2pt, fill: gray)[• mint / settle tx อื่น …])
      content((cx, -2.26), text(5.2pt, fill: gray)[PoH ordering → Tower BFT finality])
    })
  ],
  caption: [โครงสร้างบล็อกบนเครือข่าย Solana-compatible (กำหนดโดยแพลตฟอร์ม ไม่ได้ปรับแต่งในระดับโปรแกรม): ห่วงโซ่บล็อกต่อเนื่อง (slot N−2 ถึง N+2) ที่แต่ละบล็อกอ้างอิงบล็อกก่อนหน้าผ่าน previous blockhash ด้านล่างขยายบล็อก slot N ส่วนหัวบล็อก (block header) บรรจุ blockhash ที่ได้จาก PoH และ parent_slot ขณะที่ธุรกรรมภายใน รวมถึงคำสั่งชำระ `settle_offchain_match` (ดู@sec:tx-structure) ถูกจัดลำดับด้วย Proof of History ก่อนการประกาศ finality ด้วย Tower BFT.],
) <fig:block-structure>

ธุรกรรมการชำระหนึ่งรายการประกอบด้วยคำสั่ง settle หนึ่งคำสั่ง ร่วมกับคำสั่งตรวจลายเซ็น Ed25519 สองคำสั่งต่อหนึ่งคู่จับคู่ (ของผู้ซื้อและผู้ขาย) ที่โปรแกรมตรวจผ่าน instruction sysvar โดย payload ของลายเซ็น (signature, public key และข้อความ canonical รวมราว 189 ไบต์ต่อคำสั่ง) อยู่ในส่วนข้อมูลคำสั่ง (instruction data) มิใช่ในบัญชี (accounts) ทำให้ตาราง address lookup table (ALT) ซึ่งบีบอัดเฉพาะรายการบัญชี ไม่สามารถลดขนาดส่วนนี้ได้ ด้วยเหตุนี้แม้โปรแกรมจะอนุญาตการชำระแบบกลุ่มสูงสุด 4 คู่ต่อธุรกรรม (`batch_settle_offchain_match`) แต่เพดานเชิงปฏิบัติถูกจำกัดด้วยขนาดแพ็กเก็ตธุรกรรม 1,232 ไบต์ คือการรวมสองคู่ (คำสั่งตรวจลายเซ็น 4 คำสั่งราว 760 ไบต์ ร่วมกับ BatchMatchPair ที่ serialize แล้วราว 370 ไบต์ และรายการดัชนีบัญชีกับ header) ก็เกินขนาดแพ็กเก็ตแล้ว การเพิ่มจำนวนคู่ต่อธุรกรรมจริงจึงต้องเปลี่ยนวิธีบรรจุลายเซ็น (เช่น บัญชีลายเซ็นที่ตรวจไว้ล่วงหน้า หรือ multisig แบบรวมนอกเชน) มิใช่เพียงเพิ่มจำนวนคู่ ส่วนบัญชีที่ธุรกรรมแตะต้องประกอบด้วยบัญชี escrow ของผู้ซื้อและผู้ขาย บัญชี order nullifier ทั้งสองฝั่ง บัญชี zone_market และบัญชีผู้เก็บค่าธรรมเนียม/wheeling/loss ในคลัง ข้อจำกัดด้านโครงสร้างนี้อธิบายว่าเหตุใดเพดานการรวมกลุ่มและปริมาณงานของการชำระจึงผูกกับรูปแบบธุรกรรม ซึ่งสอดคล้องกับผลการวัดใน@sec:onchain-throughput
