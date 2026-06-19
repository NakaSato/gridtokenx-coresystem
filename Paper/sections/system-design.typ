#let _node(body, fill: rgb("#eef3fb")) = rect(
  fill: fill, stroke: 0.5pt + rgb("#5b7aa8"), radius: 3pt, inset: 5pt, width: 100%,
)[#align(center)[#text(size: 7pt)[#body]]]
#let _down = align(center)[#text(size: 9pt, fill: rgb("#5b7aa8"))[#sym.arrow.b]]

#heading(level: 1)[SYSTEM DESIGN] <sec:system-architecture>

#heading(level: 2)[Architecture Overview]
สถาปัตยกรรมของระบบถูกออกแบบเพื่อรองรับการจำลองการซื้อขายพลังงานแบบ Peer-to-Peer ในบทความนี้นำเสนอแบบจำลองไมโครกริด โดยแบ่งเส้นทางข้อมูลออกเป็นชั้น Smart Meter, Aggregator Bridge, Trading Service, Anchor Smart Contract Program, Settlement Engine และ Frontend Dashboard โดยข้อมูลการผลิตและการใช้พลังงานถูกสร้างจาก Smart Meter Simulator แล้วส่งเข้าสู่ Aggregator Bridge เพื่อคัดกรองข้อมูลก่อนแปลงเป็นคำสั่งธุรกรรมสำหรับ Anchor program บนเครือข่าย Solana-compatible แบบ permissioned

การแยกองค์ประกอบในลักษณะนี้ทำให้การตรวจสอบเชิงวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์เกิดขึ้นก่อนบันทึกธุรกรรม ขณะที่ Anchor program ทำหน้าที่เป็นชั้นบังคับใช้กติกาที่ตรวจสอบได้และบันทึกสถานะเพื่อการตรวจสอบย้อนหลัง ส่วน Settlement Engine ทำหน้าที่จัดการธุรกรรมที่ลงนามแล้ว ติดตามผลจาก transaction signature และอ่าน Event log เพื่อนำสถานะกลับไปแสดงบน Frontend ภาพรวมของชั้นต่างๆ และเส้นทางข้อมูลแสดงใน @fig:system-architecture

#figure(
  [
    #set align(center)
    #block(width: 100%)[
      #_node([Smart Meter Simulator \ (AMI · pandapower · Ed25519/DLMS-COSEM)])
      #_down
      #text(size: 6.5pt, fill: rgb("#777"))[ชั้น Off-chain (verification · matching)]
      #grid(columns: (1fr, 1fr, 1fr, 1fr), gutter: 4pt,
        _node([Aggregator \ Bridge]), _node([Trading \ (CDA)]), _node([IAM]), _node([Noti]))
      #v(3pt)
      #_node([Chain Bridge — NATS JetStream · ConnectRPC], fill: rgb("#fbf0e6"))
      #_down
      #text(size: 6.5pt, fill: rgb("#777"))[ชั้น On-chain (settlement · audit)]
      #_node([Anchor Programs: registry · trading · oracle · energy-token · governance], fill: rgb("#e8f5ec"))
      #v(3pt)
      #_node([Settlement & Audit Layer — PDA state · Event log], fill: rgb("#e8f5ec"))
      #_down
      #_node([Frontend Dashboard])
    ]
  ],
  caption: [Layered system architecture: off-chain verification/matching decoupled from on-chain settlement.],
) <fig:system-architecture>

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
  [
    #let _blk(label) = rect(
      fill: rgb("#e8f5ec"), stroke: 0.6pt + rgb("#3c8c5a"), radius: 3pt, inset: 5pt, width: 100%,
    )[#align(center)[#text(size: 6.5pt)[#label]]]
    #let _arr = align(center + horizon)[#text(size: 11pt, fill: rgb("#3c8c5a"))[#sym.arrow.r]]
    #let _t(s) = align(center)[#text(size: 6pt, fill: rgb("#777"))[#s]]
    #block(width: 100%)[
      #grid(
        columns: (1fr, 0.4fr, 1fr, 0.4fr, 1fr, 0.4fr, 1fr),
        align: horizon,
        _blk([*Slot n* \ PoH hash \ settlement tx]), _arr,
        _blk([*Slot n+1* \ PoH hash \ settlement tx]), _arr,
        _blk([*Slot n+2* \ PoH hash \ settlement tx]), _arr,
        _blk([*Slot n+3* \ PoH hash \ settlement tx]),
      )
      #v(2pt)
      #line(length: 100%, stroke: 0.5pt + rgb("#999"))
      #v(1pt)
      #grid(
        columns: (1fr, 0.4fr, 1fr, 0.4fr, 1fr, 0.4fr, 1fr),
        _t($t_0$), _t([]), _t($t_0 + 400"ms"$), _t([]), _t($+800"ms"$), _t([]), _t($+1200"ms"$),
      )
      #v(1pt)
      #align(center)[#text(size: 6pt, fill: rgb("#777"))[เวลา (slot $approx 400$ ms, เป้าหมายเชิงออกแบบ)]]
    ]
  ],
  caption: [Block/slot timeline: PoH-ordered slots at a design-target ≈400 ms interval, each recording settlement transactions.],
) <fig:block-time>

ในระดับเครือข่ายดังกล่าวต้องกำหนดอย่างน้อยห้ารายการก่อนนำไปใช้งานจริง ได้แก่ จำนวน Validator และหน่วยงานเจ้าของโหนด วิธีผูก identity กับกุญแจ Validator นโยบายเพิ่มหรือลบ Validator กระบวนการอัปเกรดโปรแกรมหรือ genesis/configuration และ fault model ที่ยอมรับได้ บทความนี้จึงถือว่า PoA Solana-compatible network เป็นสมมติฐานเชิงสถาปัตยกรรมของระบบจำลอง ไม่ใช่ข้อสรุปว่ามีการปรับแต่ง consensus ของ Solana public network แล้ว

#heading(level: 2)[Smart Contract Programs] <sec:smart-contract-programs>
Smart Contract แบ่งออกเป็นหลายโปรแกรมตามความรับผิดชอบ ได้แก่ registry, trading, oracle, energy-token, governance และ treasury รวมถึงโปรแกรมสำหรับการทดสอบประสิทธิภาพ (blockbench และ tpc-benchmark) ซึ่งพัฒนาด้วย Anchor Framework เพื่อกำหนด account validation, instruction handler และ Event log อย่างเป็นระบบ โปรแกรม registry มี register_user และ register_meter สำหรับลงทะเบียนผู้ใช้และ Smart Meter ส่วนโปรแกรม trading มี create_sell_order และ create_buy_order (รวมถึง submit_limit_order และ submit_market_order) สำหรับส่งคำสั่งขายและซื้อพลังงาน, match_orders และ clear_auction สำหรับจับคู่คำสั่งซื้อขายที่ Backend เสนอมา, settle_offchain_match และ execute_atomic_settlement สำหรับชำระธุรกรรมแบบ atomic settlement โดย settle_offchain_match จะตรวจสอบลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายและใช้ order nullifier เพื่อกันการส่งซ้ำ และโปรแกรม energy-token มี mint_generation และ mint_to_wallet สำหรับสร้าง energy token ที่ต้องผ่านการร่วมลงนามของ REC validator (Renewable Energy Certificate) โดย mint_generation ใช้คีย์ (meter_id, ช่วงเวลา settlement) เพื่อรับประกัน idempotency ต่อหนึ่งหน้าต่างเวลา และ burn_tokens สำหรับเผา energy token ผ่านคำสั่ง SPL นอกจากนี้ โปรแกรม oracle มี submit_meter_reading สำหรับรับค่าอ่านจาก AMI, trigger_market_clearing สำหรับกำหนดขอบเขตหน้าต่างเวลา 15 นาที (900 วินาที) และ aggregate_readings สำหรับรวมตัวนับค่าอ่านที่ผ่านและไม่ผ่านการตรวจสอบ โปรแกรม governance ทำหน้าที่เป็นชั้นควบคุมแบบ PoA สำหรับการรับรองและเพิกถอน Renewable Energy Certificate (ERC) การกำกับสิทธิ์ผู้มีอำนาจ การจัดการ allow-list ของ aggregator และการลงคะแนนแบบ DAO (รายละเอียดคำสั่งอยู่ในส่วน Consortium Network) โปรแกรม treasury จัดการการ stake โทเคน GRX การจ่ายรางวัล และการรักษาค่าตรึงของ THBG stablecoin ผ่านคำสั่งเช่น stake_grx, unstake_grx, claim_rewards, swap_grx_for_thbg, redeem_thbg_for_grx และ record_settlement ที่เรียกผ่าน Cross-Program Invocation (CPI) จากโปรแกรม trading ส่วนโปรแกรม blockbench และ tpc-benchmark ใช้รัน workload มาตรฐาน ได้แก่ Blockbench micro-benchmark, YCSB, SmallBank และ TPC-C สำหรับการประเมินประสิทธิภาพบนเครือข่าย Solana-compatible @anchorDocs @splTokenDocs

โครงสร้างบัญชีใช้ Program Derived Address (PDA) เพื่อแยก state ของระบบออกเป็นบัญชีย่อยตาม seed เฉพาะ เช่น registry และ user account, meter account, market และ market_shard, order และ trade record, escrow, order nullifier สำหรับป้องกันการส่งซ้ำ, oracle_data และ mint authority (gen_mint, thbg_mint) การใช้ PDA ทำให้โปรแกรมตรวจสอบ ownership และ deterministic address ของบัญชีได้โดยไม่ต้องพึ่ง private key ของบัญชี state แต่ละรายการ งานที่ใช้ทรัพยากรสูง เช่น การคำนวณราคาแบบซับซ้อน การจับคู่ order book ขนาดใหญ่ หรือการวิเคราะห์ Grid stability จึงถูกย้ายไปทำใน Backend และ Aggregator Bridge ก่อนส่งผลลัพธ์ที่ยืนยันแล้วเข้าสู่ Smart Contract เพื่อให้อยู่ภายใต้ข้อจำกัดด้าน compute ของธุรกรรม @solanaPdaDocs @solanaDocs โดยกลไกจับคู่คำสั่งใน Trading Service ใช้อัลกอริทึม Continuous Double Auction (CDA) แบบ price-time priority ที่แบ่ง order book ตามโซนและคำนึงถึงข้อจำกัดการไหลของพลังงาน (wheeling และ loss) ก่อนส่งคู่คำสั่งที่จับคู่แล้วไปชำระแบบ atomic บน Smart Contract รายละเอียดสูตรการกำหนดราคาและค่าธรรมเนียมอธิบายใน @sec:pricing-model

#heading(level: 2)[Data Model and Trust Boundary]
ข้อมูลหลักของคำสั่งซื้อขายประกอบด้วย order_id, user_id (บทบาท prosumer หรือ consumer), meter_id, side (offer หรือ bid), energy_amount (quantity_kwh), price_per_kwh, status, expires_at, epoch_id และ zone_id โดยปริมาณ energy_amount ต้องไม่เกิน available_surplus_kwh ที่ Aggregator Bridge รับรองสำหรับผู้ขายในช่วงเวลาเดียวกัน ซึ่งเป็นเงื่อนไขที่ตรวจสอบในชั้น off-chain ส่วนการป้องกันการส่งซ้ำใช้บัญชี nullifier บนเชน (order nullifier) แทนการเก็บ nonce ไว้ในตัวคำสั่ง ส่วน settlement record ประกอบด้วย trade_id, คู่ buy_order_id/sell_order_id, energy_amount ที่ clear, price, fee_amount/net_amount, wheeling_charge, loss_factor, erc_certificate_id, blockchain_tx และ settlement timestamp (created_at/confirmed_at) ทั้งนี้สถานะ escrow ถูกเก็บแยกเป็นบัญชี EscrowRecord ต่างหาก ไม่ได้อยู่ในตัว settlement record

ขอบเขตความรับผิดชอบถูกกำหนดให้ชัดเจนดังนี้ Backend และ Aggregator Bridge เป็นผู้ประเมินข้อมูลกำลังผลิตและการใช้ไฟฟ้า เงื่อนไข Grid stability, Islanding safety, ข้อจำกัดของโครงข่าย และเงื่อนไขปริมาณ kWh ที่ไม่เกินค่ารับรอง (available_surplus) จากนั้นจึงปล่อยให้คู่คำสั่งที่ผ่านเงื่อนไขถูกส่งไปยังขั้นตอน settlement บนเชน ส่วน Anchor program ตรวจสอบเฉพาะ account ownership, signer, ลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload, timestamp validity (expires_at), การกันส่งซ้ำผ่านบัญชี order nullifier, เงื่อนไข slippage/zone-capacity, สถานะ escrow และสถานะ order/trade ที่ยังไม่ถูกใช้ซ้ำ กล่าวคือเงื่อนไขด้านปริมาณพลังงานและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ก่อนการ submit ไม่ได้ตรวจซ้ำบนเชน ดังนั้นบล็อกเชนในต้นแบบนี้ทำหน้าที่เป็น settlement and audit layer ไม่ใช่ตัวคำนวณ power-flow หรือ grid-stability engine แบบเต็มรูปแบบ

#heading(level: 2)[Pricing and Settlement Model] <sec:pricing-model>
แบบจำลองราคาของระบบแบ่งเป็นสามส่วน คือ การกำหนดราคาเคลียร์ในกลไก CDA การคำนวณค่าธรรมเนียมและยอดสุทธิในการ settlement และกลไกราคาของโทเคนในชั้น treasury สัญลักษณ์ที่ใช้ในสมการสรุปไว้ใน @tbl:nomenclature

#figure(
  text(size: 7pt)[
    #table(
      columns: (auto, 1fr),
      inset: 3pt,
      align: (center + horizon, left + horizon),
      table.header([*สัญลักษณ์*], [*ความหมาย*]),
      [$p_s$], [ราคาเสนอขายต่อหน่วย (sell ask)],
      [$p_b$], [ราคาเสนอซื้อต่อหน่วย (buy bid)],
      [$p^*$], [ราคาเคลียร์ / landed cost],
      [$lambda$], [loss factor ($lambda >= 1$)],
      [$c_("loss")$], [ต้นทุนการสูญเสียต่อหน่วย],
      [$w$], [ค่าผ่านสาย (wheeling charge) ต่อหน่วย],
      [$m$], [ตัวคูณจูงใจ (incentive multiplier)],
      [$delta$], [ส่วนลดภายในโซน (intra-zone discount)],
      [$q$], [ปริมาณพลังงานที่จับคู่ (kWh)],
      [$V$], [มูลค่ารวมของธุรกรรม],
      [$f$], [ค่าธรรมเนียมตลาด],
      [$phi$], [อัตราค่าธรรมเนียมตลาด (bps)],
      [$W$], [ค่าผ่านสายรวม ($q dot w$)],
      [$L$], [ต้นทุนการสูญเสียรวม ($q dot c_("loss")$)],
      [$r$], [อัตราแลกเปลี่ยน GRX atom ต่อ THBG],
      [$psi$], [ค่าธรรมเนียม swap (bps)],
      [$A$], [ตัวสะสมรางวัลต่อหน่วย stake],
      [$s$, $s_("total")$], [จำนวนที่ stake และจำนวน stake รวม],
      [$R$], [รางวัลที่เติมเข้าระบบ],
    )
  ],
  caption: [Nomenclature for the pricing and settlement equations.],
) <tbl:nomenclature>

การกำหนดราคาเคลียร์ (CDA clearing) ใช้ราคาฝั่งผู้ขาย (maker price) ปรับด้วยต้นทุนโครงข่าย โดยกำหนดต้นทุนการสูญเสีย (loss cost) ต่อหน่วยจากค่า loss factor $lambda >= 1$ ดังสมการ
$ c_("loss") = p_s (lambda - 1) $ <eq:loss-cost>
ราคาเคลียร์หรือ landed cost คำนวณจากราคาเสนอขาย $p_s$ บวกค่าผ่านสาย (wheeling charge) $w$ และต้นทุนการสูญเสีย แล้วปรับด้วยตัวคูณจูงใจ (incentive multiplier) $m$ และส่วนลดภายในโซน (intra-zone discount) $delta$
$ p^* = (p_s + w + c_("loss")) dot m dot delta $ <eq:clearing>
โดย $delta = 0.95$ เมื่อผู้ซื้อและผู้ขายอยู่โซนเดียวกัน และ $delta = 1$ เมื่อข้ามโซน คำสั่งซื้อจะจับคู่ได้เมื่อ $p^* <= p_b$ (เมื่อ $p_b$ คือราคาเสนอซื้อ) และระบบจัดลำดับผู้ขายที่มี landed cost ต่ำสุดให้จับคู่ก่อนตามหลัก price-time priority ปริมาณที่จับคู่เท่ากับส่วนที่เหลือน้อยที่สุดของทั้งสองฝั่ง $q = min(q_b, q_s)$

การคำนวณค่าธรรมเนียมและยอดสุทธิในการ settlement กำหนดมูลค่ารวม ค่าธรรมเนียมตลาด และยอดสุทธิที่ผู้ขายได้รับดังนี้
$ V = q dot p^* $ <eq:value>
$ f = (V dot phi) / 10000 $ <eq:fee>
$ "net" = V - f - W - L $ <eq:net>
โดย $phi$ คือค่าธรรมเนียมตลาดในหน่วย basis point (ค่าตั้งต้นบนเชน 25 bps หรือ 0.25%), $W = q dot w$ คือค่าผ่านสายรวม และ $L = q dot c_("loss")$ คือต้นทุนการสูญเสียรวม ยอด $f$, $W$, $L$ และ net ถูกโอนแยกไปยังบัญชีผู้เก็บค่าธรรมเนียม ค่าผ่านสาย การสูญเสีย และผู้ขายตามลำดับ พารามิเตอร์ของโซนถูกตีความในหน่วย bps คือ $m = m_("bps") slash 10000$ และ $w = w_("bps") slash 10000$ โดยค่าตั้งต้นของ wheeling charge เท่ากับ 0 ภายในโซนและ 0.02 ข้ามโซน ส่วน loss factor เท่ากับ 1.01 ภายในโซนและ 1.03 ข้ามโซน

กลไกราคาของโทเคนในชั้น treasury ครอบคลุมการแลกเปลี่ยนระหว่าง GRX และ THBG stablecoin ที่ตรึงค่ากับเงินบาท โดยใช้อัตรา $r$ (จำนวน GRX atom ต่อ THBG) และค่าธรรมเนียม swap $psi$ (bps)
$ "thbg" = (g dot r) / 10^9 dot (1 - psi slash 10000) $ <eq:swap>
$ g = ("thbg" dot 10^9) / r $ <eq:redeem>
โดยการ redeem ตาม @eq:redeem ไม่มีค่าธรรมเนียม และการรักษาค่าตรึงใช้เงื่อนไข supply ต่อ reserve แบบ 1:1 คือ $"supply"_("thbg") <= "reserve"_("attested")$ ส่วนรางวัลการ stake ใช้ตัวสะสม (accumulator) แบบ MasterChef โดยรางวัลค้างรับของผู้ stake คำนวณจากจำนวนที่ stake $s$
$ "reward" = s dot A slash 10^12 - "debt" $ <eq:reward>
เมื่อมีการเติมรางวัล $R$ ตัวสะสม $A$ จะถูกปรับเป็น $A <- A + (R dot 10^12) slash s_("total")$ แบบ pro-rata ตามสัดส่วนการ stake และการ slash จะหักเต็มจำนวนที่ร้องขอแล้วกระจายคืนสู่ผู้ stake ที่เหลือผ่านตัวสะสมเดียวกัน

ในเส้นทาง CDA ที่ใช้งานจริง ตัวคูณจูงใจถูกตั้งเป็น $m = 1$ กล่าวคือ incentive multiplier มีผลเฉพาะเส้นทาง settlement แบบ feed-in หรือ grid-export มิใช่การจับคู่ CDA นอกจากนี้ค่าตั้งต้นของค่าธรรมเนียมตลาดบนเชน (25 bps) แตกต่างจากค่าตั้งต้นในไฟล์ตั้งค่านอกเชน (50 bps) และพารามิเตอร์โซนในโปรแกรม governance จัดเก็บแบบสเกล ×1000 ขณะที่ผู้บริโภคค่าจริงในชั้น trading ตีความแบบ bps ($slash 10000$) ซึ่งเป็นค่าที่ระบบใช้งานจริง ทั้งนี้การคำนวณในโค้ดใช้เลขทศนิยมตายตัว (fixed-point integer) แบบปัดลง (floor division) และยอดสุทธิถูกจำกัดไม่ให้ติดลบด้วย saturating subtraction ดังนั้นสมการข้างต้นจึงเป็นแบบจำลองเชิงค่าจริงที่อาจต่างจากผลคำนวณจริงในระดับเศษปัด

#heading(level: 2)[Trade Lifecycle Sequence]
ลำดับการซื้อขายถูกแบ่งขอบเขตการทำงานระหว่าง off-chain และ on-chain อย่างชัดเจน ดัง @fig:trade-lifecycle ฝั่ง off-chain รับผิดชอบการรวบรวมข้อมูล Smart Meter การยืนยันตัวตน การตรวจสอบเวลาอ้างอิง การประเมินเงื่อนไข Grid stability และการคำนวณคู่คำสั่งที่เสนอให้ clear ส่วนฝั่ง on-chain รับผิดชอบเฉพาะการยืนยัน account state, ลายเซ็น Ed25519 ของผู้ซื้อและผู้ขายบน order payload ที่ลงนามไว้, bounded matched pair, escrow และการบันทึก settlement event

กระบวนการนี้ช่วยให้ธุรกรรมพลังงานมีความโปร่งใสและตรวจสอบย้อนหลังได้ พร้อมลดความเสี่ยงจากการนำข้อมูล Smart Meter ที่ยังไม่ผ่านการยืนยันเข้าสู่บล็อกเชนโดยตรง การแยก boundary ระหว่าง off-chain verification และ on-chain settlement จึงเป็นหลักสำคัญในการรักษาทั้งประสิทธิภาพของระบบและความปลอดภัยของไมโครกริด ข้อจำกัดของแนวทางนี้คือผู้ใช้ต้องเชื่อถือ Aggregator Bridge และ governance ของ oracle_authority หากต้องการลด trust เพิ่มเติมควรเพิ่ม multi-oracle attestation หรือหลักฐาน cryptographic proof ในอนาคต

#figure(
  [
    #set align(left)
    #let _tag(t, f) = box(fill: f, inset: (x: 4pt, y: 1.5pt), radius: 2pt)[#text(size: 6pt, fill: white)[#t]]
    #let _row(tag, body) = grid(columns: (auto, 1fr), gutter: 6pt, align: (horizon, horizon),
      tag, text(size: 7pt)[#body])
    #block(width: 100%, inset: 2pt)[
      #_row(_tag("OFF", rgb("#5b7aa8")), [Smart Meter ส่งค่าอ่าน (ลงนาม Ed25519)])
      #_down
      #_row(_tag("OFF", rgb("#5b7aa8")), [Aggregator Bridge: ตรวจลายเซ็น + available surplus + Grid stability])
      #_down
      #_row(_tag("OFF", rgb("#5b7aa8")), [Trading Service: จับคู่คำสั่งด้วย CDA → submit settle_offchain_match])
      #_down
      #_row(_tag("ON", rgb("#3c8c5a")), [ตรวจ account state + ลายเซ็น Ed25519 ของผู้ซื้อและผู้ขาย])
      #_down
      #_row(_tag("ON", rgb("#3c8c5a")), [ตรวจ order nullifier (replay) + สถานะ escrow])
      #_down
      #_row(_tag("ON", rgb("#3c8c5a")), [บันทึก settlement event — PDA state · Event log])
      #_down
      #_row(_tag("OFF", rgb("#5b7aa8")), [Event log → Frontend Dashboard])
    ]
  ],
  caption: [Trade lifecycle: off-chain verification and CDA matching, then on-chain settlement and audit.],
) <fig:trade-lifecycle>
