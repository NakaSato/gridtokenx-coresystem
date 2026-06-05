= ระเบียบวิธีประเมินผลและการทำซ้ำได้

ส่วนนี้กำหนดวิธีประเมิน GridTokenX และแยกผลการวัดจริงออกจากการประมาณเชิงวิเคราะห์ ต้นฉบับฉบับนี้ไม่ควรถูกอ่านว่าเป็นการยืนยัน performance ของ production deployment เว้นแต่จะมี benchmark output, deployment configuration, และ dataset ที่เผยแพร่พร้อมบทความ โค้ดโอเพนซอร์สเป็น reference artifact สำหรับทำซ้ำการประเมินผล @gridtokenx

== คำถามการประเมินผล

การประเมินผลจัดตามคำถามวิจัยสี่ข้อ:

1. *Matching throughput*: off-chain CDA matching engine สามารถประมวลผล bid-ask pair ได้มากพอที่จะป้อน settlement layer โดยไม่กลายเป็น bottleneck หรือไม่?

2. *On-chain feasibility*: instruction สำหรับ settlement, oracle, registry, และ token ยังอยู่ภายในขีดจำกัด compute-unit และ account-size ของ Solana ภายใต้ batch size ที่สมจริงหรือไม่?

3. *Grid feasibility*: นโยบาย grid-aware matching ลด trade ที่เป็นไปไม่ได้ทางกายภาพเมื่อเทียบกับ unmanaged P2P market ภายใต้ load และ DER assumptions เดียวกันหรือไม่?

4. *Operational resilience*: telemetry ingestion, replay protection, และ settlement retry logic สามารถทนต่อ device outage, duplicate submission, และ network partition โดยไม่เกิด double-minting หรือ double-settlement หรือไม่?

== Artifact สำหรับ Benchmark

repository มีจุดเริ่มต้นสำหรับการประเมินดังนี้:

#table(
  columns: (1fr, 1.2fr, 1fr),
  inset: 8pt,
  align: (left, left, left),
  [*Artifact*], [*Command หรือ Location*], [*Primary Metric*],
  [Trading engine microbenchmark], [`just benchmark`], [CDA match-cycle latency และ throughput],
  [Criterion benchmark source], [`gridtokenx-trading-service/crates/trading-engine/benches/matching_benchmark.rs`], [ต้นทุนของ 1000x1000 order matching],
  [AC power-flow simulation], [`gridtokenx-smartmeter-simulator/backend/scripts/simulate_pandapower.py`], [voltage range, line loading, convergence],
  [Large telemetry load test], [`gridtokenx-smartmeter-simulator/backend/scripts/load_test_100k.py`], [effective meter-frame throughput],
)

การจำลองกริดใช้ pandapower @pandapower2018 เพื่อทำ AC power-flow analysis บน reference feeder model repository ปัจจุบันมี reference grid แบบ rural low-voltage ขนาด 80 bus ใน smart-meter simulator data directory แต่การศึกษาสำหรับ production ควรแทนที่แบบจำลองนี้ด้วย feeder topology ที่ได้รับอนุมัติจาก utility และ measured load/generation profiles

== Benchmark ของ Matching Engine

benchmark ของ trading engine สร้าง buy order 1,000 รายการและ sell order 1,000 รายการที่ราคาตัดกัน ใช้ topology snapshot ที่ยอมรับ flow ทั้งหมด และวัด full matching cycle หนึ่งรอบ การทดสอบนี้แยก matching engine ออกจาก latency ของ database, network, และ blockchain ผลที่เหมาะสำหรับตีพิมพ์ควรรายงาน:

- CPU model, จำนวน core, memory, operating system, Rust version, และ compiler flags,
- จำนวน buy order, sell order, zone, และ matched pair,
- mean, median, p95, และ p99 match-cycle latency,
- allocation count และ memory footprint ถ้ามี,
- throughput ในหน่วย matched pairs per second

benchmark นี้จำเป็นแต่ยังไม่เพียงพอ เพราะแสดงว่า off-chain matcher สามารถสร้าง fill ได้ แต่ไม่ได้พิสูจน์ end-to-end settlement capacity

=== ผล Benchmark เบื้องต้นในเครื่อง Local

เพื่อเป็นการตรวจสอบ reproducibility เบื้องต้น ได้รัน Criterion benchmark ด้วยคำสั่ง `just benchmark` บน macOS 26.5.1, Apple M2 CPU, 8 logical cores, RAM 16 GB, Rust `1.95.0`, และ Cargo `1.95.0` benchmark นี้วัดกรณี synthetic `matching cycle 1000x1000` ตามที่อธิบายข้างต้น

#table(
  columns: (1fr, auto, auto),
  inset: 8pt,
  align: (left, center, left),
  [*Metric*], [*Estimate*], [*95% confidence interval*],
  [Mean match-cycle time], [22.231 ms], [21.847--22.653 ms],
  [Median match-cycle time], [21.472 ms], [21.294--21.751 ms],
  [Standard deviation], [2.080 ms], [1.469--2.580 ms],
)

Criterion รายงาน outlier 7 รายการจาก 100 measurements และรายงาน performance regression เมื่อเทียบกับ baseline เดิมที่บันทึกไว้ในเครื่อง ผลนี้ควรถูกตีความเฉพาะเป็น single-machine microbenchmark ของ in-memory matching engine เท่านั้น ไม่รวม database access, network transport, Solana transaction construction, signature verification, RPC submission, confirmation latency, หรือ on-chain account contention

== On-Chain Settlement Capacity

Trading Program รองรับการ batch matched order pair ได้สูงสุด 4 คู่ต่อ settlement transaction เป้าหมาย 50,000 settled trades per hour เท่ากับประมาณ 13.9 matched trades per second หรือประมาณ 3.5 settlement transactions per second ที่ batch size นี้ ตัวเลขนี้เป็นเป้าหมายเชิงวิเคราะห์ ไม่ใช่ผลการวัด production

เพื่อสนับสนุน claim ที่แข็งแรงขึ้น บทความควรมีการทดลองบน Solana localnet หรือ devnet พร้อมข้อมูลต่อไปนี้:

- deployed program IDs และ commit hash,
- Solana และ Anchor version ที่แน่นอน,
- transaction batch size,
- compute units ที่ใช้โดย `place_order`, `match_orders`, `submit_reading`, และ `finalize_interval`,
- confirmation latency distribution,
- failed transaction rate และ retry count,
- account contention profile แยกตาม market shard

ผลลัพธ์ควรถูกรายงานในตารางที่แยก local validator measurement ออกจาก public cluster measurement เพราะ consensus, RPC, และ priority-fee behavior แตกต่างกันอย่างมีนัยสำคัญระหว่าง environment

== Protocol สำหรับ Grid-Aware Simulation

grid-aware trading ควรถูกประเมินเทียบกับ baseline อย่างน้อยสามแบบ:

1. *Unmanaged P2P*: order ถูกจับคู่ด้วย price-time priority โดยไม่มี grid capacity checks

2. *Static tariff P2P*: order รวม fixed wheeling charges แต่ไม่มี dynamic congestion component

3. *GridTokenX policy*: order รวม zone distance, dynamic wheeling charges, Grid Loss Factor, และ VPP capacity limits

สำหรับแต่ละ scenario simulator ควรใช้ feeder topology, load profile, PV profile, battery availability, และ order-arrival process เดียวกัน metric หลักคือ peak line loading, voltage violations, curtailed energy, matched trade volume, average buyer price, average seller revenue, และ average wheeling charge claim เช่น "ลด peak zone loading ได้ 18%" ควรระบุ dataset, จำนวนวันจำลอง, random seeds, baseline definition, และ confidence interval

== ข้อกำหนดด้าน Reproducibility

สำหรับการส่งบทความเชิงวิชาการ ควรแนบข้อมูลต่อไปนี้:

- repository URL และ commit hash,
- command ที่ใช้ build smart contracts และ services,
- benchmark logs หรือ CSV outputs,
- simulation input datasets,
- hardware และ cloud configuration,
- random seeds สำหรับ load และ order generation,
- license และ availability status ของ utility data ที่ไม่เปิดเผยสาธารณะ

หากไม่มี artifact เหล่านี้ ผลลัพธ์ในบทความควรถูกนำเสนอเป็น design goals, analytical estimates, หรือ proposed evaluation methodology แทนที่จะเป็น empirical claims
