#import "@preview/ctheorems:1.1.3": thmbox

// Settlement invariants rendered as compact theorem-like boxes, numbered I1–I9
// (fixed roman-prefixed numbering to match the in-figure tags and prose).
#let invariant = thmbox(
  "invariant", "Invariant",
  base: none,
  fill: luma(248),
  stroke: 0.4pt + luma(205),
  radius: 2pt,
  inset: 0.7em,
  padding: (top: 0.3em, bottom: 0.3em),
).with(numbering: n => "I" + str(n))

#heading(level: 1)[SETTLEMENT MODEL & INVARIANTS] <sec:settlement-model-invariants>

#heading(level: 2)[Solana Architecture]
ระบบนี้ออกแบบบนสถาปัตยกรรมของ Solana ซึ่งประมวลผล Smart Contract ผ่าน Solana Virtual Machine (SVM) @yakovenkoSolanaWhitepaper โดยใช้ Anchor Framework @anchorDocs เป็นชั้นกำหนดโครงสร้างของโปรแกรม ได้แก่ account validation, instruction handler และ Event log คุณสมบัติสำคัญที่นำมาใช้คือ Program Derived Address (PDA) สำหรับสร้างบัญชีที่ตรวจสอบ ownership ได้แบบ deterministic และ Sealevel parallel runtime สำหรับประมวลผลธุรกรรมที่ไม่ใช้ account เดียวกันแบบขนาน ทั้งนี้บทความนี้ไม่ใช่ผลวัดจากเครือข่าย Solana production แต่ใช้คุณสมบัติของ SVM และ PDA เป็นข้อกำหนดเชิงออกแบบสำหรับระบบจำลอง

#heading(level: 2)[Settlement Model]
แบบจำลองการชำระธุรกรรมของระบบแบ่งความรับผิดชอบออกเป็นสองชั้นอย่างชัดเจน ชั้นนอกเชน (off-chain) ประกอบด้วย Aggregator Bridge ซึ่งตรวจสอบลายเซ็น Ed25519 ของข้อมูลมาตรวัด ตรวจรูปแบบข้อมูลตามมาตรฐาน DLMS/COSEM และประเมินเงื่อนไขปริมาณพลังงานคงเหลือ (available surplus) และ Grid stability ร่วมกับ Trading Service ที่จับคู่คำสั่งซื้อขายด้วยอัลกอริทึม Continuous Double Auction (CDA) ส่วนชั้นบนเชน (on-chain) คือ Anchor program @anchorDocs ที่รับเฉพาะคู่คำสั่งที่ผ่านการตรวจสอบแล้ว และทำหน้าที่บันทึกการชำระธุรกรรมที่ตรวจสอบย้อนหลังได้ ก่อนบันทึก settlement โปรแกรมจะตรวจสอบ account ownership ลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload การกันส่งซ้ำผ่านบัญชี order nullifier และสถานะ escrow โดยเงื่อนไขปริมาณพลังงานและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ก่อนการ submit มิได้ตรวจซ้ำบนเชน โครงสร้างบัญชีทั้งหมดใช้ Program Derived Address (PDA) เพื่อแยก state ของแต่ละธุรกรรมและตรวจสอบ ownership ได้แบบ deterministic รายละเอียดของโปรแกรมและบัญชี PDA อธิบายใน@sec:smart-contract-programs @solanaPdaDocs

#heading(level: 2)[Atomic Delivery-versus-Payment]
คู่คำสั่งที่จับคู่แล้วถูกชำระผ่านคำสั่ง `settle_offchain_match` ของโปรแกรม trading ซึ่งทำงานแบบส่งมอบพร้อมชำระเงิน (Delivery-versus-Payment: DvP) ภายในธุรกรรมเดียว กล่าวคือการโอนเงินและการโอนพลังงานเกิดขึ้นพร้อมกันหรือไม่เกิดขึ้นเลย หากการโอนใดล้มเหลวธุรกรรมทั้งหมดจะถูกย้อนกลับ (revert) จึงไม่มีสถานะค้างที่ฝ่ายหนึ่งได้รับโดยอีกฝ่ายไม่ได้รับ ก่อนการโอน โปรแกรมตรวจลายเซ็น Ed25519 ของทั้งผู้ซื้อ (instruction sysvar ดัชนี 0) และผู้ขาย (ดัชนี 1) บนข้อความที่ผูกฟิลด์สำคัญของคำสั่ง ได้แก่ order_id, user, energy_amount, price_per_kwh, side, zone_id และ expires_at ทำให้ดัดแปลงปริมาณหรือราคาหลังการลงนามไม่ได้ จากนั้นตรวจเงื่อนไขการครอสราคา (price crossing) คือราคาจับคู่ต้องอยู่ในช่วง $p_s <= p^* <= p_b$ ตรวจ side ของทั้งสองฝั่ง และตรวจเวลาหมดอายุ

การชำระเป็นแบบ partial-fill โดยบัญชี order nullifier (seed `[nullifier, user, order_id]`) เก็บปริมาณที่ถูกเติมสะสม (filled_amount) แทนค่าบูลีน คำสั่งจึงถูกเติมได้หลายครั้งจนเต็มปริมาณที่ลงนามไว้ แต่ผลรวมจะไม่เกินปริมาณนั้น ($"match" <= "energy\_amount" - "filled"$) ทั้งสองฝั่ง สำหรับธุรกรรมข้ามโซน (cross-zone) ที่ใช้สายส่งระหว่างโซน โปรแกรมยังบังคับเพดานการไหลสะสมบนเชน ($"committed\_flow" + "match" <= "capacity"$) ส่วนธุรกรรมภายในโซนเดียวกันได้รับการยกเว้นเพราะไม่ใช้สายส่งระหว่างโซน เมื่อผ่านเงื่อนไขทั้งหมด มูลค่ารวมและส่วนแบ่งคำนวณดังนี้ โดยเงิน (currency) ไหลจาก buyer escrow ไปยังตัวเก็บค่าธรรมเนียม/wheeling/loss และ seller escrow ส่วนพลังงาน (energy token) ไหลจาก seller escrow ไปยัง buyer escrow ทั้งหมดลงนามโดย market_authority PDA

$ V &= "match" dot p^* #<eq:settle-value> \
  "fee" &= floor(V dot phi.alt slash 10000) #<eq:settle-fee> \
  "net"_s &= V - "fee" - w - c_("loss") #<eq:settle-net> $

โดย $V$ คือมูลค่ารวมที่ออกจาก buyer escrow, $phi.alt$ คือค่าธรรมเนียมตลาด (market_fee_bps), $w$ คือ wheeling charge, $c_("loss")$ คือต้นทุน loss (ดู@eq:loss-cost) และ $"net"_s$ คือยอดสุทธิที่ผู้ขายได้รับ ทั้งนี้การคูณมูลค่าใช้ checked arithmetic เพื่อปฏิเสธกรณี overflow แทนการ clamp ค่า และเมื่อตลาดตั้งค่าให้ชำระด้วย THBG ระบบบังคับให้บันทึกมูลค่ารวม (gross) ผ่าน CPI `record_settlement` ไปยังโปรแกรม treasury เพื่อให้ตัวนับยอดชำระกระทบยอดกับกระแสเงินที่ออกจาก escrow จริง

#heading(level: 2)[Invariants]
จากแบบจำลองข้างต้น ระบบกำหนดเงื่อนไขความถูกต้อง (invariants) ที่ต้องคงไว้ดังนี้

#invariant("No over-fill / replay-freedom")[ผลรวมปริมาณที่ชำระของแต่ละคำสั่งต้องไม่เกินปริมาณที่ลงนามไว้ โดยบัญชี order nullifier บนเชนสะสมปริมาณที่ถูกเติม (filled_amount) และปฏิเสธการเติมที่ทำให้เกินยอด จึงรองรับ partial-fill พร้อมกันที่กันการชำระซ้ำของส่วนเดิม] <inv:i1>

#invariant("Settlement authorization")[การชำระธุรกรรมต้องมีลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบนข้อความที่ผูกฟิลด์คำสั่ง (order_id, user, amount, price, side, zone, expiry) จึงจะถูกบันทึก] <inv:i2>

#invariant("Surplus bound")[ปริมาณพลังงานของคำสั่งขายต้องไม่เกินค่าพลังงานคงเหลือที่รับรอง (available surplus) ซึ่งบังคับใช้ในชั้น off-chain ก่อน submit] <inv:i3>

#invariant("Mint idempotency")[การสร้าง energy token ผ่าน mint_generation ใช้คีย์ (meter_id, ช่วงเวลา settlement) จึงสร้างได้เพียงครั้งเดียวต่อหนึ่งหน้าต่างเวลา] <inv:i4>

#invariant("REC double-claim freedom")[การออก Renewable Energy Certificate (REC) ถูกจำกัดด้วยปริมาณการผลิตที่ยังไม่ถูกอ้างสิทธิ์ (unclaimed generation) และตัดยอดผ่าน Cross-Program Invocation (CPI) ไปยังโปรแกรม registry] <inv:i5>

#invariant("Governance authorization")[การเปลี่ยนแปลงนโยบายและการรับรอง REC ต้องลงนามโดยผู้มีสิทธิ์หลัก (PoA authority) ส่วนการลงคะแนน DAO ป้องกันการลงคะแนนซ้ำด้วยบัญชี vote record ต่อคู่ (proposal, voter)] <inv:i6>

#invariant("Atomic DvP")[การโอนเงินและการโอนพลังงานของหนึ่งการจับคู่ต้องสำเร็จพร้อมกันภายในธุรกรรมเดียว หรือถูกย้อนกลับทั้งหมด ไม่มีสถานะที่ฝ่ายหนึ่งได้รับโดยอีกฝ่ายไม่ได้รับ] <inv:i7>

#invariant("Price-cross bound")[ราคาจับคู่ต้องอยู่ในช่วงราคาที่ทั้งสองฝ่ายลงนามยินยอม คือ $p_s <= p^* <= p_b$ มิฉะนั้นปฏิเสธด้วย slippage error] <inv:i8>

#invariant("Inter-zone capacity bound")[ผลรวมการไหลข้ามโซน (committed_flow) ของแต่ละ zone market ต้องไม่เกินความจุสายส่งที่กำหนด ($"committed\_flow" <= "capacity"$) ส่วนธุรกรรมภายในโซนเดียวกันไม่นับรวมในเพดานนี้] <inv:i9>

เงื่อนไขเหล่านี้ถูกบังคับใช้จริงในโปรแกรมบนเชนที่อธิบายใน@sec:smart-contract-programs กล่าวคือ I1, I2, I7, I8 และ I9 บังคับใช้ในคำสั่ง `settle_offchain_match` ของโปรแกรม trading โดย I1 ผ่านบัญชี order nullifier (seed `[nullifier, user, order_id]`) ที่ตรวจ `match_amount <= energy_amount - filled_amount` ของทั้งสองฝั่ง, I2 ผ่านการตรวจลายเซ็น Ed25519 ของผู้ซื้อและผู้ขายบน instructions sysvar (ดัชนี 0 และ 1), I7 ผ่านการรวมการโอน SPL ทั้งหมดไว้ในธุรกรรมเดียวที่ revert ทั้งชุดเมื่อ CPI ใดล้มเหลว, I8 ผ่านเงื่อนไข `match_price <= buyer.price` และ `match_price >= seller.price` และ I9 ผ่านการสะสม `committed_flow` เทียบกับ `capacity` ของ zone market สำหรับธุรกรรมข้ามโซน, I4 บังคับใช้ในคำสั่ง `mint_generation` ของโปรแกรม energy-token ที่ตรวจสถานะ `minted` ของบัญชี mint record ต่อคีย์ `(meter_id, window_start_ms)` ก่อนเรียก mint CPI, I5 บังคับใช้ในโปรแกรม governance ที่ตัดยอด `unclaimed_generation` แล้วเรียก CPI `mark_erc_claimed` ไปยังโปรแกรม registry และ I6 บังคับใช้ผ่านการจำกัดสิทธิ์ของผู้มีอำนาจ (admit/revoke aggregator และการโอนสิทธิ์แบบสองขั้นตอน) ร่วมกับบัญชี vote record (seed `[vote, proposal, voter]`) และเงื่อนไข quorum ขั้นต่ำ ส่วน I3 (surplus bound) เป็นเงื่อนไขที่บังคับใช้ในชั้น off-chain ตามการออกแบบ โดยบนเชนยังจำกัดปริมาณที่ชำระไม่ให้เกินส่วนที่เหลือของคำสั่งผ่านบัญชี nullifier (I1)

#heading(level: 2)[Consensus]
ระบบนี้ตั้งสมมติฐานเป็นเครือข่าย permissioned แบบ consortium โดยใช้แนวคิด Proof of Authority (PoA) @joshi2021poa เป็นชั้นกำกับดูแล (governance) และการควบคุมสิทธิ์การเข้าร่วม (admission control) เท่านั้น กล่าวคือ Validator Node และผู้เข้าร่วมทุกรายเป็นหน่วยงานที่ได้รับอนุญาตล่วงหน้าตามนโยบาย governance ของ consortium (รายละเอียดกลไกการกำกับสิทธิ์อยู่ใน@sec:consortium-network) ข้อที่ต้องเน้นย้ำคือ PoA ในบริบทนี้ไม่ได้แทนที่หรือปรับเปลี่ยนกลไกฉันทามติระดับ Layer 1 ของเครือข่าย Solana-compatible ซึ่งยังคงแยกหน้าที่ออกเป็นสองส่วน ได้แก่ Proof of History (PoH) ที่ทำหน้าที่เป็นนาฬิกาเชิงรหัสวิทยา (verifiable clock) สำหรับเรียงลำดับเหตุการณ์ตามเวลาก่อนการลงมติ และ Tower BFT ที่ทำหน้าที่ลงมติยืนยันบล็อกและประกาศสิ้นสุดบล็อก (finality) @yakovenkoSolanaWhitepaper ดังนั้น PoA จึงเป็นเพียงสมมติฐานเชิงสถาปัตยกรรมด้านการกำกับดูแลและสิทธิ์ของเครือข่ายสำหรับระบบจำลอง ไม่ใช่ข้อสรุปว่ามีการปรับแต่ง consensus ของ Solana แล้ว
