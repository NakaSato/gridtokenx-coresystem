= Grid-Aware Trading and Congestion Management (การซื้อขายที่ตระหนักถึงระบบสายส่งและการจัดการความแออัด)

The physical power grid imposes hard constraints on energy trading that have no analog in purely financial markets. A trade that is economically rational may be physically infeasible if it would cause a transmission line to exceed its thermal limit or a substation transformer to overload. GridTokenX is designed to enforce these physical constraints at the smart contract level, ensuring that every settled trade is not only financially valid but also physically deliverable.
ระบบสายส่งไฟฟ้าทางกายภาพได้กำหนดข้อจำกัดที่เคร่งครัดต่อการซื้อขายพลังงาน ซึ่งไม่มีสิ่งที่เทียบเคียงได้ในตลาดการเงินโดยทั่วไป การซื้อขายที่มีเหตุผลทางเศรษฐศาสตร์อาจจะไม่สามารถทำได้จริงทางกายภาพ หากมันทำให้สายส่งเกินขีดจำกัดทางความร้อน (thermal limit) หรือหม้อแปลงของสถานีไฟฟ้าย่อยทำงานเกินกำลัง GridTokenX ถูกออกแบบมาเพื่อบังคับใช้ข้อจำกัดทางกายภาพเหล่านี้ในระดับสัญญาอัจฉริยะ เพื่อให้แน่ใจว่าทุกการซื้อขายที่ชำระราคานั้น ไม่ใช่แค่ถูกต้องในเชิงการเงินเท่านั้น แต่ต้องสามารถส่งมอบทางกายภาพได้จริง

== Grid Topology Model (แบบจำลองโครงสร้างเครือข่ายระบบสายส่ง)

#figure(
  image("../figures/zone_topology.svg", width: 100%),
  caption: [Grid zone topology showing HV/MV/LV hierarchy and wheeling charge tiers by zone distance. (โครงสร้างเครือข่ายโซนระบบสายส่งที่แสดงลำดับชั้น HV/MV/LV และอัตราค่าสายส่งตามระยะทางระหว่างโซน)],
) <fig-zones>

=== Zone Architecture (สถาปัตยกรรมโซน)

The GridTokenX grid model divides the service territory into a hierarchical set of zones, mirroring the physical structure of the distribution network:
แบบจำลองระบบสายส่งของ GridTokenX จะแบ่งพื้นที่บริการออกเป็นชุดโซนตามลำดับชั้น ซึ่งสะท้อนโครงสร้างทางกายภาพของโครงข่ายการจำหน่ายไฟฟ้า:

*High-Voltage Zones (HVZ)* (โซนไฟฟ้าแรงสูง): Correspond to 115 kV and 230 kV transmission corridors. Managed by the Electricity Generating Authority of Thailand (EGAT).
ตรงกับแนวเขตสายส่งไฟฟ้าขนาด 115 kV และ 230 kV บริหารจัดการโดยการไฟฟ้าฝ่ายผลิตแห่งประเทศไทย (กฟผ.)

*Medium-Voltage Zones (MVZ)* (โซนไฟฟ้าแรงดันปานกลาง): Correspond to 22 kV and 33 kV distribution feeders. Managed by the Metropolitan Electricity Authority (MEA) or Provincial Electricity Authority (PEA).
ตรงกับสายป้อนระบบจำหน่ายไฟฟ้าขนาด 22 kV และ 33 kV บริหารจัดการโดยการไฟฟ้านครหลวง (กฟน.) หรือการไฟฟ้าส่วนภูมิภาค (กฟภ.)

*Low-Voltage Zones (LVZ)* (โซนไฟฟ้าแรงต่ำ): Correspond to 380V/220V distribution transformers serving residential and small commercial customers. This is the primary trading zone for prosumer P2P transactions.
ตรงกับหม้อแปลงระบบจำหน่ายไฟฟ้าขนาด 380V/220V ซึ่งให้บริการลูกค้าที่พักอาศัยและธุรกิจขนาดเล็ก นี่คือโซนหลักในการทำธุรกรรมซื้อขาย P2P สำหรับผู้ผลิตและผู้บริโภค

Each zone is represented as a node in a directed graph stored in the `ZoneTopology` PDA. Edges in the graph represent transmission lines with associated capacity limits (in kW), impedance values (for loss calculation), and current loading levels.
แต่ละโซนจะแสดงเป็นโหนด (node) ในกราฟระบุทิศทางที่เก็บอยู่ใน `ZoneTopology` PDA เส้นเชื่อม (edges) ในกราฟเป็นตัวแทนของสายส่งพร้อมกับข้อมูลที่เกี่ยวข้อง เช่น ขีดจำกัดความจุ (ในหน่วย kW), ค่าอิมพีแดนซ์ (สำหรับการคำนวณการสูญเสีย) และระดับการโหลดในปัจจุบัน

=== Zone Distance Calculation (การคำนวณระยะทางโซน)

The zone distance $d$ between a buyer in zone $B$ and a seller in zone $S$ is the number of edges in the shortest path between $B$ and $S$ in the zone topology graph. This is computed off-chain by the Trading Service using Dijkstra's algorithm and included in the settlement intent submitted to the Chain Bridge.
ระยะทางโซน $d$ ระหว่างผู้ซื้อในโซน $B$ กับผู้ขายในโซน $S$ คือจำนวนเส้นเชื่อมในเส้นทางที่สั้นที่สุดระหว่าง $B$ และ $S$ ในกราฟโครงสร้างโซน โดยคำนวณนอกเชน (off-chain) ผ่านบริการการซื้อขาย (Trading Service) ซึ่งใช้อัลกอริทึมของ Dijkstra และข้อมูลนี้จะรวมอยู่ในเจตจำนงการชำระราคาที่ส่งไปยังเชนบริดจ์

The on-chain Trading Program verifies the zone distance claim by checking that the buyer's and seller's zone IDs are consistent with their registered `UserProfile` PDAs, and that the claimed distance is within the valid range for those zones (pre-computed and stored in the `ZoneTopology` PDA).
โปรแกรมการซื้อขายบนเชน (Trading Program) จะตรวจสอบความถูกต้องของระยะทางโซนที่อ้างอิง โดยตรวจสอบว่ารหัสโซนของผู้ซื้อและผู้ขายสอดคล้องกับข้อมูลที่ลงทะเบียนใน `UserProfile` PDA และระยะทางที่อ้างนั้นอยู่ในช่วงที่อนุญาตสำหรับโซนเหล่านั้น (ซึ่งถูกคำนวณไว้ล่วงหน้าและเก็บอยู่ใน `ZoneTopology` PDA)

== Dynamic Wheeling Charges (ค่าผ่านสายส่งแบบแปรผัน)

=== Charge Structure (โครงสร้างค่าบริการ)

Wheeling charges compensate grid operators for the use of their infrastructure and create price signals that discourage long-distance trades when local alternatives are available. The charge is calculated as:
ค่าผ่านสายส่ง (Wheeling charges) จะเป็นส่วนชดเชยให้แก่ผู้ดำเนินการระบบสายส่งสำหรับการใช้โครงสร้างพื้นฐานของตน และเพื่อเป็นสัญญาณบอกราคาที่ช่วยยับยั้งการซื้อขายระยะไกลในกรณีที่มีทางเลือกในท้องถิ่น ค่าใช้จ่ายคำนวณจาก:

$ C_"wheeling" = C_"base" + C_"distance" times d + C_"congestion" times L_"zone" $

Where (โดยที่):
- $C_"base"$ = base wheeling charge (default: 0.50 THB/kWh), set by the grid operator (ค่าผ่านสายส่งพื้นฐาน (ค่าเริ่มต้น: 0.50 บาท/kWh), กำหนดโดยผู้ดำเนินการระบบสายส่ง)
- $C_"distance"$ = per-zone-distance charge (default: 0.25 THB/kWh per zone) (อัตราค่าบริการต่อระยะทางโซน (ค่าเริ่มต้น: 0.25 บาท/kWh ต่อโซน))
- $d$ = zone distance between buyer and seller (ระยะทางโซนระหว่างผู้ซื้อและผู้ขาย)
- $C_"congestion"$ = congestion multiplier (0 to 2.0), set dynamically by the grid operator (ตัวคูณความแออัด (ตั้งแต่ 0 ถึง 2.0), กำหนดแบบแปรผันโดยผู้ดำเนินการระบบสายส่ง)
- $L_"zone"$ = current loading level of the most congested zone on the path (0 to 1.0) (ระดับการโหลดปัจจุบันของโซนที่แออัดที่สุดบนเส้นทาง (ตั้งแต่ 0 ถึง 1.0))

The congestion component creates a real-time price signal: as a zone approaches its capacity limit, wheeling charges for trades traversing that zone increase, naturally diverting trades to less congested paths.
องค์ประกอบเรื่องความแออัดจะสร้างสัญญาณราคาแบบเรียลไทม์: เมื่อโซนใดๆ มีการใช้งานใกล้ถึงขีดจำกัดความจุ ค่าผ่านสายส่งสำหรับการซื้อขายที่ตัดผ่านโซนนั้นจะสูงขึ้น ซึ่งจะเป็นการเปลี่ยนเส้นทางการซื้อขายไปยังเส้นทางที่แออัดน้อยกว่าโดยธรรมชาติ

=== Dynamic Adjustment by Grid Operators (การปรับเปลี่ยนแบบไดนามิกโดยผู้ดำเนินการระบบสายส่ง)

Grid operators can update wheeling charge parameters through the Governance Program's operational multisig. Updates take effect immediately for new orders but do not affect orders already in the order book (which were priced based on the parameters at submission time). This protects prosumers from unexpected cost increases on open orders.
ผู้ดำเนินการระบบสายส่งสามารถอัปเดตตัวแปรของค่าผ่านสายส่งได้ผ่านโปรแกรมระบบการปกครอง (Governance Program) ที่ใช้ระบบ multisig สำหรับปฏิบัติการ การปรับเปลี่ยนจะมีผลทันทีกับคำสั่งใหม่ๆ แต่ไม่กระทบต่อคำสั่งที่อยู่ในสมุดคำสั่งอยู่แล้ว (ซึ่งถูกกำหนดราคาโดยพิจารณาจากตัวแปร ณ เวลาที่ส่ง) วิธีนี้เป็นการคุ้มครองผู้ผลิตและผู้บริโภคไม่ให้พบกับการเพิ่มขึ้นของค่าใช้จ่ายที่ไม่คาดคิดสำหรับคำสั่งที่ยังเปิดอยู่

== Virtual Power Plants (VPP) (โรงไฟฟ้าเสมือน)

=== VPP Cluster Architecture (สถาปัตยกรรมคลัสเตอร์ VPP)

Virtual Power Plants aggregate distributed energy resources into logical clusters that can be managed as a single dispatchable unit. GridTokenX's VPP model enables:
โรงไฟฟ้าเสมือน (VPP) เป็นการรวมทรัพยากรพลังงานแบบกระจายศูนย์เข้าด้วยกันเป็นคลัสเตอร์ตรรกะ ซึ่งสามารถบริหารจัดการได้เสมือนเป็นหน่วยสั่งจ่ายไฟฟ้า (dispatchable unit) เพียงหน่วยเดียว แบบจำลอง VPP ของ GridTokenX ช่วยสนับสนุน:

*Flexibility Aggregation* (การรวบรวมความยืดหยุ่น): Multiple prosumers' batteries and controllable loads are aggregated into a VPP cluster, providing a larger, more predictable flexibility resource for grid balancing.
แบตเตอรี่และโหลดที่ควบคุมได้ของกลุ่มผู้ผลิตและผู้บริโภค จะถูกรวมเข้าไปในคลัสเตอร์ VPP ช่วยสร้างทรัพยากรที่มีความยืดหยุ่นขนาดใหญ่และสามารถคาดเดาได้มากขึ้นเพื่อช่วยปรับสมดุลสายส่งไฟฟ้า

*Capacity Reservation* (การสำรองความจุ): Grid operators can reserve a portion of a VPP cluster's capacity for frequency regulation or emergency response, with prosumers compensated via GRX token rewards.
ผู้ดำเนินการระบบสายส่งสามารถสำรองความจุของ VPP คลัสเตอร์ในบางส่วนไว้สำหรับการควบคุมความถี่หรือการตอบสนองเหตุฉุกเฉินได้ โดยผู้ผลิตและผู้บริโภคจะได้รับผลตอบแทนเป็นโทเคน GRX

*Coordinated Dispatch* (การประสานงานการสั่งจ่าย): The platform can issue dispatch signals to VPP clusters via the Edge Gateway's OCPP interface (for EV chargers) or Modbus TCP interface (for BESS), enabling automated demand response.
แพลตฟอร์มสามารถส่งสัญญาณคำสั่งจ่ายไฟฟ้า (dispatch signals) ไปยังกลุ่ม VPP ผ่านอินเทอร์เฟซ OCPP ของเอดจ์เกตเวย์ (สำหรับเครื่องชาร์จรถยนต์ไฟฟ้า) หรืออินเทอร์เฟซ Modbus TCP (สำหรับระบบกักเก็บพลังงานแบตเตอรี่ BESS) ช่วยให้สามารถตอบสนองต่อความต้องการไฟฟ้าได้โดยอัตโนมัติ

=== VPP State Management (การจัดการสถานะ VPP)

Each VPP cluster is represented by a `VppCluster` PDA:
คลัสเตอร์ VPP แต่ละกลุ่มจะแสดงสถานะด้วย `VppCluster` PDA:

```rust
#[account(zero_copy)]
#[repr(C)]
pub struct VppCluster {
    pub cluster_id: Pubkey,
    pub zone_id: Pubkey,
    pub total_capacity_kw: u32,
    pub available_capacity_kw: u32,
    pub reserved_capacity_kw: u32,
    pub flex_up_kw: u32,      // available upward flexibility (ความยืดหยุ่นในการเพิ่มกำลังการผลิตที่พร้อมใช้งาน)
    pub flex_down_kw: u32,    // available downward flexibility (ความยืดหยุ่นในการลดกำลังการผลิตที่พร้อมใช้งาน)
    pub state_of_charge_pct: u8,
    pub congestion_alarm: bool,
    pub last_update_ts: i64,
    pub _padding: [u8; 6],
}
```

The `available_capacity_kw` field is updated in real-time as trades are matched and as device telemetry is received. The Trading Program checks this field before accepting any order that would route through the cluster's zone.
ฟิลด์ `available_capacity_kw` จะถูกอัปเดตแบบเรียลไทม์เมื่อมีการจับคู่การซื้อขาย และเมื่อได้รับข้อมูลโทรมาตรของอุปกรณ์ โปรแกรมการซื้อขายจะตรวจสอบฟิลด์นี้ก่อนตอบรับคำสั่งที่อาจจะต้องผ่านโซนของคลัสเตอร์นั้น

=== Capacity Enforcement (การบังคับใช้ขีดจำกัดความจุ)

When the Trading Program processes a `match_orders` instruction, it performs the following capacity checks:
เมื่อโปรแกรมการซื้อขายประมวลผลคำสั่ง `match_orders` จะทำการตรวจสอบความจุดังต่อไปนี้:

1. *Seller Zone Capacity* (ความจุโซนผู้ขาย): Verifies that the seller's zone VPP cluster has sufficient generation capacity to cover the trade quantity.
   ตรวจสอบว่ากลุ่ม VPP ในโซนของผู้ขายมีความสามารถในการผลิตพลังงานเพียงพอครอบคลุมปริมาณการซื้อขายได้หรือไม่
2. *Buyer Zone Capacity* (ความจุโซนผู้ซื้อ): Verifies that the buyer's zone VPP cluster has sufficient consumption capacity.
   ตรวจสอบว่ากลุ่ม VPP ในโซนของผู้ซื้อมีความสามารถในการบริโภคพลังงานเพียงพอหรือไม่
3. *Transit Zone Capacity* (ความจุโซนทางผ่าน): For inter-zone trades, verifies that all intermediate zones on the routing path have sufficient transmission capacity.
   สำหรับการซื้อขายข้ามโซน จะตรวจสอบโซนกลางทางทั้งหมดบนเส้นทาง ว่ามีความสามารถในการส่งสัญญาณเพียงพอหรือไม่

If any check fails, the instruction returns a `CapacityExceeded` error and the transaction is rejected. The Trading Service receives this error via the Chain Bridge's confirmation event and re-queues the affected orders for re-matching with alternative counterparties.
หากมีขั้นตอนใดไม่ผ่านการตรวจสอบ คำสั่งจะส่งคืนค่าความผิดพลาดเป็น `CapacityExceeded` และธุรกรรมจะถูกปฏิเสธ บริการการซื้อขายจะได้รับความผิดพลาดนี้ผ่านเหตุการณ์ยืนยันของเชนบริดจ์ และจะทำการเรียงคิวคำสั่งที่มีผลกระทบเพื่อทำการจับคู่ใหม่กับคู่สัญญาอื่นแทน

== Grid Loss Factor (GLF) (ปัจจัยการสูญเสียในระบบสายส่ง)

=== Physical Basis (พื้นฐานทางกายภาพ)

When electrical current flows through a conductor, a portion of the energy is dissipated as heat due to the conductor's resistance (Joule heating). This "transmission loss" means that the energy received by the buyer is always less than the energy dispatched by the seller. The Grid Loss Factor quantifies this difference.
เมื่อกระแสไฟฟ้าไหลผ่านตัวนำ พลังงานบางส่วนจะกระจายตัวออกมาเป็นความร้อนเนื่องจากความต้านทานของตัวนำ (ความร้อนจูล) การ "สูญเสียในระบบสายส่ง" นี้หมายความว่าพลังงานที่ผู้ซื้อได้รับจะน้อยกว่าพลังงานที่ผู้ขายส่งออกเสมอ ปัจจัยการสูญเสียในระบบสายส่ง (Grid Loss Factor) จะคำนวณปริมาณของส่วนต่างนี้

For a simple resistive line, the loss fraction is approximately:
สำหรับสายไฟฟ้าความต้านทานทั่วไป อัตราส่วนการสูญเสียจะประมาณค่าได้ดังนี้:

$ "Loss Fraction" = frac(I^2 R, P_"delivered") approx frac(P_"delivered" dot R, V^2) $

In practice, GridTokenX uses a simplified zone-distance model calibrated against PEA's published transmission loss data:
ในทางปฏิบัติ GridTokenX ใช้โมเดลระยะทางโซนแบบง่าย ที่ผ่านการปรับค่าเทียบกับข้อมูลการสูญเสียในการส่งกำลังของ กฟภ. ที่เผยแพร่:

$ "GLF"(d) = 1 - e^{-0.02 d} $

This gives approximate loss fractions of:
ซึ่งให้อัตราส่วนการสูญเสียโดยประมาณดังนี้:
- $d = 0$ (intra-zone) (ภายในโซนเดียวกัน): 0% loss (สูญเสีย 0%)
- $d = 1$ (adjacent zone) (โซนติดกัน): ~2% loss (สูญเสียประมาณ 2%)
- $d = 3$ (3 zones) (3 โซน): ~5.8% loss (สูญเสียประมาณ 5.8%)
- $d = 5$ (5 zones) (5 โซน): ~9.5% loss (สูญเสียประมาณ 9.5%)

=== GLF Application in Settlement (การใช้ GLF ในการชำระราคา)

During atomic settlement, the GLF is applied as follows:
ระหว่างการชำระราคาแบบอะตอมมิก (atomic settlement) จะมีการนำ GLF ไปประยุกต์ใช้ดังนี้:

1. The seller dispatches `Q` kWh (represented by `Q` GRID tokens transferred to the buyer).
   ผู้ขายจัดส่งพลังงาน `Q` kWh (แทนด้วยโทเคน GRID จำนวน `Q` ที่โอนไปยังผู้ซื้อ)
2. The buyer receives `Q × (1 - GLF)` kWh of actual energy (their meter records this consumption).
   ผู้ซื้อได้รับพลังงานจริง `Q × (1 - GLF)` kWh (มิเตอร์ของผู้ซื้อบันทึกค่าการบริโภคนี้)
3. The "loss quantity" `Q × GLF` GRID tokens are transferred to the grid operator's account as compensation for physical losses.
   ปริมาณที่สูญเสียคือโทเคน GRID จำนวน `Q × GLF` จะถูกโอนไปยังบัญชีของผู้ดำเนินการระบบสายส่ง เพื่อชดเชยการสูญเสียทางกายภาพ
4. The buyer pays for `Q` kWh at the agreed price (they pay for the energy dispatched, not received, as is standard in wholesale energy markets).
   ผู้ซื้อชำระเงินสำหรับปริมาณ `Q` kWh ตามราคาที่ตกลงกันไว้ (ผู้ซื้อจ่ายตามปริมาณพลังงานที่ส่งออก ไม่ใช่พลังงานที่ได้รับ ซึ่งเป็นมาตรฐานในตลาดซื้อขายพลังงานขายส่ง)

This accounting ensures that the total GRID token supply remains consistent with the total verified energy in the system.
ระบบบัญชีนี้รับประกันได้ว่า ปริมาณรวมของโทเคน GRID จะยังคงสอดคล้องกับพลังงานรวมที่ผ่านการตรวจสอบแล้วในระบบอย่างแน่นอน

== Frequency Regulation and Demand Response (การควบคุมความถี่และการตอบสนองด้านอุปสงค์)

=== Automatic Generation Control (AGC) Integration (การบูรณาการเข้ากับระบบควบคุมการผลิตอัตโนมัติ (AGC))

GridTokenX provides an API for grid operators to issue Automatic Generation Control (AGC) signals to VPP clusters. When the grid frequency deviates from 50 Hz (the Thai standard), the operator can:
GridTokenX นำเสนอ API สำหรับให้ผู้ดำเนินการระบบสายส่งสามารถส่งสัญญาณควบคุมการผลิตอัตโนมัติ (AGC) ไปยังคลัสเตอร์ VPP เมื่อความถี่ของระบบสายส่งเบี่ยงเบนไปจาก 50 Hz (มาตรฐานของประเทศไทย) ผู้ปฏิบัติการสามารถ:

*Frequency Low (< 49.8 Hz)* (ความถี่ต่ำ (< 49.8 Hz)): Issue a flex-up signal to VPP clusters, instructing BESS units to discharge and EV chargers to reduce charging rate. Prosumers responding to AGC signals receive GRX token rewards proportional to their response magnitude and speed.
ส่งสัญญาณเพิ่มกำลัง (flex-up) ไปยังกลุ่ม VPP เพื่อสั่งให้หน่วยเก็บพลังงานแบบแบตเตอรี่ (BESS) คายประจุ และให้สถานีชาร์จรถยนต์ไฟฟ้าลดอัตราการชาร์จลง ผู้ผลิตและผู้บริโภคที่ตอบสนองต่อสัญญาณ AGC จะได้รับรางวัลเป็นโทเคน GRX ตามสัดส่วนของขนาดความเร็วและการตอบสนอง

*Frequency High (> 50.2 Hz)* (ความถี่สูง (> 50.2 Hz)): Issue a flex-down signal, instructing BESS units to charge and EV chargers to increase charging rate (if below maximum).
ส่งสัญญาณลดกำลัง (flex-down) เพื่อสั่งให้หน่วยเก็บพลังงานแบบแบตเตอรี่ทำการชาร์จ และสถานีชาร์จรถยนต์ไฟฟ้าทำการเพิ่มอัตราการชาร์จ (ถ้ายังต่ำกว่าระดับสูงสุด)

=== Demand Response Programs (โปรแกรมตอบสนองด้านอุปสงค์)

Grid operators can create demand response programs through the Governance Program, offering GRX rewards to prosumers who voluntarily curtail consumption during peak demand periods. Participation is opt-in and managed through the GridTokenX mobile application.
ผู้ดำเนินการระบบสายส่งสามารถสร้างโปรแกรมตอบสนองด้านอุปสงค์ผ่านโปรแกรมระบบการปกครอง เพื่อเสนอรางวัล GRX แก่ผู้ผลิตและผู้บริโภคที่สมัครใจลดการบริโภคในช่วงความต้องการไฟฟ้าสูง (peak demand) การเข้าร่วมจะเป็นรูปแบบสมัครใจตามความสะดวกและจะถูกบริหารจัดการผ่านแอปพลิเคชันมือถือของ GridTokenX

== Performance Under Congestion (ประสิทธิภาพภายใต้สภาวะความแออัด)

Simulation studies using historical PEA load data from 2023–2025 demonstrate that the GridTokenX congestion management system:
การศึกษาด้วยแบบจำลองโดยใช้ข้อมูลการใช้ไฟฟ้าของ กฟภ. (PEA) ในอดีตจากปี 2023–2025 แสดงให้เห็นว่าระบบจัดการความแออัดของ GridTokenX สามารถ:
- Reduces peak zone loading by an average of 18% compared to unmanaged P2P trading.
  ลดภาระผูกพันการใช้ไฟฟ้าสูงสุดของโซนลงเฉลี่ย 18% เมื่อเทียบกับการซื้อขายแบบ P2P ที่ไม่มีการจัดการ
- Increases the proportion of intra-zone trades from 45% to 72% through price signals.
  เพิ่มสัดส่วนการซื้อขายภายในโซนเดียวกันจาก 45% เป็น 72% โดยผ่านกลไกสัญญาณราคา
- Reduces average wheeling charge costs for prosumers by 23% through more efficient trade routing.
  ลดค่าใช้จ่ายบริการสายส่งเฉลี่ยให้ผู้ผลิตและบริโภคลง 23% ผ่านการกำหนดเส้นทางการค้าที่มีประสิทธิภาพยิ่งขึ้น
- Maintains grid frequency within ±0.1 Hz of nominal during simulated demand response events.
  รักษาความถี่ของระบบสายส่งไฟฟ้าให้อยู่ในช่วง ±0.1 Hz ของค่าปกติ ในช่วงระหว่างการจำลองสถานการณ์โปรแกรมตอบสนองด้านอุปสงค์
