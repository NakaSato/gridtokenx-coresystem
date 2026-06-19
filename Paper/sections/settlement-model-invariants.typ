#heading(level: 1)[SETTLEMENT MODEL & INVARIANTS] <sec:settlement-model-invariants>

#heading(level: 2)[Solana Architecture]
ระบบนี้ออกแบบบนสถาปัตยกรรมของ Solana ซึ่งประมวลผล Smart Contract ผ่าน Solana Virtual Machine (SVM) @yakovenkoSolanaWhitepaper โดยใช้ Anchor Framework @anchorDocs เป็นชั้นกำหนดโครงสร้างของโปรแกรม ได้แก่ account validation, instruction handler และ Event log คุณสมบัติสำคัญที่นำมาใช้คือ Program Derived Address (PDA) สำหรับสร้างบัญชีที่ตรวจสอบ ownership ได้แบบ deterministic และ Sealevel parallel runtime สำหรับประมวลผลธุรกรรมที่ไม่ใช้ account เดียวกันแบบขนาน ทั้งนี้บทความนี้ไม่ใช่ผลวัดจากเครือข่าย Solana production แต่ใช้คุณสมบัติของ SVM และ PDA เป็นข้อกำหนดเชิงออกแบบสำหรับระบบจำลอง

#heading(level: 2)[Settlement Model]
แบบจำลองการชำระธุรกรรมของระบบแบ่งความรับผิดชอบออกเป็นสองชั้นอย่างชัดเจน ชั้นนอกเชน (off-chain) ประกอบด้วย Aggregator Bridge ซึ่งตรวจสอบลายเซ็น Ed25519 ของข้อมูลมาตรวัด ตรวจรูปแบบข้อมูลตามมาตรฐาน DLMS/COSEM และประเมินเงื่อนไขปริมาณพลังงานคงเหลือ (available surplus) และ Grid stability ร่วมกับ Trading Service ที่จับคู่คำสั่งซื้อขายด้วยอัลกอริทึม Continuous Double Auction (CDA) ส่วนชั้นบนเชน (on-chain) คือ Anchor program @anchorDocs ที่รับเฉพาะคู่คำสั่งที่ผ่านการตรวจสอบแล้ว และทำหน้าที่บันทึกการชำระธุรกรรมที่ตรวจสอบย้อนหลังได้ ก่อนบันทึก settlement โปรแกรมจะตรวจสอบ account ownership ลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload การกันส่งซ้ำผ่านบัญชี order nullifier และสถานะ escrow โดยเงื่อนไขปริมาณพลังงานและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ก่อนการ submit มิได้ตรวจซ้ำบนเชน โครงสร้างบัญชีทั้งหมดใช้ Program Derived Address (PDA) เพื่อแยก state ของแต่ละธุรกรรมและตรวจสอบ ownership ได้แบบ deterministic รายละเอียดของโปรแกรมและบัญชี PDA อธิบายใน @sec:smart-contract-programs @solanaPdaDocs

#heading(level: 2)[Invariants]
จากแบบจำลองข้างต้น ระบบกำหนดเงื่อนไขความถูกต้อง (invariants) ที่ต้องคงไว้ดังนี้
- I1 (Replay-freedom): คู่คำสั่งที่จับคู่แล้วถูกชำระได้เพียงครั้งเดียว โดยบัญชี order nullifier บนเชนกันการส่งซ้ำของคำสั่งเดิม
- I2 (Settlement authorization): การชำระธุรกรรมต้องมีลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload จึงจะถูกบันทึก
- I3 (Surplus bound): ปริมาณพลังงานของคำสั่งขายต้องไม่เกินค่าพลังงานคงเหลือที่รับรอง (available surplus) ซึ่งบังคับใช้ในชั้น off-chain ก่อน submit
- I4 (Mint idempotency): การสร้าง energy token ผ่าน mint_generation ใช้คีย์ (meter_id, ช่วงเวลา settlement) จึงสร้างได้เพียงครั้งเดียวต่อหนึ่งหน้าต่างเวลา
- I5 (ERC double-claim freedom): การออก Renewable Energy Certificate (ERC) ถูกจำกัดด้วยปริมาณการผลิตที่ยังไม่ถูกอ้างสิทธิ์ (unclaimed generation) และตัดยอดผ่าน Cross-Program Invocation (CPI) ไปยังโปรแกรม registry
- I6 (Governance authorization): การเปลี่ยนแปลงนโยบายและการรับรอง ERC ต้องลงนามโดยผู้มีสิทธิ์หลัก (PoA authority) ส่วนการลงคะแนน DAO ป้องกันการลงคะแนนซ้ำด้วยบัญชี vote record ต่อคู่ (proposal, voter)

เงื่อนไขเหล่านี้สอดคล้องกับการบังคับใช้จริงในโปรแกรม trading, energy-token และ governance ที่อธิบายใน @sec:smart-contract-programs

#heading(level: 2)[Consensus]
ระบบนี้ตั้งสมมติฐานเป็นเครือข่าย permissioned แบบ consortium โดยใช้แนวคิด Proof of Authority (PoA) @joshi2021poa เป็นชั้น governance และการควบคุมสิทธิ์การเข้าร่วม กล่าวคือ Validator Node และผู้เข้าร่วมเป็นหน่วยงานที่ได้รับอนุญาตตามนโยบาย governance ทั้งนี้ PoA ในบริบทนี้ไม่ใช่การปรับเปลี่ยนกลไกฉันทามติระดับ Layer 1 ของเครือข่าย Solana-compatible ซึ่งยังคงอาศัย Proof of History (PoH) ร่วมกับ Tower BFT ในการยืนยันธุรกรรมและประกาศสิ้นสุดบล็อก แต่เป็นสมมติฐานเชิงสถาปัตยกรรมด้านการกำกับดูแลและสิทธิ์ของเครือข่ายสำหรับระบบจำลอง

#heading(level: 2)[Backend Service]
Backend Service ทำหน้าที่เป็นชั้นกลางระหว่าง Smart Meter Simulator (ดูรายละเอียดการออกแบบใน @sec:grid-simulator), Aggregator Bridge และ Smart Contract โดยรับผิดชอบการรวบรวมข้อมูล การตรวจสอบความถูกต้อง การจัดคิวธุรกรรม และการส่งคำสั่งไปยังบล็อกเชนหลังจากข้อมูลผ่านเงื่อนไขด้าน Grid stability แล้วเท่านั้น การออกแบบใช้แนวคิด Micro Service เพื่อแยกภาระงานออกเป็นภาระงานย่อยๆ ทำให้สามารถขยายระบบเฉพาะส่วนที่มีปริมาณคำขอสูงและลดผลกระทบเมื่อบริการใดบริการหนึ่งเกิดความผิดพลาด แต่ละบริการพัฒนาด้วยภาษา Rust (Axum) บน Tokio async runtime และสื่อสารระหว่างกันผ่าน ConnectRPC บน mutually authenticated TLS (mTLS) โดยผูกตัวตนของบริการด้วย SPIFFE @spiffe2018 X.509 identity ที่ตรวจสอบจากใบรับรองฝั่ง client ในขั้นตอน mTLS handshake ส่วนเส้นทางธุรกรรมที่ต้องเขียนข้อมูลลงบล็อกเชนถูกแยกออกจาก application tier ผ่าน NATS JetStream @natsio2024 เพื่อรองรับ backpressure และ at-least-once delivery semantics

องค์ประกอบหลักของ Backend Service ประกอบด้วย
- IAM Service: จัดการตัวตน สิทธิ์การเข้าถึง การจัดการสิทธิ์ในการเข้าถึงข้อมูล On-chain และบทบาทของผู้ใช้งาน เช่น Prosumer, Consumer และ Operator 
- Aggregator Bridge: รับข้อมูลการผลิตและการใช้ไฟฟ้าจาก Smart Meter Simulator หรือ Smart Meter Layer ตรวจสอบรูปแบบข้อมูล เวลาอ้างอิง รหัสอุปกรณ์ และค่าพลังงานก่อนส่งต่อไปยังขั้นตอนวิเคราะห์
- Trading Service: ตรวจสอบคำสั่งซื้อขายพลังงานร่วมกับเงื่อนไขด้าน Grid stability เช่น ปริมาณพลังงานคงเหลือ ข้อจำกัดของโครงข่าย และสถานะการเชื่อมต่อของ Smart Meter
- Chain Bridge: การสื่อสารภายในเป็นการทำงานประสานกันของทุก Service บน Private Network ผ่าน ConnectRPC Protocol Internal Service กับ Smart Contract เช่น IAM Service, Aggregator Service, Trading Service, Notification Service เพื่อเป็นตัวกลางที่สามารถส่งคำสั่งไปยัง Solana Program และติดตามผลลัพธ์จาก transaction signature หรือ Event log
- Notification Service: ส่งการแจ้งเตือน เช่น Email, Alert และ Notification เมื่อคำสั่งซื้อขายหรือสถานะ settlement มีเปลี่ยนแปลง การสื่อสารภายในเป็นการทำงานประสานกันของทุก Service บน Private Network ผ่าน ConnectRPC Protocol

  
การแยกบริการในลักษณะนี้ช่วยให้ระบบรองรับข้อมูลแบบ Realtime Smart Meter จำนวนมากได้ดีขึ้น เนื่องจากบริการรับข้อมูลสามารถขยายจำนวน instance ได้โดยไม่กระทบต่อบริการตรวจสอบธุรกรรมหรือบริการเชื่อมต่อบล็อกเชน นอกจากนี้ Backend Services ยังเป็นจุดควบคุมความปลอดภัยก่อนบันทึกธุรกรรมลง Smart Contract ทำให้ระบบซื้อขายพลังงานแบบ Peer-to-Peer ไม่พึ่งพาบล็อกเชนเพียงอย่างเดียว แต่ผสานการตรวจสอบทางวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์ของผู้ใช้งานเข้าด้วยกัน
