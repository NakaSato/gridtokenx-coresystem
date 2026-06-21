#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge, shapes

#heading(level: 1)[SYSTEM DESIGN AND IMPLEMENTATION] <sec:system-architecture>

#heading(level: 2)[Architecture Overview]
สถาปัตยกรรมของระบบถูกออกแบบเพื่อรองรับการจำลองการซื้อขายพลังงานแบบ Peer-to-Peer ในบทความนี้นำเสนอแบบจำลองไมโครกริด โดยแบ่งเส้นทางข้อมูลออกเป็นชั้น Smart Meter, Aggregator Bridge, Trading Service, Anchor Smart Contract Program, Settlement Engine และ Frontend Dashboard โดยข้อมูลการผลิตและการใช้พลังงานถูกสร้างจาก Smart Meter Simulator แล้วส่งเข้าสู่ Aggregator Bridge เพื่อคัดกรองข้อมูลก่อนแปลงเป็นคำสั่งธุรกรรมสำหรับ Anchor program บนเครือข่าย Solana-compatible แบบ permissioned

การแยกองค์ประกอบในลักษณะนี้ทำให้การตรวจสอบเชิงวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์เกิดขึ้นก่อนบันทึกธุรกรรม ขณะที่ Anchor program ทำหน้าที่เป็นชั้นบังคับใช้กติกาที่ตรวจสอบได้และบันทึกสถานะเพื่อการตรวจสอบย้อนหลัง ส่วน Settlement Engine ทำหน้าที่จัดการธุรกรรมที่ลงนามแล้ว ติดตามผลจาก transaction signature และอ่าน Event log เพื่อนำสถานะกลับไปแสดงบน Frontend ภาพรวมของชั้นต่างๆ และเส้นทางข้อมูลแสดงใน @fig:system-architecture

#figure(
  text(size: 7pt)[
    #let blue = rgb("#5b7aa8")
    #let orange = rgb("#c77d3c")
    #let green = rgb("#3c8c5a")
    #let W = 7.7cm
    #let ib(b) = rect(stroke: 0.5pt + blue, radius: 2pt, inset: 3pt, width: 100%, fill: rgb("#eef3fb"))[#align(center)[#text(size: 6pt)[#b]]]
    #diagram(
      spacing: (0pt, 9pt),
      {
        node((0, 0), align(center)[Smart Meter Simulator \ (AMI · pandapower · Ed25519/DLMS-COSEM)],
          fill: rgb("#eef3fb"), stroke: 0.5pt + blue, shape: shapes.rect, corner-radius: 2pt, width: W, inset: 4pt)
        edge((0, 0), (0, 1), "-|>", label: text(5.5pt, fill: rgb("#777"))[ชั้น Off-chain: verification · matching], label-side: center)
        node((0, 1), grid(columns: (1fr, 1fr, 1fr, 1fr), gutter: 3pt,
          ib[Aggregator Bridge], ib[Trading (CDA)], ib[IAM], ib[Noti]),
          stroke: none, fill: none, width: W, inset: 0pt)
        edge((0, 1), (0, 2), "-|>")
        node((0, 2), [Chain Bridge — NATS JetStream · ConnectRPC],
          fill: rgb("#fbf0e6"), stroke: 0.5pt + orange, shape: shapes.rect, corner-radius: 2pt, width: W, inset: 4pt)
        edge((0, 2), (0, 3), "-|>", label: text(5.5pt, fill: rgb("#777"))[ชั้น On-chain: settlement · audit], label-side: center)
        node((0, 3), [Anchor Programs: registry · trading · oracle · energy-token · governance],
          fill: rgb("#e8f5ec"), stroke: 0.5pt + green, shape: shapes.rect, corner-radius: 2pt, width: W, inset: 4pt)
        edge((0, 3), (0, 4), "-|>")
        node((0, 4), [Settlement & Audit Layer — PDA state · Event log],
          fill: rgb("#e8f5ec"), stroke: 0.5pt + green, shape: shapes.rect, corner-radius: 2pt, width: W, inset: 4pt)
        edge((0, 4), (0, 5), "-|>")
        node((0, 5), [Frontend Dashboard],
          fill: rgb("#eef3fb"), stroke: 0.5pt + blue, shape: shapes.rect, corner-radius: 2pt, width: W, inset: 4pt)
      },
    )
  ],
  caption: [Layered system architecture: off-chain verification/matching decoupled from on-chain settlement.],
) <fig:system-architecture>

#heading(level: 2)[Backend Services]
ชั้น Backend ทำหน้าที่เป็นชั้นกลางระหว่าง Smart Meter Simulator (ดู @sec:grid-simulator), Aggregator Bridge และ Smart Contract โดยรับผิดชอบการรวบรวมข้อมูล การตรวจสอบความถูกต้อง การจัดคิวธุรกรรม และการส่งคำสั่งไปยังบล็อกเชนหลังจากข้อมูลผ่านเงื่อนไขด้าน Grid stability แล้วเท่านั้น การออกแบบใช้แนวคิด Micro Service เพื่อแยกภาระงานออกเป็นภาระงานย่อย ทำให้ขยายระบบเฉพาะส่วนที่มีปริมาณคำขอสูงและลดผลกระทบเมื่อบริการใดบริการหนึ่งเกิดความผิดพลาด รายละเอียดของช่องทางสื่อสารระหว่างบริการ (ConnectRPC บน mTLS และ NATS JetStream) และสมมติฐานความเชื่อถือที่เกี่ยวข้องอธิบายไว้ใน @sec:threat-model องค์ประกอบหลักของชั้น Backend ประกอบด้วย
- IAM Service: จัดการตัวตน สิทธิ์การเข้าถึงข้อมูล On-chain และบทบาทของผู้ใช้งาน เช่น Prosumer, Consumer และ Operator
- Aggregator Bridge: รับข้อมูลการผลิตและการใช้ไฟฟ้าจาก Smart Meter ตรวจสอบรูปแบบข้อมูล เวลาอ้างอิง รหัสอุปกรณ์ และค่าพลังงานก่อนส่งต่อไปยังขั้นตอนวิเคราะห์
- Trading Service: ตรวจสอบและจับคู่คำสั่งซื้อขายพลังงานร่วมกับเงื่อนไขด้าน Grid stability เช่น ปริมาณพลังงานคงเหลือ ข้อจำกัดของโครงข่าย และสถานะการเชื่อมต่อของ Smart Meter
- Chain Bridge: ตัวกลางเดียวที่ส่งคำสั่งไปยัง Solana Program และติดตามผลลัพธ์จาก transaction signature หรือ Event log โดยบริการอื่นไม่เรียก Solana RPC โดยตรง
- Notification Service: ส่งการแจ้งเตือน เช่น Email และ Alert เมื่อคำสั่งซื้อขายหรือสถานะ settlement เปลี่ยนแปลง

การแยกบริการในลักษณะนี้ช่วยให้ระบบรองรับข้อมูล Realtime Smart Meter จำนวนมากได้ดีขึ้น เนื่องจากบริการรับข้อมูลขยายจำนวน instance ได้โดยไม่กระทบต่อบริการตรวจสอบธุรกรรมหรือบริการเชื่อมต่อบล็อกเชน นอกจากนี้ชั้น Backend ยังเป็นจุดควบคุมความปลอดภัยก่อนบันทึกธุรกรรมลง Smart Contract ทำให้ระบบไม่พึ่งพาบล็อกเชนเพียงอย่างเดียว แต่ผสานการตรวจสอบทางวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์ของผู้ใช้งานเข้าด้วยกัน

#heading(level: 2)[Grid Simulator] <sec:grid-simulator>

การออกแบบ Grid Modeling ซึ่งช่วยให้การจำลอง Advanced Metering Infrastructure (AMI) และการจัดการโครงข่ายไฟฟ้าที่มีความแม่นยำสูง ออกแบบมาเพื่อจำลองระบบไฟฟ้าที่ซับซ้อน แหล่งผลิตพลังงานแบบกระจาย (Distributed Energy Resources: DERs) และการดำเนินการของ Virtual Power Plant (VPP) แกนหลักของระบบจำลองผสานการประเมินสถานะแบบเวลาจริงที่ผ่านการตรวจสอบทางฟิสิกส์ (Physics-validated State Estimation) และ Optimal Power Flow (OPF) โดยใช้ Pandapower ซึ่งทำให้ระบบสามารถสร้างข้อมูลมาตรวัดแบบ Deterministic สำหรับโครงข่ายไฟฟ้าขนาดใหญ่

#figure(
  image("../picture/grid_bus_network.png", width: 100%),
  caption: [Grid bus network topology used for simulator.],
) <fig:grid-bus-network>

Grid Simulator พัฒนาด้วย Python 3.11 @python311 สำหรับจำลองพฤติกรรมของการใช้ไฟฟ้า Distribution Grid ใช้รูปแบบ Network Topology จากไฟล์ GridLAB-D GLM @chassin2008gridlabd แล้วแปลงเป็น grid modeling ซึ่งประกอบด้วย bus, line, load และ photovoltaic unit ดังแสดงใน @fig:grid-bus-network เครื่องมือหลักที่ใช้ ได้แก่ FastAPI @ramirez2026fastapi NetworkX @hagberg2008networkx สำหรับแทนโครงสร้าง topology, pvlib @anderson2023pvlib สำหรับจำลอง photovoltaic generation และ pandapower @thurner2018pandapower สำหรับคำนวณ power flow

กระบวนการจำลองทำงานแบบ discrete time-step โดยในแต่ละรอบ smart meter จะสร้าง energy reading จาก user load profile, photovoltaic generation, weather condition, voltage response และ telemetry replay ในกรณีที่มีการใช้งาน จากนั้นโปรแกรมจะคำนวณ net power injection ของแต่ละ bus เพื่อนำไปอัปเดต grid state ได้แก่ bus voltage, line flow, power loss และ line utilization นอกจากนี้ ระบบยังสามารถ replay ข้อมูล telemetry จริงจากไฟล์ CSV และเชื่อมโยงข้อมูลกับ bus ผ่าน meter registry ทำให้รองรับ hybrid simulation ระหว่าง measured data และ synthetic data ได้ ความถูกต้องของ simulator ตรวจสอบผ่านชุดทดสอบที่ครอบคลุม topology loading, meter-to-bus mapping

เพื่อให้เป็นไปตามมาตรฐานอุตสาหกรรมและรับรองที่มาของข้อมูล Aggregator Bridge รับข้อมูลมาตรวัดความถี่สูงแบบเวลาจริงแล้วกระจายผ่าน Redis Streams ที่แบ่งตามโซน (zone-partitioned) สำหรับการเฝ้าระวังสถานะโครงข่ายแบบพลวัต พร้อมรวมค่าอ่านเป็นหน้าต่างเวลา 15 นาทีเพื่อใช้ในการประเมินกำลังการผลิตและการสั่งการ (dispatch) ในชั้น Backend รูปแบบข้อมูลมาตรวัดเป็นไปตามมาตรฐาน DLMS/COSEM (IEC 62056) โดยถอดรหัสส่วน payload แบบ Binary ด้วย AES-256-GCM และเผยแพร่ต่อในรูปแบบ JSON นอกจากนี้ ระบบรับประกันความไม่ปฏิเสธเชิงรหัสวิทยา (Cryptographic Non-repudiation) ด้วยการตรวจสอบลายเซ็นเข้ารหัสแบบอสมมาตร Ed25519 ทั้งแบบค่าอ่านรายจุดและแบบกลุ่ม (Batch) ก่อนรับข้อมูลเข้าสู่ระบบ ทั้งนี้ในต้นแบบปัจจุบันยังไม่มีเส้นทางสร้าง Settlement Attestation บนเชนโดยตรงจากชั้นมาตรวัด ซึ่งเป็นแนวทางที่เปิดไว้สำหรับงานในอนาคต

#heading(level: 2)[Consortium Network]
เครือข่ายบล็อกเชนในระบบนี้ออกแบบเป็น Consortium Network ภายใต้สมมติฐานฉันทามติแบบ Proof of Authority (PoA) ตามที่อธิบายไว้ใน @sec:settlement-model-invariants ส่วนนี้จึงเน้นรายละเอียดการออกแบบเครือข่ายและการกำกับดูแลเป็นหลัก การออกแบบทำให้ผู้ตรวจสอบบล็อกเป็นหน่วยงานมีหน้าที่ตรวจสอบหรือได้รับยินยอมจาก DSO เช่น ผู้ให้บริการรวบรวมโหลด (Load Aggregator) หน่วยงานกำกับดูแลหรือองค์กรที่ได้รับอนุญาต เหตุผลหลักในการเลือก PoA คือ Network Governance ที่ควบคุมได้ง่ายกว่าเครือข่ายสาธารณะ เช่น Solana Mainnet, Ethereum และความเหมาะสมต่อข้อกำหนดด้าน Regulatory compliance และ cost predictability สำหรับการทดลองหรือใช้งานในระบบพลังงานที่ต้องประมาณต้นทุนธุรกรรมได้ล่วงหน้า @joshi2021poa @androulaki2018hyperledger ทั้งนี้นโยบายด้านสิทธิ์และการกำกับดูแลถูกบังคับใช้ผ่านโปรแกรม governance บนเชน ซึ่งกำหนดหน่วยงานผู้มีสิทธิ์หลัก (REC certifying authority) การลงคะแนนแบบ DAO ที่มี quorum ขั้นต่ำผ่าน create_proposal, cast_vote และ execute_proposal การเสนอและอนุมัติเปลี่ยนผู้มีสิทธิ์ผ่าน propose_authority_change และ approve_authority_change รวมถึงการรับเข้าและถอดถอน Aggregator ที่ได้รับอนุญาตผ่าน admit_aggregator และ revoke_aggregator

ความแตกต่างจาก Solana public mainnet คือเครือข่ายนี้ไม่เปิดให้ validator ภายนอกเข้าร่วมแบบ permissionless และสามารถกำหนดนโยบายด้านสิทธิ์ การอัปเกรดโปรแกรม และการเก็บข้อมูลตามข้อกำหนดของโครงการได้ อย่างไรก็ตาม execution layer ยังคงอ้างอิงสถาปัตยกรรม Solana Virtual Machine และ Sealevel parallel runtime เพื่อให้ธุรกรรมที่ไม่ใช้ account เดียวกันสามารถประมวลผลแบบขนานได้ ค่า slot time ใกล้ 400 ms และ compute budget ที่กล่าวถึงในบทความนี้เป็นเป้าหมายเชิงออกแบบที่อ้างอิงเอกสาร Solana ไม่ใช่ผลวัดของเครือข่าย permissioned โครงสร้างการเรียงบล็อกตามลำดับเวลาแบบ Proof of History (PoH) แสดงใน @fig:block-time @yakovenkoSolanaWhitepaper

#figure(
  text(size: 6.5pt)[
    #let green = rgb("#3c8c5a")
    #diagram(
      spacing: (7pt, 7pt),
      node-stroke: 0.6pt + green,
      node-fill: rgb("#e8f5ec"),
      {
        let slots = ("n", "n+1", "n+2", "n+3")
        let times = ($t_0$, $t_0 + 400"ms"$, $+800"ms"$, $+1200"ms"$)
        for (i, s) in slots.enumerate() {
          node((i, 0), align(center)[*Slot #s* \ PoH hash \ settlement tx],
            shape: shapes.rect, corner-radius: 2pt, inset: 4pt)
          if i > 0 { edge((i - 1, 0), (i, 0), "-|>", stroke: 0.6pt + green) }
          node((i, 1), text(size: 5.5pt, fill: rgb("#777"))[#times.at(i)], stroke: none, fill: none)
        }
      },
    )
  ],
  caption: [Block/slot timeline (illustrative): PoH-ordered slots at a design-target ≈400 ms interval; the per-slot settlement transactions depict the intended write path and are not measured throughput.],
) <fig:block-time>

ในระดับเครือข่ายดังกล่าวต้องกำหนดอย่างน้อยห้ารายการก่อนนำไปใช้งานจริง ได้แก่ จำนวน Validator และหน่วยงานเจ้าของโหนด วิธีผูก identity กับกุญแจ Validator นโยบายเพิ่มหรือลบ Validator กระบวนการอัปเกรดโปรแกรมหรือ genesis/configuration และ fault model ที่ยอมรับได้ บทความนี้จึงถือว่า PoA Solana-compatible network เป็นสมมติฐานเชิงสถาปัตยกรรมของระบบจำลอง ไม่ใช่ข้อสรุปว่ามีการปรับแต่ง consensus ของ Solana public network แล้ว

#heading(level: 2)[Smart Contract Programs] <sec:smart-contract-programs>
Smart Contract แบ่งออกเป็นหลายโปรแกรมตามความรับผิดชอบ ได้แก่ registry, trading, oracle, energy-token, governance และ treasury รวมถึงโปรแกรมสำหรับการทดสอบประสิทธิภาพ (blockbench และ tpc-benchmark) ซึ่งพัฒนาด้วย Anchor Framework เพื่อกำหนด account validation, instruction handler และ Event log อย่างเป็นระบบ โปรแกรม registry มี register_user และ register_meter สำหรับลงทะเบียนผู้ใช้และ Smart Meter ส่วนโปรแกรม trading มี create_sell_order และ create_buy_order (รวมถึง submit_limit_order และ submit_market_order) สำหรับส่งคำสั่งขายและซื้อพลังงาน, match_orders และ clear_auction สำหรับจับคู่คำสั่งซื้อขายที่ Backend เสนอมา, settle_offchain_match และ execute_atomic_settlement สำหรับชำระธุรกรรมแบบ atomic settlement โดย settle_offchain_match จะตรวจสอบลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายและใช้ order nullifier เพื่อกันการส่งซ้ำ และโปรแกรม energy-token มี mint_generation และ mint_to_wallet สำหรับสร้าง energy token ที่ต้องผ่านการร่วมลงนามของ REC certifying authority (Renewable Energy Certificate) โดย mint_generation ใช้คีย์ (meter_id, ช่วงเวลา settlement) เพื่อรับประกัน idempotency ต่อหนึ่งหน้าต่างเวลา และ burn_tokens สำหรับเผา energy token ผ่านคำสั่ง SPL นอกจากนี้ โปรแกรม oracle มี submit_meter_reading สำหรับรับค่าอ่านจาก AMI, trigger_market_clearing สำหรับกำหนดขอบเขตหน้าต่างเวลา 15 นาที (900 วินาที) และ aggregate_readings สำหรับรวมตัวนับค่าอ่านที่ผ่านและไม่ผ่านการตรวจสอบ โปรแกรม governance ทำหน้าที่เป็นชั้นควบคุมแบบ PoA สำหรับการรับรองและเพิกถอน Renewable Energy Certificate (REC) การกำกับสิทธิ์ผู้มีอำนาจ การจัดการ allow-list ของ aggregator และการลงคะแนนแบบ DAO (รายละเอียดคำสั่งอยู่ในส่วน Consortium Network) โปรแกรม treasury จัดการการ stake โทเคน GRX การจ่ายรางวัล และการรักษาค่าตรึงของ THBG stablecoin ผ่านคำสั่งเช่น stake_grx, unstake_grx, claim_rewards, swap_grx_for_thbg, redeem_thbg_for_grx และ record_settlement ที่เรียกผ่าน Cross-Program Invocation (CPI) จากโปรแกรม trading ส่วนโปรแกรม blockbench และ tpc-benchmark ใช้รัน workload มาตรฐาน ได้แก่ Blockbench micro-benchmark, YCSB, SmallBank และ TPC-C สำหรับการประเมินประสิทธิภาพบนเครือข่าย Solana-compatible @anchorDocs @splTokenDocs

โครงสร้างบัญชีใช้ Program Derived Address (PDA) เพื่อแยก state ของระบบออกเป็นบัญชีย่อยตาม seed เฉพาะ เช่น registry และ user account, meter account, market และ market_shard, order และ trade record, escrow, order nullifier สำหรับป้องกันการส่งซ้ำ, oracle_data และ mint authority (gen_mint, thbg_mint) การใช้ PDA ทำให้โปรแกรมตรวจสอบ ownership และ deterministic address ของบัญชีได้โดยไม่ต้องพึ่ง private key ของบัญชี state แต่ละรายการ งานที่ใช้ทรัพยากรสูง เช่น การคำนวณราคาแบบซับซ้อน การจับคู่ order book ขนาดใหญ่ หรือการวิเคราะห์ Grid stability จึงถูกย้ายไปทำใน Backend และ Aggregator Bridge ก่อนส่งผลลัพธ์ที่ยืนยันแล้วเข้าสู่ Smart Contract เพื่อให้อยู่ภายใต้ข้อจำกัดด้าน compute ของธุรกรรม @solanaPdaDocs @solanaDocs โดยกลไกจับคู่คำสั่งใน Trading Service ใช้อัลกอริทึม Continuous Double Auction (CDA) แบบ price-time priority ที่แบ่ง order book ตามโซนและคำนึงถึงข้อจำกัดการไหลของพลังงาน (wheeling และ loss) ก่อนส่งคู่คำสั่งที่จับคู่แล้วไปชำระแบบ atomic บน Smart Contract รายละเอียดสูตรการกำหนดราคาและค่าธรรมเนียมอธิบายใน @sec:pricing-model

#heading(level: 2)[Data Model and Trust Boundary]
ข้อมูลหลักของคำสั่งซื้อขายประกอบด้วย order_id, user_id (บทบาท prosumer หรือ consumer), meter_id, side (offer หรือ bid), energy_amount (quantity_kwh), price_per_kwh, status, expires_at, epoch_id และ zone_id โดยปริมาณ energy_amount ต้องไม่เกิน available_surplus_kwh ที่ Aggregator Bridge รับรองสำหรับผู้ขายในช่วงเวลาเดียวกัน ซึ่งเป็นเงื่อนไขที่ตรวจสอบในชั้น off-chain ส่วนการป้องกันการส่งซ้ำใช้บัญชี nullifier บนเชน (order nullifier) แทนการเก็บ nonce ไว้ในตัวคำสั่ง ส่วน settlement record ประกอบด้วย trade_id, คู่ buy_order_id/sell_order_id, energy_amount ที่ clear, price, fee_amount/net_amount, wheeling_charge, loss_factor, erc_certificate_id, blockchain_tx และ settlement timestamp (created_at/confirmed_at) ทั้งนี้สถานะ escrow ถูกเก็บแยกเป็นบัญชี PDA ต่างหาก (SPL token account ภายใต้ seed `escrow`) ไม่ได้อยู่ในตัว settlement record

ขอบเขตความรับผิดชอบถูกกำหนดให้ชัดเจนดังนี้ Backend และ Aggregator Bridge เป็นผู้ประเมินข้อมูลกำลังผลิตและการใช้ไฟฟ้า เงื่อนไข Grid stability, Islanding safety, ข้อจำกัดของโครงข่าย และเงื่อนไขปริมาณ kWh ที่ไม่เกินค่ารับรอง (available_surplus) จากนั้นจึงปล่อยให้คู่คำสั่งที่ผ่านเงื่อนไขถูกส่งไปยังขั้นตอน settlement บนเชน ส่วน Anchor program ตรวจสอบเฉพาะ account ownership, signer, ลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload, timestamp validity (expires_at), การกันส่งซ้ำผ่านบัญชี order nullifier, เงื่อนไข slippage/zone-capacity, สถานะ escrow และสถานะ order/trade ที่ยังไม่ถูกใช้ซ้ำ กล่าวคือเงื่อนไขด้านปริมาณพลังงานและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ก่อนการ submit ไม่ได้ตรวจซ้ำบนเชน ดังนั้นบล็อกเชนในต้นแบบนี้ทำหน้าที่เป็น settlement and audit layer ไม่ใช่ตัวคำนวณ power-flow หรือ grid-stability engine แบบเต็มรูปแบบ

#heading(level: 2)[Trade Lifecycle Sequence]
ลำดับการซื้อขายถูกแบ่งขอบเขตการทำงานระหว่าง off-chain และ on-chain อย่างชัดเจน ดัง @fig:trade-lifecycle ฝั่ง off-chain รับผิดชอบการรวบรวมข้อมูล Smart Meter การยืนยันตัวตน การตรวจสอบเวลาอ้างอิง การประเมินเงื่อนไข Grid stability และการคำนวณคู่คำสั่งที่เสนอให้ clear ส่วนฝั่ง on-chain รับผิดชอบเฉพาะการยืนยัน account state, ลายเซ็น Ed25519 ของผู้ซื้อและผู้ขายบน order payload ที่ลงนามไว้, bounded matched pair, escrow และการบันทึก settlement event

กระบวนการนี้ช่วยให้ธุรกรรมพลังงานมีความโปร่งใสและตรวจสอบย้อนหลังได้ พร้อมลดความเสี่ยงจากการนำข้อมูล Smart Meter ที่ยังไม่ผ่านการยืนยันเข้าสู่บล็อกเชนโดยตรง การแยก boundary ระหว่าง off-chain verification และ on-chain settlement จึงเป็นหลักสำคัญในการรักษาทั้งประสิทธิภาพของระบบและความปลอดภัยของไมโครกริด ข้อจำกัดของแนวทางนี้คือผู้ใช้ต้องเชื่อถือ Aggregator Bridge และ governance ของ oracle_authority หากต้องการลด trust เพิ่มเติมควรเพิ่ม multi-oracle attestation หรือหลักฐาน cryptographic proof ในอนาคต

#figure(
  text(size: 6.5pt)[
    #let _tag(t, f) = box(fill: f, inset: (x: 3pt, y: 1pt), radius: 2pt)[#text(size: 5.5pt, fill: white)[#t]]
    #let _body(tag, f, b) = grid(columns: (auto, 1fr), gutter: 5pt, align: (horizon + center, horizon),
      _tag(tag, f), b)
    #diagram(
      spacing: (0pt, 7pt),
      {
        let off = rgb("#5b7aa8")
        let on = rgb("#3c8c5a")
        let steps = (
          (off, "OFF", [Smart Meter ส่งค่าอ่าน (ลงนาม Ed25519)]),
          (off, "OFF", [Aggregator Bridge: ตรวจลายเซ็น + available surplus + Grid stability]),
          (off, "OFF", [Trading Service: จับคู่คำสั่งด้วย CDA → submit settle_offchain_match]),
          (on,  "ON",  [ตรวจ account state + ลายเซ็น Ed25519 ของผู้ซื้อและผู้ขาย]),
          (on,  "ON",  [ตรวจ order nullifier (replay) + สถานะ escrow]),
          (on,  "ON",  [บันทึก settlement event — PDA state · Event log]),
          (off, "OFF", [Event log → Frontend Dashboard]),
        )
        for (i, s) in steps.enumerate() {
          node((0, i), _body(s.at(1), s.at(0), s.at(2)),
            fill: s.at(0).lighten(84%), stroke: 0.5pt + s.at(0), width: 7.4cm, inset: 4pt)
          if i > 0 { edge((0, i - 1), (0, i), "-|>", stroke: 0.6pt + rgb("#888")) }
        }
      },
    )
  ],
  caption: [Trade lifecycle: off-chain verification and CDA matching, then on-chain settlement and audit.],
) <fig:trade-lifecycle>
