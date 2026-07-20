#import "@preview/fletcher:0.5.8" as fletcher: diagram, node, edge, shapes
#import "@preview/cetz:0.5.2"
#import "@preview/chronos:0.3.0"

= SYSTEM DESIGN AND IMPLEMENTATION <sec:system-architecture>

== Architecture Overview
สถาปัตยกรรมของระบบถูกออกแบบเพื่อรองรับการจำลองการซื้อขายพลังงานแบบ Peer-to-Peer ในบทความนี้นำเสนอแบบจำลองไมโครกริด โดยแบ่งเส้นทางข้อมูลออกเป็นชั้น Smart Meter, Aggregator Bridge, Trading Service, Anchor Smart Contract Program, Settlement Engine และ Frontend Dashboard โดยข้อมูลการผลิตและการใช้พลังงานถูกสร้างจาก Smart Meter Simulator แล้วส่งเข้าสู่ Aggregator Bridge เพื่อคัดกรองข้อมูลก่อนแปลงเป็นคำสั่งธุรกรรมสำหรับ Anchor program บนเครือข่าย Solana-compatible แบบ permissioned การแบ่งระบบออกเป็นโดเมนนอกเชนและบนเชน พร้อมเส้นทางข้อมูลหลักและจุดข้ามขอบเขตความเชื่อถือ สรุปไว้ใน@fig:system-architecture

#figure(
  text(size: 5.5pt)[
    #let blob(pos, label, tint: gray, ..args) = node(pos, align(center, label),
      width: 4.6cm, fill: tint.lighten(75%), stroke: 0.6pt + tint.darken(15%),
      corner-radius: 2.5pt, inset: 3pt, ..args)
    #diagram(
      spacing: (4mm, 6mm),
      edge-stroke: 0.5pt + rgb("#777"),
      mark-scale: 60%,
      {
        let blue = rgb("#5b7aa8")
        let orange = rgb("#c77d3c")
        let green = rgb("#3c8c5a")
        let purple = rgb("#7a5b9e")
        let gray = rgb("#888")
        blob((0, 0), [*Smart Meter Simulator* \ AMI · DLMS/COSEM · Ed25519], tint: blue)
        blob((0, 1), [*Aggregator Bridge* \ verify Ed25519 · Redis · 15-min window], tint: orange)
        blob((0, 2), [*Trading Service* — CDA matching], tint: blue)
        node((1.35, 2), align(center)[*IAM*], width: 1.3cm, fill: gray.lighten(75%), stroke: 0.6pt + gray.darken(15%), corner-radius: 2.5pt, inset: 3pt)
        blob((0, 3), [*Chain Bridge* \ sole Solana RPC · NATS · gRPC · mTLS], tint: purple)
        blob((0, 4), [*Anchor programs* \ registry · trading · oracle \ energy-token · governance · treasury], tint: green)
        node(enclose: ((0, 0), (1.35, 2)), align(top + left, text(5pt, weight: "bold", fill: orange.darken(10%))[Off-chain domain — verify & match]), stroke: (paint: orange, dash: "dashed", thickness: 0.7pt), fill: orange.lighten(94%), inset: 9pt)
        node(enclose: ((0, 4),), align(top + left, text(5pt, weight: "bold", fill: green.darken(10%))[On-chain domain — settle & audit]), stroke: (paint: green, dash: "dashed", thickness: 0.7pt), fill: green.lighten(94%), inset: 9pt)
        edge((0, 0), (0, 1), "-|>", label: text(4.5pt)[signed readings])
        edge((0, 1), (0, 2), "-|>", label: text(4.5pt)[validated])
        edge((0, 2), (0, 3), "-|>", label: text(4.5pt)[matched pair])
        edge((0, 3), (0, 4), "-|>", label: text(4.5pt)[`chain.tx.*` / gRPC])
        edge((1.35, 2), (0, 2), "<|-|>")
      },
    )
  ],
  caption: [System architecture and the off-chain/on-chain trust boundary. The off-chain domain (orange, dashed) verifies Ed25519-signed meter telemetry, aggregates it, and matches orders via CDA; the on-chain domain (green, dashed) settles and audits the verified pairs. Chain Bridge is the sole crossing between the two — the only service touching Solana RPC, writing via NATS `chain.tx.*` and reading via gRPC over mTLS.],
) <fig:system-architecture>

การแยกองค์ประกอบในลักษณะนี้ทำให้การตรวจสอบเชิงวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์เกิดขึ้นก่อนบันทึกธุรกรรม ขณะที่ Anchor program ทำหน้าที่เป็นชั้นบังคับใช้กติกาที่ตรวจสอบได้และบันทึกสถานะเพื่อการตรวจสอบย้อนหลัง ส่วน Settlement Engine ทำหน้าที่จัดการธุรกรรมที่ลงนามแล้ว ติดตามผลจาก transaction signature และอ่าน Event log เพื่อนำสถานะกลับไปแสดงบน Frontend


== Backend Services
ชั้น Backend ทำหน้าที่เป็นชั้นกลางระหว่าง Smart Meter Simulator (ดู@sec:grid-simulator), Aggregator Bridge และ Smart Contract โดยรับผิดชอบการรวบรวมข้อมูล การตรวจสอบความถูกต้อง การจัดคิวธุรกรรม และการส่งคำสั่งไปยังบล็อกเชนหลังจากข้อมูลผ่านเงื่อนไขด้าน Grid stability แล้วเท่านั้น การออกแบบใช้แนวคิด Microservice เพื่อแยกภาระงานออกเป็นภาระงานย่อย ทำให้ขยายระบบเฉพาะส่วนที่มีปริมาณคำขอสูงและลดผลกระทบเมื่อบริการใดบริการหนึ่งเกิดความผิดพลาด รายละเอียดของช่องทางสื่อสารระหว่างบริการ (ConnectRPC บน mTLS และ NATS JetStream) และสมมติฐานความเชื่อถือที่เกี่ยวข้องอธิบายไว้ใน@sec:threat-model องค์ประกอบหลักของชั้น Backend ประกอบด้วย
- IAM Service: จัดการตัวตน สิทธิ์การเข้าถึงข้อมูล On-chain และบทบาทของผู้ใช้งาน เช่น Prosumer, Consumer และ Operator
- Aggregator Bridge: รับข้อมูลการผลิตและการใช้ไฟฟ้าจาก Smart Meter ตรวจสอบรูปแบบข้อมูล เวลาอ้างอิง รหัสอุปกรณ์ และค่าพลังงานก่อนส่งต่อไปยังขั้นตอนวิเคราะห์
- Trading Service: ตรวจสอบและจับคู่คำสั่งซื้อขายพลังงานร่วมกับเงื่อนไขด้าน Grid stability เช่น ปริมาณพลังงานคงเหลือ ข้อจำกัดของโครงข่าย และสถานะการเชื่อมต่อของ Smart Meter
- Chain Bridge: ตัวกลางเดียวที่ส่งคำสั่งไปยัง Solana Program และติดตามผลลัพธ์จาก transaction signature หรือ Event log โดยบริการอื่นไม่เรียก Solana RPC โดยตรง
- Notification Service: ส่งการแจ้งเตือน เช่น Email และ Alert เมื่อคำสั่งซื้อขายหรือสถานะ settlement เปลี่ยนแปลง

การแยกบริการในลักษณะนี้ช่วยให้ระบบรองรับข้อมูล Realtime Smart Meter จำนวนมากได้ดีขึ้น เนื่องจากบริการรับข้อมูลขยายจำนวน instance ได้โดยไม่กระทบต่อบริการตรวจสอบธุรกรรมหรือบริการเชื่อมต่อบล็อกเชน นอกจากนี้ชั้น Backend ยังเป็นจุดควบคุมความปลอดภัยก่อนบันทึกธุรกรรมลง Smart Contract ทำให้ระบบไม่พึ่งพาบล็อกเชนเพียงอย่างเดียว แต่ผสานการตรวจสอบทางวิศวกรรมไฟฟ้าและการควบคุมสิทธิ์ของผู้ใช้งานเข้าด้วยกัน

== Grid and Meter Simulation <sec:grid-simulator>

Grid Modeling ออกแบบมาเพื่อจำลองระบบไฟฟ้าที่ซับซ้อน แหล่งผลิตพลังงานแบบกระจาย (Distributed Energy Resources: DERs) และการดำเนินการของ Virtual Power Plant (VPP) จึงช่วยให้การจำลอง Advanced Metering Infrastructure (AMI) และการจัดการโครงข่ายไฟฟ้ามีความแม่นยำสูง แกนหลักของระบบจำลองผสานการประเมินสถานะแบบเวลาจริงที่ผ่านการตรวจสอบทางฟิสิกส์ (Physics-validated State Estimation) และ Optimal Power Flow (OPF) โดยใช้ Pandapower ซึ่งทำให้ระบบสามารถสร้างข้อมูลมาตรวัดแบบ Deterministic สำหรับโครงข่ายไฟฟ้าขนาดใหญ่

#figure(
  image("../picture/grid_bus_network.png", width: 100%),
  caption: [Grid bus network topology used for simulator.],
) <fig:grid-bus-network>

Grid Simulator พัฒนาด้วย Python 3.11 @python311 สำหรับจำลองพฤติกรรมของการใช้ไฟฟ้า Distribution Grid ใช้รูปแบบ Network Topology จากไฟล์ GridLAB-D GLM @chassin2008gridlabd แล้วแปลงเป็น grid modeling ซึ่งประกอบด้วย bus, line, load และ photovoltaic unit ดังแสดงใน@fig:grid-bus-network เครื่องมือหลักที่ใช้ ได้แก่ FastAPI @ramirez2026fastapi, NetworkX @hagberg2008networkx สำหรับแทนโครงสร้าง topology, pvlib @anderson2023pvlib สำหรับจำลอง photovoltaic generation และ pandapower @thurner2018pandapower สำหรับคำนวณ power flow

กระบวนการจำลองทำงานแบบ discrete time-step โดยในแต่ละรอบประกอบด้วยสองขั้นตอนคือ การสร้างค่าอ่านที่ระดับมาตรวัด (ดู@sec:smart-meter-simulator) แล้วตามด้วยการแก้สถานะโครงข่ายที่ระดับ grid (ดู@sec:grid-simulation) นอกจากค่าอ่านสังเคราะห์ ระบบยังสามารถ replay ข้อมูล telemetry จริงจากไฟล์ CSV และเชื่อมโยงข้อมูลกับ bus ผ่าน meter registry ทำให้รองรับ hybrid simulation ระหว่าง measured data และ synthetic data ได้ ความถูกต้องของ simulator ตรวจสอบผ่านชุดทดสอบที่ครอบคลุม topology loading และ meter-to-bus mapping

=== Smart Meter Simulator <sec:smart-meter-simulator>
ในแต่ละ bus ของ topology ระบบสร้างประชากรมาตรวัด (meter population) ตามสัดส่วนชนิดของผู้ใช้ โดยมาตรวัดแต่ละตัว (SmartMeter) ประกอบขึ้นจากแบบจำลองอุปกรณ์ย่อยแบบแยกส่วน ได้แก่ โหลด (Load), แผงเซลล์แสงอาทิตย์ (Solar) เมื่อมีการติดตั้ง และระบบกักเก็บพลังงานแบตเตอรี่ (BESS) แบบเลือกได้ พฤติกรรมการใช้ไฟฟ้าจำลองด้วยแบบจำลองโหลดแบบ ZIP ที่ตอบสนองต่อแรงดัน (voltage-dependent ZIP load) ซึ่งกำลังไฟฟ้าจริงที่ดึงจากโครงข่ายขึ้นกับแรงดันต่อหน่วย (per-unit voltage) ตามสมการ

$ P(V) = P_"base" (Z dot V^2 + I dot V + P), quad Z + I + P = 1 $ <eq:zip-load>

โดยองค์ประกอบ Z (impedance) แปรผันตาม $V^2$, องค์ประกอบ I (current) แปรผันตาม $V$ และองค์ประกอบ P (power) คงที่ มาตรวัดในการประเมินนี้ตั้งสัดส่วน impedance ไว้ที่ 0.20 (`ZIP_IMPEDANCE_FRACTION=0.20`) และตรึงแรงดันให้อยู่ในช่วง $[0, 1.5]$ ต่อหน่วยก่อนคำนวณ ส่วนกำลังผลิตจากแผงเซลล์แสงอาทิตย์คำนวณด้วย pvlib @anderson2023pvlib โดยใช้แบบจำลองท้องฟ้าใส (clear-sky) แบบ Ineichen ร่วมกับแบบจำลอง PVWatts สำหรับกำลังไฟฟ้ากระแสตรง แล้วลดทอนด้วยตัวประกอบสภาพอากาศ (weather derate factor) เช่น เมฆมาก (cloudy) คูณ 0.42 และมีเมฆบางส่วน (partly cloudy) คูณ 0.72 หากไม่มี pvlib ระบบจะถอยไปใช้โปรไฟล์การผลิตแบบฟังก์ชันเป็นค่าสำรอง

เพื่อให้การจำลองทำซ้ำได้ (deterministic) มาตรวัดแต่ละตัวสุ่มสัญญาณรบกวนจากสตรีมเฉพาะของตน โดยเพาะค่าเริ่มต้น (seed) ของตัวสุ่มจากการ XOR ระหว่าง seed รวมของระบบกับไดเจสต์ SHA-256 ของรหัสมาตรวัด ทำให้การเพิ่มหรือลบมาตรวัดหนึ่งตัวไม่ทำให้ค่าอ่านของมาตรวัดตัวอื่นเคลื่อน ผลลัพธ์ต่อหนึ่งรอบคือเรคคอร์ดค่าอ่านพลังงาน (EnergyReading) ที่บรรจุพลังงานที่ผลิต พลังงานที่ใช้ พลังงานส่วนเกิน (surplus) และพลังงานส่วนขาด (deficit) เป็นหน่วย kWh ที่ไม่เป็นลบ พร้อมความยาวช่วงเวลา (interval) ของรอบนั้น ก่อนส่งออก มาตรวัดแต่ละตัวมีอัตลักษณ์ Ed25519 เฉพาะตัว (per-meter key) ที่สร้างขึ้นแบบกำหนดได้จาก SHA-256 ของ `secret:meter_id` แล้วลงนามบนสายอักขระตามแบบแผน (canonical string) รูปแบบ `device_id:kwh:timestamp_ms` ส่งออกเป็นลายเซ็น base58 ทำให้ Aggregator Bridge ตรวจสอบที่มาของค่าอ่านได้รายจุดโดยไม่ต้องเก็บกุญแจลับของมาตรวัดไว้ที่ส่วนกลาง

=== Grid Simulation <sec:grid-simulation>
ในแต่ละรอบเวลา (tick) เมื่อรวบรวมค่าอ่านของมาตรวัดทุกตัวแล้ว ระบบจะคำนวณการอัดกำลังสุทธิ (net power injection) ของแต่ละ bus จากผลต่างระหว่างการผลิตและการใช้ไฟฟ้า แล้วแก้ปัญหา power flow เพื่ออัปเดตสถานะโครงข่าย ได้แก่ แรงดันต่อหน่วยของ bus, การไหลของกำลังในสาย (line flow), กำลังสูญเสีย (power loss) และระดับการใช้งานของสาย (line utilization) ตัวแก้หลักใช้ pandapower @thurner2018pandapower แบบ backward/forward sweep (BFSW) ซึ่งเป็นการแก้ AC power flow แบบแม่นยำสำหรับโครงข่ายจำหน่ายแบบรัศมี (radial distribution) และเมื่อ pandapower ไม่พร้อมใช้งานหรือการคำนวณไม่ลู่เข้า (non-convergence) ระบบจะถอยไปใช้ตัวแก้แบบประมาณ DistFlow เป็นค่าสำรองเพื่อให้การจำลองดำเนินต่อได้

นอกจากการแก้ power flow พื้นฐาน ชั้น grid simulation ยังจำลองกลไกควบคุมแรงดันและเหตุการณ์ผิดปกติของโครงข่ายจำหน่าย ได้แก่ การตอบสนองของอินเวอร์เตอร์แบบ volt-watt และ volt-VAR การปรับแทปหม้อแปลงแบบ on-load tap changer (OLTC) การฉีดความผิดพร่อง (fault injection) ที่สาย bus หรือหม้อแปลง และการสับสวิตช์เชื่อมโยง (tie-switch) เพื่อถ่ายโอนโหลด ทำให้ชุดข้อมูลที่ส่งออกไปยัง Aggregator Bridge สะท้อนพฤติกรรมเชิงฟิสิกส์ของโครงข่ายภายใต้สภาวะการทำงานและสภาวะผิดปกติที่หลากหลาย มิใช่เพียงค่าพลังงานที่สุ่มขึ้นอย่างอิสระ ทั้งนี้ความสามารถด้านฟิสิกส์ของโครงข่ายข้างต้น (volt-VAR, OLTC, fault injection และ tie-switch) เป็นส่วนหนึ่งของชุดจำลอง แต่ยังไม่ได้ใช้เป็นตัวแปรในการประเมินที่รายงานในบทความนี้ ซึ่งวัดเฉพาะอัตราการรับค่าอ่านที่ลงนามแล้ว ต้นทุนการชำระบนเชน และอัตราการจับคู่ (ดู@sec:evaluation) การประเมินผลกระทบของเงื่อนไข Grid stability เหล่านี้ต่อการจับคู่และการชำระจึงเป็นงานในอนาคต

เพื่อให้เป็นไปตามมาตรฐานอุตสาหกรรมและรับรองที่มาของข้อมูล Aggregator Bridge รับข้อมูลมาตรวัดความถี่สูงแบบเวลาจริงแล้วกระจายผ่าน Redis Streams ที่แบ่งตามโซน (zone-partitioned) สำหรับการเฝ้าระวังสถานะโครงข่ายแบบพลวัต พร้อมรวมค่าอ่านเป็นหน้าต่างเวลา 15 นาทีเพื่อใช้ในการประเมินกำลังการผลิตและการสั่งการ (dispatch) ในชั้น Backend รูปแบบข้อมูลมาตรวัดเป็นไปตามมาตรฐาน DLMS/COSEM (IEC 62056) โดยถอดรหัสส่วน payload แบบ Binary ด้วย AES-256-GCM และเผยแพร่ต่อในรูปแบบ JSON นอกจากนี้ ระบบรับประกันความไม่ปฏิเสธเชิงรหัสวิทยา (Cryptographic Non-repudiation) ด้วยการตรวจสอบลายเซ็นเข้ารหัสแบบอสมมาตร Ed25519 ทั้งแบบค่าอ่านรายจุดและแบบกลุ่ม (Batch) ก่อนรับข้อมูลเข้าสู่ระบบ ทั้งนี้ในต้นแบบปัจจุบันยังไม่มีเส้นทางสร้าง Settlement Attestation บนเชนโดยตรงจากชั้นมาตรวัด ซึ่งเป็นแนวทางที่เปิดไว้สำหรับงานในอนาคต เส้นทางการกระจายข้อมูลของ Aggregator Bridge สรุปไว้ใน @fig:telemetry-dissemination

#figure(
  text(size: 5.5pt)[
    #let blob(pos, label, tint: gray, ..args) = node(pos, align(center, label),
      width: 2.3cm, fill: tint.lighten(72%), stroke: 0.5pt + tint.darken(15%),
      corner-radius: 2.5pt, inset: 3pt, ..args)
    #diagram(
      spacing: (2.5mm, 7mm),
      edge-stroke: 0.5pt + rgb("#777"),
      mark-scale: 60%,
      {
        let blue = rgb("#5b7aa8")
        let orange = rgb("#c77d3c")
        let green = rgb("#3c8c5a")
        // meters → bridge → three dissemination sinks (cylinders) → consumers
        blob((1, 0), [*Smart Meters (AMI)* \ Ed25519-signed · DLMS/COSEM], tint: blue)
        blob((1, 1), [*Aggregator Bridge* \ ตรวจ Ed25519 · ถอด AES-256-GCM], tint: orange)
        blob((0, 2), [Zone Redis Streams `events:zone_0..n`], tint: blue, shape: shapes.cylinder)
        blob((1, 2), [InfluxDB v2 history (async)], tint: green, shape: shapes.cylinder)
        blob((2, 2), [Window bins `(meter_id, window_start_ms)`], tint: orange, shape: shapes.cylinder)
        blob((0, 3), [Trading (CDA) · grid-state monitoring], tint: blue)
        blob((2, 3), [Dispatch · mint (energy-token)], tint: green)
        edge((1, 0), (1, 1), "-|>", label: text(4.5pt, fill: rgb("#777"))[signed readings])
        edge((1, 1), (0, 2), "-|>")
        edge((1, 1), (1, 2), "-|>")
        edge((1, 1), (2, 2), "-|>")
        edge((0, 2), (0, 3), "-|>")
        edge((2, 2), (2, 3), "-|>")
      },
    )
  ],
  caption: [Aggregator Bridge telemetry dissemination: verified readings fan out to zone-partitioned Redis Streams (realtime), an InfluxDB history sink (async, fire-and-forget), and 15-min aggregation windows keyed by `(meter_id, window_start_ms)`. Each sink sits above the consumer it feeds; the InfluxDB history sink is terminal.],
) <fig:telemetry-dissemination>

== Consortium Network <sec:consortium-network>
เครือข่ายบล็อกเชนในระบบนี้ออกแบบเป็น Consortium Network ภายใต้สมมติฐานการกำกับการเข้าร่วมแบบ Proof of Authority (PoA) ตามที่อธิบายไว้ใน@sec:settlement-model ส่วนนี้จึงเน้นรายละเอียดการออกแบบเครือข่ายและการกำกับดูแลเป็นหลัก การออกแบบทำให้ผู้ตรวจสอบบล็อกเป็นหน่วยงานมีหน้าที่ตรวจสอบหรือได้รับยินยอมจาก DSO เช่น ผู้ให้บริการรวบรวมโหลด (Load Aggregator) หน่วยงานกำกับดูแลหรือองค์กรที่ได้รับอนุญาต เหตุผลหลักในการเลือก PoA คือ Network Governance ที่ควบคุมได้ง่ายกว่าเครือข่ายสาธารณะ เช่น Solana Mainnet, Ethereum และความเหมาะสมต่อข้อกำหนดด้าน Regulatory compliance และ cost predictability สำหรับการทดลองหรือใช้งานในระบบพลังงานที่ต้องประมาณต้นทุนธุรกรรมได้ล่วงหน้า @joshi2021poa @androulaki2018hyperledger สิ่งสำคัญที่ต้องเน้นย้ำคือ PoA ในที่นี้เป็นชั้น governance และการควบคุมสิทธิ์การเข้าร่วม (admission control) ไม่ใช่การแทนที่กลไกฉันทามติระดับ Layer 1 ของเครือข่าย Solana-compatible ซึ่งยังคงอาศัย Proof of History (PoH) ร่วมกับ Tower BFT ในการเรียงลำดับและประกาศสิ้นสุดบล็อก (finality) ตามที่อธิบายไว้ใน@sec:settlement-model

นโยบายด้านสิทธิ์และการกำกับดูแลถูกบังคับใช้ผ่านโปรแกรม governance บนเชน ซึ่งครอบคลุมสามกลไกหลัก กลไกแรกคือการกำกับหน่วยงานผู้มีสิทธิ์หลัก (PoA authority) ผ่านการโอนสิทธิ์แบบสองขั้นตอน (two-step handover) โดย propose_authority_change ให้ผู้มีสิทธิ์ปัจจุบันกำหนด pending authority พร้อมเวลาหมดอายุ และ approve_authority_change ต้องถูกเรียกโดย pending authority เองเพื่อรับโอน ทำให้ไม่สามารถยกสิทธิ์ให้บัญชีที่ไม่ยินยอมหรือผิดพลาดได้ และอนุญาตให้มีคำขอเปลี่ยนค้างได้เพียงรายการเดียวต่อครั้ง กลไกที่สองคือการควบคุม allow-list ของ Aggregator ที่ได้รับอนุญาตให้ลงนามค่าอ่านผ่าน admit_aggregator และ revoke_aggregator กลไกที่สามคือการลงคะแนนแบบ DAO ผ่าน create_proposal, cast_vote และ execute_proposal สำหรับปรับพารามิเตอร์เชิงเศรษฐศาสตร์ของแต่ละโซน (zone_config) ได้แก่ incentive multiplier, wheeling charge, loss factor และ maintenance mode

การลงคะแนนใช้น้ำหนักตามกำลังการผลิตสะสมของมาตรวัด (stake-by-generation) โดยน้ำหนักของผู้ลงคะแนนคำนวณเป็น $w = op("max")(100, "total generation" / 1000)$ กล่าวคือทุก 1,000 kWh ของการผลิตสะสมเทียบเท่าหนึ่งหน่วยน้ำหนัก โดยมีค่าขั้นต่ำ 100 เพื่อให้ผู้เข้าร่วมรายเล็กยังมีเสียง การกันลงคะแนนซ้ำใช้บัญชี vote record แบบ PDA ต่อคู่ (proposal, voter) หนึ่งบัญชีต่อหนึ่งเสียง เมื่อสิ้นสุดช่วงเวลาลงคะแนน execute_proposal จะสรุปผลแบบอัตโนมัติ ข้อเสนอจะผ่าน (Passed) ก็ต่อเมื่อผลรวมคะแนนถึงเกณฑ์องค์ประชุมขั้นต่ำ (min_quorum_votes ที่กำหนดใน poa_config) และคะแนนเห็นด้วยมากกว่าคะแนนไม่เห็นด้วย มิฉะนั้นถือว่าตกไป (Rejected) จึงป้องกันการเปลี่ยนพารามิเตอร์ด้วยผู้ลงคะแนนจำนวนน้อยเกินไป

ความแตกต่างจาก Solana public mainnet คือเครือข่ายนี้ไม่เปิดให้ validator ภายนอกเข้าร่วมแบบ permissionless และสามารถกำหนดนโยบายด้านสิทธิ์ การอัปเกรดโปรแกรม และการเก็บข้อมูลตามข้อกำหนดของโครงการได้ อย่างไรก็ตาม execution layer ยังคงอ้างอิงสถาปัตยกรรม Solana Virtual Machine และ Sealevel parallel runtime เพื่อให้ธุรกรรมที่ไม่ใช้ account เดียวกันสามารถประมวลผลแบบขนานได้ ค่า slot time ใกล้ 400 ms และ compute budget ที่กล่าวถึงในบทความนี้เป็นเป้าหมายเชิงออกแบบที่อ้างอิงเอกสาร Solana ไม่ใช่ผลวัดของเครือข่าย permissioned การแบ่งบทบาทของชั้นกำกับดูแลแบบ PoA (admission control) ออกจากชั้นฉันทามติระดับ Layer 1 ที่ยังคงอาศัย PoH สำหรับการเรียงลำดับเวลาและ Tower BFT สำหรับการลงมติและประกาศ finality แสดงใน@fig:poa-consensus @yakovenkoSolanaWhitepaper

#figure(
  text(size: 6.5pt)[
    #let blue = rgb("#2f6fb0")
    #let green = rgb("#3c8c5a")
    #let orange = rgb("#c97a26")
    #diagram(
      spacing: (6pt, 11pt),
      node-stroke: 0.6pt,
      {
        // Governance layer (PoA): admission control over the validator set
        node((1, 0), align(center)[*PoA Governance Authority* \ admission control \ admit / revoke validator],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: rgb("#eef3fb"))
        node((1, 1), align(center)[*Authorized Validator Set* \ $V_1, V_2, ..., V_n$ \ (permissioned)],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + blue, fill: rgb("#eef3fb"))
        edge((1, 0), (1, 1), "-|>", stroke: 0.6pt + blue, label: text(5.5pt, fill: blue)[admits])

        // Layer 1 consensus pipeline (unchanged Solana mechanism)
        node((0, 2), align(center)[*Leader slot* \ PoH ordering \ (verifiable clock)],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + green, fill: rgb("#e8f5ec"))
        node((1, 2), align(center)[*Tower BFT* \ stake-weighted vote \ (supermajority)],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + green, fill: rgb("#e8f5ec"))
        node((2, 2), align(center)[*Finality* \ block committed \ settlement tx durable],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + orange, fill: rgb("#fbf0e6"))
        edge((1, 1), (0, 2), "-|>", stroke: 0.6pt + green, label: text(5.5pt, fill: green)[propose])
        edge((0, 2), (1, 2), "-|>", stroke: 0.6pt + green)
        edge((1, 2), (2, 2), "-|>", stroke: 0.6pt + orange)
      },
    )
  ],
  caption: [Separation of concerns in the consortium network (illustrative): the PoA layer governs admission control over an authorized validator set, while Layer 1 consensus is unchanged — PoH provides verifiable time ordering and Tower BFT provides stake-weighted voting and finality. Roles, not measured throughput.],
) <fig:poa-consensus>

ในระดับเครือข่ายดังกล่าวต้องกำหนดอย่างน้อยห้ารายการก่อนนำไปใช้งานจริง ได้แก่ จำนวน Validator และหน่วยงานเจ้าของโหนด วิธีผูก identity กับกุญแจ Validator นโยบายเพิ่มหรือลบ Validator กระบวนการอัปเกรดโปรแกรมหรือ genesis/configuration และ fault model ที่ยอมรับได้ บทความนี้จึงถือว่า PoA Solana-compatible network เป็นสมมติฐานเชิงสถาปัตยกรรมของระบบจำลอง ไม่ใช่ข้อสรุปว่ามีการปรับแต่ง consensus ของ Solana public network แล้ว

== Smart Contract Programs <sec:smart-contract-programs>
Smart Contract แบ่งออกเป็นหลายโปรแกรมตามความรับผิดชอบ ได้แก่ registry, trading, oracle, energy-token, governance และ treasury รวมถึงโปรแกรมสำหรับการทดสอบประสิทธิภาพ (blockbench และ tpc-benchmark) ซึ่งพัฒนาด้วย Anchor Framework เพื่อกำหนด account validation, instruction handler และ Event log อย่างเป็นระบบ โปรแกรม registry มี register_user และ register_meter สำหรับลงทะเบียนผู้ใช้และ Smart Meter ส่วนโปรแกรม trading มี create_sell_order และ create_buy_order (รวมถึง submit_limit_order และ submit_market_order) สำหรับส่งคำสั่งขายและซื้อพลังงาน, match_orders และ clear_auction สำหรับจับคู่คำสั่งซื้อขายที่ Backend เสนอมา, settle_offchain_match และ execute_atomic_settlement สำหรับชำระธุรกรรมแบบ atomic settlement โดย settle_offchain_match จะตรวจสอบลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายและใช้ order nullifier เพื่อกันการส่งซ้ำ และโปรแกรม energy-token มี mint_generation และ mint_to_wallet สำหรับสร้าง energy token ที่ต้องผ่านการร่วมลงนามของ REC certifying authority (Renewable Energy Certificate) โดย mint_generation ใช้คีย์ (meter_id, ช่วงเวลา settlement) เพื่อรับประกัน idempotency ต่อหนึ่งหน้าต่างเวลา และ burn_tokens สำหรับเผา energy token ผ่านคำสั่ง SPL นอกจากนี้ โปรแกรม oracle มี submit_meter_reading สำหรับรับค่าอ่านจาก AMI, trigger_market_clearing สำหรับกำหนดขอบเขตหน้าต่างเวลา 15 นาที (900 วินาที) และ aggregate_readings สำหรับรวมตัวนับค่าอ่านที่ผ่านและไม่ผ่านการตรวจสอบ ลำดับเวลาของหน้าต่างรวมข้อมูลและการเคลียร์ตลาดแสดงใน@fig:clearing-window โปรแกรม governance ทำหน้าที่เป็นชั้นควบคุมแบบ PoA สำหรับการรับรองและเพิกถอน Renewable Energy Certificate (REC) การกำกับสิทธิ์ผู้มีอำนาจ การจัดการ allow-list ของ aggregator และการลงคะแนนแบบ DAO (โครงสร้างบัญชีและบทบาทชั้นควบคุมอธิบายใน@sec:governance-control-plane รายละเอียดการกำกับดูแลเครือข่ายในส่วน Consortium Network) โปรแกรม treasury จัดการการ stake โทเคน GRX การจ่ายรางวัล และการรักษาค่าตรึงของ THBC stablecoin ผ่านคำสั่งเช่น stake_grx, unstake_grx, claim_rewards, swap_grx_for_thbc, redeem_thbc_for_grx และ record_settlement ที่เรียกผ่าน Cross-Program Invocation (CPI) จากโปรแกรม trading ส่วนโปรแกรม blockbench และ tpc-benchmark ใช้รัน workload มาตรฐาน ได้แก่ Blockbench micro-benchmark, YCSB, SmallBank และ TPC-C สำหรับการประเมินประสิทธิภาพบนเครือข่าย Solana-compatible @anchorDocs @splTokenDocs รหัสโปรแกรมบนเชน (program ID) ของโปรแกรมหลักทั้งหกซึ่งประกาศด้วย `declare_id!` สรุปไว้ใน@tbl:program-ids

#figure(
  caption: [On-chain program identities (Anchor `declare_id!`) of the six core programs on the Solana-compatible consortium network. These deterministic addresses pin the deployed artifact for reproducibility.],
  text(size: 7pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal", size: 6.5pt)
    #table(
      columns: (auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, left + horizon),
      table.header([โปรแกรม], [Program ID (`declare_id!`)]),
      [registry], [`FcSd5x4X1nzJMKLZC4tMZXnQ1ipLrGsEfeoH8N4mvJX7`],
      [trading], [`CnWDEUhTvSixeLSyViWgAnnu9YouBAYVGcrrFm1s9WcX`],
      [oracle], [`64Vgos61STZ8pW9NnHi2iGtXMTQr7NqBoMorK6Zg8RJU`],
      [energy-token], [`6FZKcVKCLFSNLMxypFJGU4K14xUBnxNW9VAuKGhmqjGX`],
      [governance], [`FokVuBSPXP11aeL7VZWd8n8aVAhWqVpyPZETToSxdvTS`],
      [treasury], [`FfxSQYKUmx9NGdCC9TDPmZSYjWYE1h4ruu3JatzHN5Tn`],
    )
  ],
) <tbl:program-ids>

โครงสร้างบัญชีใช้ Program Derived Address (PDA) เพื่อแยก state ของระบบออกเป็นบัญชีย่อยตาม seed เฉพาะ เช่น registry และ user account, meter account, market และ market_shard, order และ trade record, escrow, order nullifier สำหรับป้องกันการส่งซ้ำ, oracle_data และ mint authority (gen_mint, thbc_mint) การใช้ PDA ทำให้โปรแกรมตรวจสอบ ownership และ deterministic address ของบัญชีได้โดยไม่ต้องพึ่ง private key ของบัญชี state แต่ละรายการ งานที่ใช้ทรัพยากรสูง เช่น การคำนวณราคาแบบซับซ้อน การจับคู่ order book ขนาดใหญ่ หรือการวิเคราะห์ Grid stability จึงถูกย้ายไปทำใน Backend และ Aggregator Bridge ก่อนส่งผลลัพธ์ที่ยืนยันแล้วเข้าสู่ Smart Contract เพื่อให้อยู่ภายใต้ข้อจำกัดด้าน compute ของธุรกรรม @solanaPdaDocs @solanaDocs โดยกลไกจับคู่คำสั่งใน Trading Service ใช้อัลกอริทึม Continuous Double Auction (CDA) แบบ price-time priority ที่แบ่ง order book ตามโซนและคำนึงถึงข้อจำกัดการไหลของพลังงาน (wheeling และ loss) ก่อนส่งคู่คำสั่งที่จับคู่แล้วไปชำระแบบ atomic บน Smart Contract รายละเอียดสูตรการกำหนดราคาและค่าธรรมเนียมอธิบายใน@sec:pricing-model ความสัมพันธ์ระหว่างโปรแกรมทั้งหกแบ่งเป็นสองชนิด คือการเรียกข้ามโปรแกรม (Cross-Program Invocation: CPI) ที่เขียนสถานะ และการอ่านสถานะแบบควบคุม (control-plane read) ที่โปรแกรมหนึ่งอ่านบัญชีของอีกโปรแกรมเพื่อกำหนดสิทธิ์การทำงานโดยไม่เรียก CPI ดังสรุปใน@fig:program-cpi

#figure(
  text(size: 6.5pt)[
    #show raw: set text(size: 5.5pt)
    #let cp = rgb("#2f6fb0")
    #let wr = rgb("#c97a26")
    #let sv = rgb("#3c8c5a")
    #diagram(
      spacing: (12pt, 15pt),
      node-stroke: 0.6pt,
      {
        node((0, 0), align(center)[*oracle* \ `submit_meter_reading`],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))
        node((1, 0), align(center)[*governance* \ PoA control plane],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + cp, fill: rgb("#eef3fb"))
        node((2, 0), align(center)[*trading* \ `settle_offchain_match`],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + wr, fill: rgb("#fbf0e6"))
        node((0, 1), align(center)[*energy-token* \ `mint_generation`],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))
        node((1, 1), align(center)[*registry* \ users · meters · validators],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))
        node((2, 1), align(center)[*treasury* \ `record_settlement` · peg],
          shape: shapes.rect, corner-radius: 2pt, inset: 4pt, stroke: 0.6pt + sv, fill: rgb("#e8f5ec"))

        edge((0, 0), (1, 0), "-|>", stroke: (paint: cp, dash: "dashed", thickness: 0.6pt),
          label: text(5pt, fill: cp)[read `AggregatorEntry`])
        edge((2, 0), (1, 0), "-|>", stroke: (paint: cp, dash: "dashed", thickness: 0.6pt),
          label: text(5pt, fill: cp)[read maintenance / ERC])
        edge((1, 0), (1, 1), "-|>", stroke: 0.6pt + wr,
          label: text(5pt, fill: wr)[CPI `mark_erc_claimed`])
        edge((1, 1), (0, 1), "-|>", stroke: 0.6pt + wr,
          label: text(5pt, fill: wr)[CPI airdrop mint])
        edge((2, 0), (2, 1), "-|>", stroke: 0.6pt + wr,
          label: text(5pt, fill: wr)[CPI `record_settlement`])
      },
    )
  ],
  caption: [Inter-program relationships among the six Anchor programs. Solid arrows are Cross-Program Invocations that write state (governance→registry on ERC issue, registry→energy-token on airdrop, trading→treasury on settlement). Dashed arrows are control-plane reads with no CPI: trading reads `governance` for the maintenance gate and ERC validity, and oracle validates an admitted-aggregator entry before accepting a reading. Governance (blue) is the policy source; trading (orange) initiates on-chain settlement.],
) <fig:program-cpi>

#figure(
  text(size: 6pt)[
    #show raw: set text(size: 5.5pt)
    #let off = rgb("#5b7aa8")
    #let on = rgb("#3c8c5a")
    #cetz.canvas(length: 1cm, {
      import cetz.draw: *
      // shaded 15-minute aggregation window
      rect((0, -0.08), (6, 0.08), stroke: none, fill: off.lighten(82%))
      line((0, 0), (6.7, 0), mark: (end: ">"), stroke: 0.7pt)
      // window boundaries
      line((0, -0.16), (0, 0.16), stroke: 0.7pt + off)
      line((6, -0.16), (6, 0.16), stroke: 0.7pt + on)
      content((0, -0.42), text(6pt)[$t = 0$])
      content((6, -0.42), text(6pt)[$t = 900$ s])
      // incoming signed readings within the window
      for i in (0.5, 1.3, 2.1, 2.9, 3.7, 4.5, 5.3) {
        line((i, 0), (i, 0.32), stroke: 0.5pt + off)
      }
      content((3, 0.66), text(6pt, fill: off)[signed readings · `submit_meter_reading`])
      content((6.35, 0.34), text(6pt, fill: on)[close])
      // post-window pipeline, centered under the axis
      content((3, -1.05), text(6pt, fill: on)[หน้าต่างปิด → `aggregate_readings` → `trigger_market_clearing` → settle])
    })
  ],
  caption: [Market-clearing timeline: signed meter readings ingest continuously over the 15-minute (900 s) aggregation window; at window close the oracle aggregates readings, triggers clearing, and the matched pair is settled on-chain.],
) <fig:clearing-window>

=== Trading: วงจรคำสั่งซื้อขายและ escrow บนเชน <sec:trading-program>
โปรแกรม trading จัดการวงจรชีวิตของคำสั่งซื้อขายและบัญชี escrow บนเชน เสริมกับเส้นทางการชำระใน@sec:settlement-model ผู้ใช้สร้างคำสั่งผ่าน create_sell_order และ create_buy_order (รวมถึง submit_limit_order และ submit_market_order) ซึ่งสร้างบัญชี Order แบบ PDA รายคำสั่งที่ผูกกับเจ้าของ พร้อมกำหนดอายุคำสั่ง (expires_at) ไว้ที่ 24 ชั่วโมง (86,400 วินาที) นับจากเวลาสร้าง ทั้งนี้คำสั่งขายต้องอ้างใบรับรอง ERC ที่ยังไม่หมดอายุก่อนจึงจะสร้างได้ ซึ่งสอดคล้องกับการกำกับด้วย REC ใน@sec:governance-control-plane ก่อนเข้าสู่ตลาด ผู้ใช้ฝากโทเคนเข้าบัญชี escrow ผ่าน deposit_escrow และถอนคืนส่วนที่ไม่ถูกใช้ผ่าน withdraw_escrow โดยบัญชี escrow เป็น SPL token account ภายใต้ PDA ที่ลงนามโดย market_authority

การจับคู่คำสั่งมีสองเส้นทางที่เสริมกัน เส้นทางแรกคือเครื่องจับคู่ในชั้น off-chain (trading-engine) ที่รัน CDA แบบ price-time priority เหนือสมุดคำสั่งทั้งโซนด้วยปริมาณงานสูง (ดู@sec:cda-matching และอัตราที่วัดได้ใน@sec:matching-throughput) เส้นทางที่สองคือคำสั่ง match_orders บนเชนที่ตรวจและบันทึกการจับคู่รายคู่ โดยแตะเฉพาะบัญชี Order สองรายการกับ zone_market แล้วเขียน trade record โดยไม่เคลื่อนย้ายโทเคน จึงมีต้นทุน compute ต่ำ (ดู@fig:cu-profile) ส่วนคำสั่ง cancel_order ลบคำสั่งที่ยังค้างในสมุด

บัญชีระดับตลาดถูกแยกออกเป็นบัญชี zone_market รายโซนที่เก็บความลึกของสมุดคำสั่ง (order book depth) ความจุสายส่ง (capacity) และการไหลที่ผูกพันแล้ว (committed_flow) แยกออกจากบัญชี Market กลาง เพื่อให้การส่งคำสั่งและการบังคับเพดานการไหลข้ามโซนขนานกันได้ตามแบบ Sealevel (ดู@sec:sealevel-sharding) เมื่อคู่คำสั่งผ่านการจับคู่แล้วจะถูกส่งไปชำระแบบ atomic ผ่าน settle_offchain_match ตามแบบจำลองการชำระใน@sec:settlement-model

=== Governance Program: ชั้นควบคุม PoA บนเชน <sec:governance-control-plane>
โปรแกรม governance ทำหน้าที่เป็นชั้นควบคุม (control plane) แบบ Proof of Authority บนเชน ออกแบบเป็นโปรแกรมเดียวที่รวม 20 instruction แบ่งตามหน้าที่เป็นห้าระบบย่อย (กลุ่มคำสั่งหลัก 19 รายการ ร่วมกับคำสั่งสืบค้นสถิติ get_governance_stats อีกหนึ่งรายการ) จุดสำคัญเชิงสถาปัตยกรรมคือ governance ไม่ได้ทำงานโดดเดี่ยว แต่เป็นแหล่งความจริง (source of truth) ที่โปรแกรมอื่นบนเชนอ่านสถานะไปกำหนดพฤติกรรมของตน กล่าวคือ governance บันทึก "นโยบาย" ขณะที่ trading และ oracle เป็นผู้ "บังคับใช้" นโยบายนั้น ณ ขอบเขตของโปรแกรมตนเอง ระบบย่อยทั้งห้าประกอบด้วย
- ระบบสิทธิ์ผู้มีอำนาจ (Authority): initialize_governance สร้างบัญชี singleton เริ่มต้น และการโอนสิทธิ์ทำแบบสองขั้นตอน propose_authority_change → approve_authority_change โดยผู้รับโอนต้องลงนามเอง พร้อม cancel_authority_change และเวลาหมดอายุ 48 ชั่วโมง ไม่มีเส้นทางโอนสิทธิ์แบบขั้นตอนเดียว (อธิบายเพิ่มใน@sec:consortium-network)
- ระบบควบคุมพารามิเตอร์ (Config gates): update_governance_config (เปิด/ปิดการตรวจ ERC และการโอน), update_erc_limits, set_maintenance_mode (สวิตช์หยุดทั้งระบบ), update_authority_info และ set_oracle_authority ทุกคำสั่งต้องลงนามโดย authority
- ระบบใบรับรองพลังงานหมุนเวียน (ERC certificates): issue_erc ตรวจตามนโยบายใน GovernanceConfig แล้วเรียก Cross-Program Invocation (CPI) ไปยัง registry เพื่อทำเครื่องหมายว่าพลังงานถูกอ้างสิทธิ์แล้ว (mark_erc_claimed) ร่วมกับ validate_erc_for_trading, transfer_erc และ revoke_erc
- ระบบลงคะแนน DAO: create_proposal → cast_vote (ถ่วงน้ำหนักตามกำลังผลิต) → execute_proposal โดยจำกัดให้แก้ได้เฉพาะพารามิเตอร์ของ ZoneConfig ที่กำหนดไว้เท่านั้น ไม่แตะต้องอำนาจ PoA (รายละเอียดการถ่วงน้ำหนักและองค์ประชุมใน@sec:consortium-network)
- ระบบ allow-list ของ Aggregator: admit_aggregator และ revoke_aggregator (เฉพาะ authority) ซึ่งแต่ละรายการคือบัญชี PDA เฉพาะ ทำหน้าที่รับเข้า (admission) โหนด validator นอกเชนทีละราย

บัญชีสถานะ (state account) ของโปรแกรมเป็นบัญชี PDA ที่กำหนด address ได้แบบ deterministic จาก seed เฉพาะ ดังสรุปใน@tbl:governance-accounts

#figure(
  caption: [บัญชีสถานะ (PDA) ของโปรแกรม governance: seed และข้อมูลที่เก็บ บัญชี GovernanceConfig เป็น singleton ตรึงขนาดคงที่ 405 ไบต์เพื่อรองรับการอัปเกรด ขณะที่บัญชีที่เหลือสร้างหนึ่งรายการต่อหนึ่งเอนทิตี (per-cert / per-node / per-zone / per-proposal).],
  text(size: 8pt)[
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal")
    #table(
      columns: (auto, auto, 1fr),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, left + horizon, left + horizon),
      table.header([บัญชี (PDA)], [Seed], [เก็บข้อมูล]),
      [`GovernanceConfig`], [`[poa_config]`], [singleton: authority, pending_authority, นโยบาย ERC, maintenance flag, min_quorum_votes และตัวนับ],
      [`ErcCertificate`], [`[erc_certificate,` `cert_id]`], [REC: owner, พลังงาน (kWh), สถานะ, วันหมดอายุ],
      [`AggregatorEntry`], [`[aggregator,` `pubkey]`], [โหนด validator นอกเชนที่ถูก admit (allow-list)],
      [`ZoneConfig`], [`[zone_config,` `zone_id]`], [พารามิเตอร์รายโซน: wheeling charge, incentive, loss factor],
      [`Proposal`], [`[proposal,` `zone, id]`], [ข้อเสนอ DAO: พารามิเตอร์เป้าหมาย, คะแนนเห็นด้วย/ไม่เห็นด้วย, สถานะ, เวลาหมดอายุ],
      [`VoteRecord`], [`[vote,` `proposal, voter]`], [การลงคะแนนหนึ่งเสียงต่อคู่ (proposal, voter)],
    )
  ],
) <tbl:governance-accounts>

จุดที่ทำให้ governance มีสถานะเป็น control plane อย่างแท้จริงคือวิธีที่โปรแกรมอื่นบริโภคสถานะของมัน โปรแกรม trading อ่านบัญชี GovernanceConfig ในทุกคำสั่งสร้างคำสั่งซื้อขาย แล้วเรียก is_operational() เพื่อปิดกั้นการทำงานเมื่อระบบอยู่ในโหมดบำรุงรักษา (maintenance) พร้อมตรวจความสมบูรณ์ของ ERC ก่อนรับคำสั่งขาย ขณะที่โปรแกรม oracle ตรวจบัญชี AggregatorEntry เพื่ออนุญาตเฉพาะโหนดที่ถูก admit แล้ว (หรือ chain bridge ที่กำหนดไว้) ให้ส่งค่าอ่านผ่าน submit_meter_reading ได้ ทั้งสองกรณีเป็นการอ่านสถานะแบบ read-only ด้วยการ deserialize บัญชีเองและตรวจ owner กับ address ของ PDA โดยไม่เรียก CPI ซึ่งหลีกเลี่ยงต้นทุนของ CPI และทำให้การบังคับใช้นโยบาย (gating) เป็นเพียงการตรวจบัญชีที่ส่งเข้ามาในธุรกรรมนั้น ในแง่นี้บัญชี AggregatorEntry จึงเป็นบันทึกบนเชนของการรับเข้าโหนด validator นอกเชน ที่ถูกบังคับใช้จริง ณ จุดที่ oracle รับค่าอ่านเข้าสู่ระบบ

โครงสร้างนี้สะท้อน PoA สองชั้นที่แยกจากกัน ได้แก่ ชั้นปฏิบัติการ (operational) ที่กำหนดว่าใครได้รับอนุญาตให้รัน validator บนเครือข่าย permissioned และชั้นแอปพลิเคชัน (application-layer) ที่ GovernanceConfig.authority ควบคุมสิทธิ์การบริหารโปรแกรม โดย DAO ถูกจำกัดอำนาจ (power-bounded) ให้ปรับได้เฉพาะพารามิเตอร์ของโซน ไม่สามารถยึดอำนาจ authority หรือแก้ allow-list ของ validator ได้ นอกจากนี้บัญชี GovernanceConfig ยังถูกตรึงขนาดไว้คงที่ที่ 405 ไบต์พร้อมพื้นที่สำรอง (`_reserved`) สำหรับการอัปเกรด ทำให้เพิ่มฟิลด์ใหม่ได้โดยไม่ต้องย้าย (migrate) บัญชีเดิม ซึ่งเป็นวินัยด้านการออกแบบที่จำเป็นเมื่อโปรแกรมอื่นต่างพึ่งพา layout ของบัญชีนี้ในการ deserialize เอง

วงจรชีวิตของใบรับรอง ERC ออกแบบรอบคุณสมบัติห้ามอ้างสิทธิ์ซ้ำ (anti-double-claim) ก่อนออกใบรับรอง คำสั่ง issue_erc คำนวณพลังงานที่ยังไม่ถูกอ้างสิทธิ์เป็น $"unclaimed" = "total_generation" - "claimed_erc_generation" - "settled_net_generation"$ แบบ saturating แล้วบังคับว่าปริมาณที่ขอออกต้องไม่เกินค่านี้ ($"energy_amount" <= "unclaimed"$) มิฉะนั้นปฏิเสธ พร้อมตรวจนโยบายจาก GovernanceConfig ผ่าน can_issue_erc() (ระบบต้องอยู่ในสถานะทำงานและเปิดการตรวจ ERC และปริมาณต้องอยู่ในช่วง min_energy ถึง max_erc) เมื่อผ่านเงื่อนไข โปรแกรมเรียก CPI ไปยัง registry เพื่อเพิ่มตัวนับพลังงานที่ถูกอ้างสิทธิ์ (mark_erc_claimed) ทำให้พลังงานหน่วยเดียวกันถูกรับรองซ้ำไม่ได้ ใบรับรองที่ออกใหม่มีสถานะ Valid แต่ตั้งค่า validated_for_trading เป็นเท็จจนกว่าจะผ่านคำสั่ง validate_erc_for_trading (ต้องอยู่ในสถานะทำงาน สถานะ Valid และยังไม่หมดอายุ) ซึ่งเป็นเงื่อนไขบังคับก่อนใบรับรองจะนำไปค้ำคำสั่งซื้อขายได้ ส่วน revoke_erc และ transfer_erc ควบคุมการเพิกถอน (กันการเพิกถอนซ้ำ) และการโอนสิทธิ์ (อนุญาตเฉพาะเมื่อเปิดการโอนใบรับรองหรือเป็นการโอนจากผู้ออกเอง) โดยทุก handler ปรับปรุงตัวนับรวมใน GovernanceConfig (จำนวนใบรับรองที่ออก/ตรวจ/เพิกถอน และพลังงานสะสมที่รับรอง)

วงจรข้อเสนอ DAO มีการ์ดป้องกันหลายชั้นนอกเหนือจากการถ่วงน้ำหนักเสียงตามกำลังผลิต (อธิบายใน@sec:consortium-network) คำสั่ง create_proposal ปฏิเสธช่วงเวลาลงคะแนนที่ไม่เป็นบวก และบังคับว่าผู้เสนอต้องเป็นเจ้าของมาตรวัดที่อ้างอิง โดยอ่านบัญชี MeterAccount แบบ zero-copy แล้วตรวจว่า meter.owner ตรงกับผู้เสนอ คำสั่ง cast_vote รับเฉพาะเมื่อข้อเสนออยู่ในสถานะ Active และเวลายังไม่เลย expires_at มิฉะนั้นปฏิเสธด้วย ProposalExpired และผู้ลงคะแนนต้องเป็นเจ้าของมาตรวัดเช่นกัน การลงคะแนนซ้ำถูกกันด้วยบัญชี VoteRecord PDA ต่อคู่ (proposal, voter) ซึ่งการสร้างบัญชีครั้งที่สองจะล้มเหลวเพราะบัญชีมีอยู่แล้ว คำสั่ง execute_proposal บังคับให้เวลาผ่าน expires_at ก่อน แล้วสรุปผลอัตโนมัติ คือถ้าผลรวมเสียงต่ำกว่าองค์ประชุม (min_quorum_votes) ถือว่าตกไป ถ้าถึงองค์ประชุมและเสียงเห็นด้วยมากกว่าไม่เห็นด้วยจึงผ่าน (กรณีเสียงเท่ากันถือว่าตก) และเมื่อผ่านจะปรับได้เฉพาะพารามิเตอร์ ZoneConfig สี่รายการเท่านั้น ได้แก่ incentive multiplier, wheeling charge, loss factor (ต้องเป็นค่าบวก) และ maintenance mode ตอกย้ำขอบเขตอำนาจที่จำกัดของ DAO

กลไก maintenance แสดงคุณสมบัติของสวิตช์หยุดทั้งระบบ (system-wide kill switch) ผ่านการเขียนบัญชีจุดเดียว เมื่อ authority เรียก set_maintenance_mode(true) ค่า boolean เพียงค่าเดียวบนบัญชี singleton GovernanceConfig จะพลิก ส่งผลให้ทุกคำสั่งสร้างคำสั่งซื้อขายในโปรแกรม trading ทุกโซนถูกปฏิเสธด้วย MaintenanceMode ทันทีโดยไม่ต้อง deploy โปรแกรม trading ใหม่ ทั้งนี้การอ่านฝั่ง trading ข้ามดิสคริมิเนเตอร์ (discriminator) 8 ไบต์แรกของบัญชีแล้วถอดรหัส Borsh ตาม layout ของ struct โดยตรง การ gate จึงทนต่อการเปลี่ยนดิสคริมิเนเตอร์ของบัญชี governance ได้ตราบใดที่ลำดับฟิลด์ไม่เปลี่ยน ซึ่งสอดคล้องกับการตรึงขนาดบัญชีและพื้นที่สำรองที่กล่าวไว้ข้างต้น

=== Registry: การลงทะเบียนและหลักประกันของ Validator <sec:registry-program>
โปรแกรม registry เป็นทะเบียนกลางของผู้ใช้ มาตรวัด และผู้ตรวจสอบ (validator) คำสั่ง register_user และ register_meter สร้างบัญชี UserAccount และ MeterAccount แบบ zero-copy ที่ผูกกับเจ้าของผ่าน PDA นอกจากบทบาททะเบียนแล้ว โปรแกรมนี้ยังถือหลักประกัน (security bond) ของผู้ตรวจสอบ โดย register_validator กำหนดให้ต้องวางเงินค้ำ (stake) GRX ขั้นต่ำ 10,000 GRX (MIN_VALIDATOR_STAKE) ก่อนได้รับสถานะ validator ขณะที่ stake_grx โอน GRX เข้าคลังกลางและมีช่วงรอถอน (cooldown) 24 ชั่วโมง เมื่อผู้ตรวจสอบประพฤติผิด คำสั่ง slash_validator ที่ลงนามโดย authority แบบ PoA จะหักหลักประกันแบบปรับตามความรุนแรง คือ $"slash" = floor("bond" times "slash_bps" slash 10000)$ โดยจ่ายชดเชยผู้เสียหายไม่เกินความเสียหายที่พิสูจน์ได้ ($"compensation" = min("slash", "proven_loss")$) และส่วนที่เหลือเข้ากองทุน slash เพื่อตัดแรงจูงใจการกล่าวหาเพื่อหวังรางวัล การหักเต็มจำนวนเปลี่ยนสถานะเป็น Slashed (ถาวร ห้ามลงทะเบียนซ้ำ) ส่วนการหักบางส่วนจนต่ำกว่าขั้นต่ำเปลี่ยนเป็น Suspended (กู้คืนได้ด้วยการเติมเงินค้ำ) กลไก stake-and-slash นี้เป็นแรงจูงใจเชิงเศรษฐศาสตร์ที่เสริมการควบคุมการเข้าร่วมแบบ PoA นอกจากนี้การมอบโทเคนเริ่มต้น 10 GRX แก่ผู้ใช้ใหม่ถูกแยกออกจาก register_user ไปเป็นคำสั่ง claim_airdrop ต่างหาก (เรียก CPI ไปยัง energy-token เพื่อ mint โดยลงนามด้วย PDA ของ registry) เพื่อให้การลงทะเบียนไม่ล้มเหลวทั้งธุรกรรมหากการ mint มีปัญหา

=== Oracle: การรับค่าอ่านแบบขนานและการเคลียร์ตลาด <sec:oracle-program>
โปรแกรม oracle รับค่าอ่านมาตรวัดเข้าสู่เชนผ่าน submit_meter_reading โดยออกแบบให้เขียนลงบัญชี MeterState รายมาตรวัด (seed `[meter, meter_id]`) ขณะที่บัญชี OracleData ส่วนกลางถูกอ่านอย่างเดียว ค่าอ่านของมาตรวัดต่างตัวจึงมีชุดบัญชีที่เขียน (write set) ไม่ทับซ้อนกันและประมวลผลแบบขนานได้ตามแบบจำลอง Sealevel อย่างไรก็ตามโค้ดระบุข้อจำกัดตามจริงว่า การขนานเกิดขึ้นเมื่อผู้ลงนามจ่ายค่าธรรมเนียม (fee payer) ต่างกันเท่านั้น หากค่าอ่านหลายรายการใช้ผู้ลงนาม gateway เดียวกัน รายการเหล่านั้นยังถูกประมวลผลแบบลำดับเพราะบัญชีผู้จ่ายถูกล็อกเขียน ก่อนรับค่าอ่าน โปรแกรมตรวจความผิดปกติ (anomaly) ด้วยการตรวจช่วงค่าพลังงาน (min/max) และอัตราส่วนการผลิตต่อการใช้ ซึ่งคำนวณแบบจำนวนเต็มเพื่อเลี่ยงเลขทศนิยม ($"produced" times 100 <= "max_ratio" times "consumed"$) ส่วนสิทธิ์การส่งค่าอ่านจำกัดเฉพาะ chain bridge ที่กำหนด หรือโหนดที่อยู่ใน allow-list ของ governance ผ่านการตรวจบัญชี AggregatorEntry ใน authorize_node_caller (ดู@sec:governance-control-plane) การเคลียร์ตลาดทำผ่าน trigger_market_clearing ที่บังคับให้ขอบหน้าต่าง epoch ตรงกับ 900 วินาที (`epoch_timestamp % 900 == 0`) และบันทึก last_cleared_epoch เพื่อกันการเคลียร์ซ้ำหรือย้อนเวลา

=== Energy Token: การออกโทเคนแบบ Idempotent และการกำกับด้วย REC <sec:energy-token-program>
โปรแกรม energy-token จัดการการสร้าง (mint) โทเคนพลังงานภายใต้การกำกับของคณะผู้รับรอง REC เส้นทางการ mint ทั้งสาม (mint_to_wallet, mint_generation, mint_tokens_direct) บังคับให้ผู้ลงนามต้องอยู่ในชุดผู้รับรอง REC (สูงสุด 5 ราย) เมื่อมีการตั้งผู้รับรองไว้แล้ว (`rec_validators_count > 0`) จึงเป็นการร่วมลงนามของหน่วยรับรองพลังงานหมุนเวียนก่อนสร้างโทเคน คำสั่ง mint_generation ที่สร้างโทเคนจากการผลิตจริงรับประกันความไม่ซ้ำซ้อน (idempotency) ต่อหนึ่งหน้าต่างเวลา ด้วยบัญชี GenerationMintRecord รายคู่ (meter_id, window_start_ms) ที่สร้างแบบ init_if_needed และบังคับให้ขอบหน้าต่างตรงกับ 900,000 มิลลิวินาที โดยตั้งธง minted เป็นจริงหลังการ mint สำเร็จเท่านั้น การเรียกซ้ำที่หน้าต่างเดิมจึงคืนค่าเป็น no-op และหากการ mint ล้มเหลว ธงยังเป็นเท็จทำให้ลองใหม่ได้ คำสั่ง mint_tokens_direct เป็นเป้าหมาย CPI ที่ registry เรียกเพื่อมอบโทเคนเริ่มต้น ขณะที่ burn_tokens เผาโทเคนผ่านคำสั่ง SPL Token-2022 ทั้งนี้บัญชี TokenInfo ที่เก็บชุดผู้รับรองและตัวนับเป็นแบบ zero-copy เพื่อให้เส้นทางความถี่สูงอ่านได้โดยไม่ล็อกเขียน

=== Treasury: การบันทึกการชำระและการตรึงค่า THBC <sec:treasury-program>
โปรแกรม treasury เป็นปลายทาง CPI ของการบันทึกการชำระจากโปรแกรม trading และเป็นแกนการเงินของระบบ การบันทึกการชำระแบบกลุ่ม (record_settlement_batch) เขียนบัญชี SettlementRecord รายคู่ (zone_id, batch_id) ที่เก็บรากเมอร์เคิล (merkle_root ขนาด 32 ไบต์) มูลค่ารวม และภาษีมูลค่าเพิ่ม (vat_amount, vat_rate_bps) เป็นข้อผูกพันสำหรับตรวจสอบย้อนหลัง โดยรากเมอร์เคิลผูกชุดธุรกรรมในกลุ่มไว้บนเชนขณะที่ใบไม้ (leaf) ของต้นไม้ถูกเก็บนอกเชน คำสั่งฐานนี้กระทบยอดรวมส่วนกลาง (total_settled_thbc) โดยตรง เพื่อรองรับการชำระพร้อมกันจำนวนมากโดยไม่ให้บัญชี treasury กลายเป็นคอขวด จึงมีคำสั่งแบบขนาน (record_settlement_batch_sharded) ที่บันทึก SettlementRecord เช่นเดิมแต่เพิ่มยอดลงบัญชีตัวสะสมรายชาร์ดแทนยอดรวมส่วนกลาง โดยแบ่งออกเป็น 16 ชาร์ด (`settle_shard_for(key) = key[0] % 16`) แล้วกระทบยอดเข้าศูนย์กลางภายหลังด้วย aggregate_settlement_shards ด้านการตรึงค่า stablecoin THBC คำสั่ง swap_grx_for_thbc บังคับว่าอุปทานใหม่ต้องไม่เกินทุนสำรองที่ได้รับการรับรอง (`new_supply <= attested_reserve`) และการรับรองต้องยังไม่หมดอายุ (`now - attestation_ts <= attestation_ttl`) ส่วน redeem_thbc_for_grx จำกัดการไถ่ถอนไม่ให้เกินหลักประกันในคลัง (`grx_out <= swap_vault.amount`) นอกจากนี้การวางเงินค้ำ GRX เพื่อรับรางวัลใช้ตัวสะสมแบบ MasterChef (acc_reward_per_share สเกลด้วย $10^12$) ที่เพิ่มขึ้นตามรางวัลที่เติมเข้า ($"delta" = "amount" times "ACC" slash "total_staked"$) และเมื่อมีการ slash หลักประกันจะถูกกระจายต่อให้ผู้วางเงินค้ำที่เหลือผ่านการเพิ่มตัวสะสมเดียวกัน

=== การประมวลผลแบบขนานด้วย Sealevel และการแบ่งชาร์ด <sec:sealevel-sharding>
รูปแบบการออกแบบบัญชีที่ปรากฏซ้ำในหลายโปรแกรมคือการใช้บัญชี PDA รายเอนทิตี เพื่อให้ธุรกรรมที่ไม่เกี่ยวข้องกันมีชุดบัญชีที่เขียนไม่ทับซ้อนและประมวลผลแบบขนานได้ตามแบบจำลอง Sealevel ของ Solana ตัวอย่างเช่น บัญชี MeterState รายมาตรวัดในโปรแกรม oracle, บัญชี Order และ order nullifier รายคำสั่งในโปรแกรม trading และบัญชี escrow รายผู้ใช้ สำหรับตัวนับรวมที่หากเขียนลงบัญชีเดียวจะกลายเป็นคอขวด (เช่น จำนวนผู้ใช้สะสม หรือยอดชำระสะสม) ระบบใช้การแบ่งชาร์ดจำนวน 16 ชาร์ดแบบกำหนดได้จากไบต์แรกของกุญแจ (`key.to_bytes()[0] % 16`) ทั้งในโปรแกรม registry (ผู้ใช้และมาตรวัด) และ treasury (ยอดชำระ) แล้วจึงกระทบยอดเข้าตัวนับศูนย์กลางภายหลังด้วยคำสั่งระดับผู้ดูแล (aggregate_shards, aggregate_settlement_shards และ aggregate_readings) ที่ป้องกันการนับซ้ำด้วยบิตแมสก์ ผลคือบัญชีส่วนกลาง เช่น GovernanceConfig, OracleData และ Market ถูกออกแบบให้อ่านแบบล่าช้าได้ (stale) บนเส้นทางที่มีความถี่สูง โดยยอมรับว่าค่ารวมจะตามหลังเล็กน้อยเพื่อแลกกับ throughput ที่ขนานได้ การออกแบบนี้สอดคล้องกับเป้าหมาย slot time ใกล้ 400 มิลลิวินาทีที่อ้างถึงใน@sec:consortium-network ส่วนปริมาณงานธุรกรรมจริงบนเชนวัดบน validator เดี่ยวและรายงานใน@sec:onchain-throughput โดยตัวเลขบนเครือข่าย permissioned หลายโหนดที่รวมต้นทุน consensus ยังเป็นงานในอนาคต (ดู@sec:settlement-cost)

== Data Model and Trust Boundary
ข้อมูลหลักของคำสั่งซื้อขายประกอบด้วย order_id, user_id (บทบาท prosumer หรือ consumer), meter_id, side (offer หรือ bid), energy_amount (quantity_kwh), price_per_kwh, status, expires_at, epoch_id และ zone_id โดยปริมาณ energy_amount ต้องไม่เกิน available_surplus_kwh ที่ Aggregator Bridge รับรองสำหรับผู้ขายในช่วงเวลาเดียวกัน ซึ่งเป็นเงื่อนไขที่ตรวจสอบในชั้น off-chain ส่วนการป้องกันการส่งซ้ำใช้บัญชี nullifier บนเชน (order nullifier) แทนการเก็บ nonce ไว้ในตัวคำสั่ง ส่วน settlement record ประกอบด้วย trade_id, คู่ buy_order_id/sell_order_id, energy_amount ที่ clear, price, fee_amount/net_amount, wheeling_charge, loss_factor, erc_certificate_id, blockchain_tx และ settlement timestamp (created_at/confirmed_at) ทั้งนี้สถานะ escrow ถูกเก็บแยกเป็นบัญชี PDA ต่างหาก (SPL token account ภายใต้ seed `escrow`) ไม่ได้อยู่ในตัว settlement record

ความสามารถในการตรวจสอบย้อนหลัง (auditability) ที่ทำให้บล็อกเชนทำหน้าที่เป็นชั้น audit มาจาก Event log ที่โปรแกรมปล่อยในทุกขั้นตอนสำคัญของวงจรการซื้อขาย ได้แก่ การสร้างคำสั่ง (SellOrderCreated, BuyOrderCreated), การจับคู่และการชำระผ่านเหตุการณ์ OrderMatched ที่บันทึกคู่คำสั่ง ผู้ซื้อ-ผู้ขาย ปริมาณ ราคา มูลค่ารวม และค่าธรรมเนียม โดยปล่อยจากทั้ง settle_offchain_match และ batch_settle_offchain_match, การยกเลิกคำสั่ง (OrderCancelled), การฝากหลักประกัน (EscrowDeposited) และการเคลียร์ตลาด (AuctionCleared) ส่วนการบันทึกการชำระแบบกลุ่มในชั้น treasury ปล่อยเหตุการณ์ SettlementBatchRecorded ที่ผูกรากเมอร์เคิลของกลุ่มไว้บนเชน เหตุการณ์เหล่านี้เป็นบันทึกที่ไม่ถูกแก้ไขย้อนหลัง (append-only) ซึ่งผู้ตรวจสอบภายนอกใช้ประกอบประวัติธุรกรรมที่ตรวจทานได้โดยไม่ต้องเชื่อถือชั้น off-chain โดยตรง สอดคล้องกับบทบาท settlement and audit layer ที่กล่าวไว้ใน@sec:settlement-model

ขอบเขตความรับผิดชอบถูกกำหนดให้ชัดเจนดังนี้ Backend และ Aggregator Bridge เป็นผู้ประเมินข้อมูลกำลังผลิตและการใช้ไฟฟ้า เงื่อนไข Grid stability, Islanding safety, ข้อจำกัดของโครงข่าย และเงื่อนไขปริมาณ kWh ที่ไม่เกินค่ารับรอง (available_surplus) จากนั้นจึงปล่อยให้คู่คำสั่งที่ผ่านเงื่อนไขถูกส่งไปยังขั้นตอน settlement บนเชน ส่วน Anchor program ตรวจสอบเฉพาะ account ownership, signer, ลายเซ็น Ed25519 ของทั้งผู้ซื้อและผู้ขายบน order payload, timestamp validity (expires_at), การกันส่งซ้ำผ่านบัญชี order nullifier, เงื่อนไข slippage/zone-capacity, สถานะ escrow และสถานะ order/trade ที่ยังไม่ถูกใช้ซ้ำ กล่าวคือเงื่อนไขด้านปริมาณพลังงานและ oracle attestation ถูกบังคับใช้ในชั้น off-chain ก่อนการ submit ไม่ได้ตรวจซ้ำบนเชน ดังนั้นบล็อกเชนในต้นแบบนี้ทำหน้าที่เป็น settlement and audit layer ไม่ใช่ตัวคำนวณ power-flow หรือ grid-stability engine แบบเต็มรูปแบบ

== Trade Lifecycle Sequence
ลำดับการซื้อขายถูกแบ่งขอบเขตการทำงานระหว่าง off-chain และ on-chain อย่างชัดเจน ดัง@fig:trade-lifecycle ฝั่ง off-chain รับผิดชอบการรวบรวมข้อมูล Smart Meter การยืนยันตัวตน การตรวจสอบเวลาอ้างอิง การประเมินเงื่อนไข Grid stability และการคำนวณคู่คำสั่งที่เสนอให้ clear ส่วนฝั่ง on-chain รับผิดชอบเฉพาะการยืนยัน account state, ลายเซ็น Ed25519 ของผู้ซื้อและผู้ขายบน order payload ที่ลงนามไว้, bounded matched pair, escrow และการบันทึก settlement event

กระบวนการนี้ช่วยให้ธุรกรรมพลังงานมีความโปร่งใสและตรวจสอบย้อนหลังได้ พร้อมลดความเสี่ยงจากการนำข้อมูล Smart Meter ที่ยังไม่ผ่านการยืนยันเข้าสู่บล็อกเชนโดยตรง การแยก boundary ระหว่าง off-chain verification และ on-chain settlement จึงเป็นหลักสำคัญในการรักษาทั้งประสิทธิภาพของระบบและความปลอดภัยของไมโครกริด ข้อจำกัดของแนวทางนี้คือผู้ใช้ต้องเชื่อถือ Aggregator Bridge และ governance ของ oracle_authority หากต้องการลด trust เพิ่มเติมควรเพิ่ม multi-oracle attestation หรือหลักฐาน cryptographic proof ในอนาคต

#figure(
  placement: top,
  scope: "parent",
  text(size: 7pt)[
    // Keep inline math/code at diagram text size (template oversizes math to 10pt).
    #show math.equation: set text(size: 7pt)
    #show raw: set text(size: 6.5pt)
    // Auto-scale the sequence diagram down to the available (parent) width so it
    // never overflows the page, regardless of participant/note widths.
    #layout(size => {
    let __d = chronos.diagram({
      import chronos: *
      _par("Meter", display-name: "Smart Meter")
      _par("Agg", display-name: "Aggregator Bridge")
      _par("Trade", display-name: "Trading Service")
      _par("Anchor", display-name: "Anchor Programs")

      _grp("off-chain: verification · matching", {
        _seq("Meter", "Agg", comment: "signed reading Ed25519 / DLMS (15 min)")
        _seq("Agg", "Agg", comment: [verify sig · surplus · grid stability \[I3\]])
        _seq("Agg", "Trade", comment: "validated reading")
        _seq("Trade", "Trade", comment: [CDA price-time · landed cost $p^*$])
      })

      _seq("Trade", "Anchor", comment: [submit `settle_offchain_match`], color: rgb("#c77d3c"))

      _grp("on-chain: atomic DvP settlement", {
        _note("over", [verify sig · price-cross], pos: "Anchor")
        _note("over", [nullifier · zone-cap], pos: "Anchor")
        _note("over", [atomic DvP transfer], pos: "Anchor")
        _note("over", [fail → revert all], pos: "Anchor", color: rgb("#fbeeee"))
      })

      _seq("Anchor", "Trade", comment: [emit `OrderMatched` · `record_settlement`], dashed: true)
    })
    let __f = calc.min(1.0, size.width / measure(__d).width)
    scale(x: __f * 100%, y: __f * 100%, reflow: true, __d)
    })
  ],
  caption: [Trade lifecycle as a sequence diagram: off-chain participants (Smart Meter → Aggregator Bridge → Trading Service) verify and match, then submit to the on-chain Anchor Programs (via the Chain Bridge) which settle and audit. Notes tag the on-chain checks enforced during settlement (อธิบายใน@sec:settlement-model); any failed CPI reverts the whole atomic DvP settlement.],
) <fig:trade-lifecycle>
