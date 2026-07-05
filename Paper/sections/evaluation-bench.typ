#import "@preview/lilaq:0.6.0" as lq
#import "@preview/zero:0.6.1": format-table, set-group
#import "../metrics.typ": metrics

// Okabe-Ito colorblind-safe palette — shared across every data plot in this section
// for a consistent, publication-clean look (no harsh primary blue/red).
#let c-blue = rgb("#0072B2")       // primary series (throughput, measured, CU)
#let c-orange = rgb("#E69F00")     // secondary series (loss)
#let c-vermillion = rgb("#D55E00") // emphasis / budget threshold
#let c-gray = rgb("#999999")       // reference / ideal lines

== Ingest Scaling and Loss Under Load <sec:ingest-saturation>
เพื่อประเมินขอบเขตความสามารถของเส้นทางรับข้อมูลให้กว้างกว่าอัตราเชิงออกแบบ 5.33 รายการต่อวินาทีตาม@sec:ingest-throughput ผู้วิจัยเพิ่มภาระงานแบบขั้นบันได (load ramp) ด้วยจำนวนมาตรวัด 40, 80, 160, 320 และ 640 เครื่อง โดยแต่ละขั้นรันเป็นเวลา 60 วินาที และทำซ้ำ 5 รอบเพื่อรายงานค่าเฉลี่ยและส่วนเบี่ยงเบนมาตรฐาน ในแต่ละรอบ simulator ส่งค่าอ่านที่ลงนาม Ed25519 แบบต่อเนื่องสูงสุด (ไม่มีการหน่วงระหว่างรอบส่ง) ตัวชี้วัดหลักวัดที่ขอบเขต HTTP คือสัดส่วนคำขอที่ Aggregator Bridge รับ ตรวจลายเซ็น และกระจายเข้าสู่ Redis Stream สำเร็จ (HTTP 200) โดยนิยาม throughput = จำนวนรายการที่สำเร็จ ÷ เวลาที่ใช้ และ loss = จำนวนคำขอที่ล้มเหลว ÷ คำขอทั้งหมด ผลสรุปไว้ใน@tbl:ingest-ramp และแสดงแนวโน้มเป็นกราฟใน@fig:ingest-ramp การทดลองรันบนเครื่อง Apple M2 (8 cores, หน่วยความจำ 16 GiB)

#figure(
  caption: [Ingest throughput and loss vs. meter-fleet size (mean ± sd over 5 runs, 60 s each).],
  text(size: 7pt)[
    // zero: decimal-align the throughput (mantissa ± uncertainty) and loss (exponent) columns.
    #show math.equation: set text(size: 7pt) // zero emits math; keep it at cell size
    #show table: format-table(auto, auto, auto)
    #table(
      columns: (auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (center + horizon, center + horizon, center + horizon),
      table.header([*มาตรวัด (เครื่อง)*], [*throughput (readings/s)*], [*loss (สูงสุด)*]),
      [40],  [134.4+-9.2],   [0],
      [80],  [72.8+-6.9],    [2.6e-4],
      [160], [88.4+-15.0],   [2.2e-4],
      [320], [115.0+-19.8],  [0],
      [640], [148.9+-25.6],  [1.0e-4],
    )
  ],
) <tbl:ingest-ramp>

#figure(
  text(size: 8pt)[
    #lq.diagram(
      width: 7cm, height: 4.4cm,
      xscale: "log",
      xaxis: (ticks: ((40, [40]), (80, [80]), (160, [160]), (320, [320]), (640, [640]))),
      xlabel: [จำนวนมาตรวัด (เครื่อง)],
      ylabel: [throughput (readings/s)],
      ylim: (0, 180),
      legend: (position: top + left),
      // primary axis: throughput (left)
      // mean ± sd shown as a filled band (cleaner than error bars at this density)
      lq.fill-between(
        (40, 80, 160, 320, 640),
        (125.2, 65.9, 73.4, 95.2, 123.3),   // mean − sd
        y2: (143.6, 79.7, 103.4, 134.8, 174.5), // mean + sd
        fill: c-blue.transparentize(82%), stroke: none, z-index: 0,
      ),
      lq.plot(
        (40, 80, 160, 320, 640),
        (134.4, 72.8, 88.4, 115.0, 148.9),
        mark: "o", color: c-blue, label: [throughput],
      ),
      // secondary axis: request loss in percent (right)
      lq.axis(
        kind: "y", position: right, lim: (0, 0.04),
        label: [loss (%)],
        lq.plot(
          (40, 80, 160, 320, 640),
          (0, 0.026, 0.022, 0, 0.010),
          mark: "s", color: c-orange, label: [loss],
        ),
      ),
    )
  ],
  caption: [Ingest throughput (left axis, mean ± sd) and request loss (right axis) vs. meter-fleet size; loss stays ≤ 0.03% across the tested range. Throughput is non-monotonic and single-client sender-bound — a lower bound, not a service-saturation curve.],
) <fig:ingest-ramp>

ผลการวัดมีสองข้อสังเกตหลัก ข้อแรกคือสัดส่วนการสูญหายของข้อมูลอยู่ในระดับใกล้ศูนย์ตลอดทุกขนาดฟลีต โดยค่าสูงสุดที่วัดได้คือประมาณ 2.6 × 10#super[−4] (คิดเป็นประมาณ 0.03%) ที่ขนาด 80 เครื่อง และหลายรอบไม่มีการสูญหายเลย ผลนี้บ่งชี้ว่าเส้นทางรับข้อมูลรักษาสัดส่วนการสูญหายให้ใกล้ศูนย์ (≤ 0.03%) ได้จนถึงภาระงาน 640 เครื่อง ข้อที่สองคืออัตราการรับข้อมูลที่วัดได้ไม่ได้เพิ่มขึ้นแบบเอกฐานตามจำนวนมาตรวัด แต่แกว่งอยู่ในช่วงประมาณ 73–149 รายการต่อวินาที (ค่าเฉลี่ย) โดยมีส่วนเบี่ยงเบนมาตรฐานค่อนข้างสูง (สูงสุดประมาณ 26 รายการต่อวินาทีที่ 640 เครื่อง) เนื่องจากการทดลองนี้สร้างภาระงานจากไคลเอนต์ผู้ส่งเพียงตัวเดียวที่ทำงานแบบ asynchronous และส่งค่าอ่านรายมาตรวัดต่อรอบตามลำดับ ความแกว่งและความไม่เป็นเอกฐานนี้จึงน่าจะสะท้อนข้อจำกัดฝั่งผู้ส่ง (เช่น ต้นทุนการสร้างและลงนามค่าอ่าน และการประมวลผลแบบ single-client) ร่วมกับจังหวะการกระจายแบบ asynchronous เข้าสู่ Redis มากกว่าการอิ่มตัวของบริการรับข้อมูล ทั้งนี้ผู้วิจัยไม่สรุปสาเหตุที่แน่ชัดของรูปแบบนี้จากข้อมูลที่มี

จากผลที่ได้ อัตราเฉลี่ยสูงสุดที่วัดได้ (ค่าเฉลี่ย 5 รอบที่ฟลีต 640 เครื่อง) อยู่ที่ประมาณ 149 รายการต่อวินาที ซึ่งสูงกว่าอัตราเชิงออกแบบ 5.33 รายการต่อวินาทีหลายเท่าตัว และเกิดขึ้นที่ขนาดฟลีตใหญ่ที่สุดที่ทดสอบ (640 เครื่อง) อย่างไรก็ตาม อัตราที่วัดได้ไม่เพิ่มขึ้นแบบเอกฐานตามจำนวนมาตรวัด (ค่าเฉลี่ยที่ 80 เครื่องต่ำกว่าที่ 40 เครื่อง) ผู้วิจัยจึงไม่สรุปว่าเส้นทางรับข้อมูลถึงหรือไม่ถึงจุดอิ่มตัวจากข้อมูลชุดนี้ อย่างไรก็ตาม เนื่องจากภาระงานถูกสร้างจากไคลเอนต์ผู้ส่งเพียงตัวเดียวแบบส่งต่อเนื่องรายมาตรวัดต่อรอบ (sequential per tick) ตัวเลขนี้จึงเป็น lower bound ที่สะท้อนว่า Aggregator Bridge รองรับไคลเอนต์ที่ส่งเต็มอัตราหนึ่งตัวได้โดยมีการสูญหายใกล้ศูนย์ มากกว่าจะเป็นเพดานความสามารถที่แท้จริงของเส้นทางรับข้อมูล การวัดเพดานที่แท้จริงต้องใช้ผู้ส่งแบบขนานหลายตัวและแยกต้นทุนฝั่งผู้ส่ง (เช่น การ onboard และการลงนาม) ออกจากต้นทุนของบริการรับข้อมูล ซึ่งยังเป็นงานในอนาคต อนึ่ง อัตราในการทดลอง ramp นี้ (73–149 รายการต่อวินาที) สูงกว่าอัตราเวลานาฬิกาจริงประมาณ 16 รายการต่อวินาทีของการรันต่อเนื่องหนึ่งรอบใน@sec:ingest-throughput เนื่องจากการทดลอง ramp ส่งแบบไม่หน่วงระหว่างรอบ (max-rate) เพื่อหาขอบเขตการขยายตัว ขณะที่การรันต่อเนื่องผูกจังหวะการส่งกับช่วงเวลา 15 วินาทีของเวลาจำลอง

== Off-chain Matching Throughput <sec:matching-throughput>
นอกเหนือจากเส้นทางรับข้อมูล ผู้วิจัยวัดต้นทุนการจับคู่คำสั่งของเครื่องจับคู่ Continuous Double Auction (CDA) ในชั้น off-chain ด้วย micro-benchmark (Criterion) ที่เรียกฟังก์ชันจับคู่หนึ่งรอบ (match cycle) เหนือสมุดคำสั่งซื้อ 1,000 รายการและคำสั่งขาย 1,000 รายการ (รวม 2,000 คำสั่ง) โดยกำหนดให้ราคาคำสั่งซื้อสูงกว่าคำสั่งขายทุกคู่ จึงจับคู่ได้เต็มเป็นคู่คำสั่งสูงสุดประมาณ 1,000 คู่ต่อรอบ การทดลองรันบนเครื่องเดียวกัน (Apple M2, 8 cores, หน่วยความจำ 16 GiB) เก็บ 100 ตัวอย่างหลังช่วง warm-up ผลสรุปใน@tbl:matching-tput

#figure(
  caption: [In-memory CDA matching throughput (one match cycle over 1,000 bids × 1,000 asks, 100 samples).],
  text(size: 7pt)[
    #table(
      columns: (auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon),
      table.header([*ตัวชี้วัด*], [*ค่า*]),
      [เวลาต่อรอบจับคู่ 1,000 × 1,000 (median)], [32.56 ms],
      [ช่วงความเชื่อมั่น 95%], [32.28–32.75 ms],
      [อัตราประมวลผลคำสั่ง (≈)], [6.1 × 10#super[4] orders/s],
      [อัตราจับคู่คู่คำสั่ง (≈)], [3.1 × 10#super[4] pairs/s],
    )
  ],
) <tbl:matching-tput>

เครื่องจับคู่ประมวลผลคำสั่งทั้งสองฝั่งหนึ่งรอบเต็มในเวลามัธยฐาน (median) 32.56 มิลลิวินาที (ช่วงความเชื่อมั่น 95% ประมาณ 32.28–32.75 มิลลิวินาที) คิดเป็นอัตราการประมวลผลประมาณ 6.1 × 10#super[4] คำสั่งต่อวินาที หรือประมาณ 3.1 × 10#super[4] คู่คำสั่งจับคู่ต่อวินาทีบนเธรดเดียว ค่านี้วัดเฉพาะการจับคู่ในหน่วยความจำ (in-memory matching) ไม่รวมต้นทุนการชำระธุรกรรมบนเชน การคงสภาพข้อมูล (persistence) หรือการสื่อสารผ่านเครือข่าย จึงเป็นขอบเขตบน (upper bound) ของอัตราการจับคู่ที่แยกออกจากต้นทุน settlement อย่างชัดเจน ผลนี้บ่งชี้ว่าในสถาปัตยกรรมแบบแยกชั้น การจับคู่ในชั้น off-chain มิใช่คอขวดของระบบเมื่อเทียบกับต้นทุนการชำระธุรกรรมบนเชนใน@sec:settlement-cost ทั้งนี้การจับคู่แบบ single-cycle 1,000 × 1,000 เป็นภาระงานสังเคราะห์เพื่อวัดต้นทุนต่อรอบ มิใช่อัตราคงตัวภายใต้กระแสคำสั่งจริงที่มีการกระจายราคาและโซนหลากหลาย ซึ่งเป็นงานในลำดับถัดไป

== On-chain Settlement Cost <sec:settlement-cost>
นอกเหนือจากเส้นทางรับข้อมูล ผู้วิจัยวัดต้นทุนการประมวลผลบนเชนของการชำระธุรกรรมโดยตรง โดยรายงานหน่วยประมวลผล (compute units, CU) ที่คำสั่งชำระแบบจับคู่นอกเชน (off-chain match) ใช้จริง อ่านจากค่า `computeUnitsConsumed` ของธุรกรรมที่ยืนยันแล้วในการทดสอบ escrow settlement บน solana-test-validator 3.1.10 (Agave client) ค่านี้เป็นตัวชี้วัดต้นทุนบนเชนที่กำหนดได้แน่นอน (deterministic) และไม่ขึ้นกับฮาร์ดแวร์ของ validator ต่างจากความหน่วงบนเครือข่ายทดสอบเฉพาะที่ ซึ่งไม่สื่อถึงเครือข่ายเป้าหมายเชิงออกแบบ ผลสรุปใน@tbl:settle-cu

#figure(
  caption: [Measured compute-unit cost of the settlement instruction (1 matched order pair).],
  text(size: 7pt)[
    // zero: group-format + align the compute-unit figure (comma sep to match prose "96,707").
    #set-group(separator: ",")
    #show math.equation: set text(size: 7pt)
    #show table: format-table(none, auto)
    #table(
      columns: (auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon),
      table.header([*คำสั่ง (instruction)*], [*compute units*]),
      [settlement ต่อ 1 คู่คำสั่ง], [#metrics.settle-cu],
    )
  ],
) <tbl:settle-cu>

ค่า 96,707 CU ต่อการชำระหนึ่งคู่คำสั่ง#footnote[ต้นทุน compute ขึ้นกับรูปแบบการโอนขาเงินของธุรกรรม ค่าที่รายงานนี้เป็นค่าจากชุดทดสอบ escrow settlement หนึ่งรูปแบบ ส่วนเส้นทางที่มีขาแลกเปลี่ยนแบบ classic-SPL สู่ Token-2022 วัดได้ราว 103k CU และการชำระแบบกลุ่มที่ใช้ Token-2022 ทั้งสองขาวัดได้ราว 80–92k CU ตัวเลข 96,707 จึงเป็นค่าเฉพาะของรูปแบบที่วัด มิใช่ค่าคงที่สากล] เทียบกับงบประมาณ compute ตั้งต้นต่อคำสั่งที่ 200,000 CU และเพดานสูงสุดต่อธุรกรรมที่ 1,400,000 CU บ่งชี้ว่าการชำระแต่ละครั้งใช้ทรัพยากรประมาณ 48% ของงบตั้งต้น อนึ่ง แม้เพดาน compute สูงสุดต่อธุรกรรมจะรองรับได้ในเชิงทฤษฎีราว 14 คู่ต่อธุรกรรม แต่ข้อจำกัดที่บังคับจริง (binding constraint) มิใช่ compute แต่เป็นขนาดแพ็กเก็ตธุรกรรม 1,232 ไบต์ ซึ่งบีบจำนวนคู่ต่อธุรกรรมให้ต่ำกว่าเพดาน 4 คู่ที่โปรแกรม `batch_settle_offchain_match` อนุญาต (ดู@sec:tx-structure) ดังนั้นการลดต้นทุนต่อคู่ด้วย batch settlement จึงต้องเปลี่ยนวิธีบรรจุลายเซ็น มิใช่อาศัยงบ compute ที่เหลือเพียงอย่างเดียว ทั้งนี้ระดับต้นทุน 48% ต่อคำสั่งยังคงสอดคล้องกับการออกแบบให้บล็อกเชนทำหน้าที่เป็นชั้น settlement ที่ใช้ compute ต่ำตาม@sec:system-architecture

== ปริมาณงานธุรกรรมบนเชน (On-chain Transaction Throughput) <sec:onchain-throughput>
นอกเหนือจากต้นทุน compute ต่อคำสั่งใน@sec:settlement-cost ผู้วิจัยวัดปริมาณงาน (throughput) ของการประมวลผลธุรกรรมบนเชนด้วยชุดภาระงาน OLTP มาตรฐานที่พอร์ตมาสู่ account model ของ Solana ได้แก่ BlockBench (ไมโครเบนช์มาร์กแบบ SIGMOD 2017 ร่วมกับ YCSB), SmallBank และ TPC-C เสริมด้วยการวัดเส้นทางการชำระจริง (settle_offchain_match) ทั้งหมดรันบน solana-test-validator เดี่ยว (single-node; เครือข่าย permissioned ที่กำกับการเข้าร่วมแบบ PoA) บนเครื่อง Apple M2 (8 cores) ที่ commit `58cfc79` ของ gridtokenx-anchor โดยความหน่วงเป็นเวลานาฬิกาจริงแบบ client→confirmed และหน่วย compute อ่านจาก `computeUnitsConsumed` ของธุรกรรมที่ยืนยันแล้ว ผลภาระงาน OLTP แบบลำดับสรุปใน@tbl:oltp-bench และผลการกวาดค่าระดับการทำงานพร้อมกัน (concurrency sweep) ของ TPC-C สรุปใน@tbl:tpc-sweep

#figure(
  caption: [Standard OLTP workloads ported to the account model (sequential, n = 150). TPS here is latency-bound by the single-client submit loop, not a throughput ceiling; `ycsb_read` is an RPC account fetch with no consensus round-trip.],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon, center + horizon, center + horizon, center + horizon),
      table.header([*ภาระงาน (workload · op)*], [*mean ms*], [*TPS*], [*CU/tx*]),
      [BlockBench · `do_nothing`], [719.95], [1.39], [648],
      [BlockBench · `cpu_heavy_sort`], [590.83], [1.69], [9,645],
      [BlockBench · `ycsb_read` (RPC)], [4.29], [233.18], [—],
      [SmallBank · `SendPayment`], [604.63], [1.65], [5,963],
      [SmallBank · `Amalgamate`], [631.62], [1.58], [5,936],
    )
  ],
) <tbl:oltp-bench>

#figure(
  caption: [TPC-C concurrency sweep (TX = 500, 50% NewOrder / 50% Payment), 100% success at every level. Throughput from concurrent in-flight submission; CU/tx is flat across load.],
  text(size: 7pt)[
    #table(
      columns: (auto, auto, auto, auto, auto),
      inset: (x: 4pt, y: 3pt),
      align: (center + horizon,) * 5,
      table.header([*concurrency*], [*TPS*], [*mean ms*], [*p95 ms*], [*CU/tx (mean)*]),
      [5], [8.67], [575.00], [726.10], [21,263],
      [10], [14.50], [679.34], [879.95], [20,633],
      [20], [21.87], [856.74], [1,656.15], [21,269],
      [40], [29.90], [1,057.79], [1,707.00], [21,508],
    )
  ],
) <tbl:tpc-sweep>

#figure(
  text(size: 8pt)[
    #lq.diagram(
      width: 6.5cm, height: 4cm,
      xscale: "log",
      xaxis: (ticks: ((5, [5]), (10, [10]), (20, [20]), (40, [40]))),
      xlabel: [concurrency (in-flight tx)],
      ylabel: [TPS (settled/s)],
      ylim: (0, 75),
      legend: (position: top + left),
      // shade the throughput shortfall (measured vs linear-ideal) — the sublinear gap
      lq.fill-between((5, 10, 20, 40), (8.67, 14.50, 21.87, 29.90), y2: (8.67, 17.34, 34.68, 69.36),
        fill: c-gray.transparentize(85%), stroke: none, z-index: 0),
      lq.plot((5, 10, 20, 40), (8.67, 17.34, 34.68, 69.36), mark: none, color: c-gray, label: [linear (ideal)]),
      lq.plot((5, 10, 20, 40), (8.67, 14.50, 21.87, 29.90), mark: "o", color: c-blue, label: [measured]),
    )
  ],
  caption: [TPC-C throughput vs. concurrency on the single-node validator. Measured TPS scales sublinearly — 8× concurrency yields only 3.45× throughput — diverging from the linear-ideal reference, with the saturation knee between concurrency 10 and 20.],
) <fig:tpc-tps>

ตัวเลขที่สำคัญที่สุดต่อระบบนี้คือปริมาณงานของเส้นทางการชำระจริง มิใช่ของ proxy ทั่วไป เมื่อวัดเส้นทาง `batch_settle_offchain_match` แบบ open-loop submission sweep (สร้างธุรกรรมล่วงหน้าแล้วยิงพร้อมกันตามระดับ concurrency และยิงซ้ำธุรกรรมที่ตกหล่นจนยืนยัน) ได้อัตราเพียง ~0.5 TPS และคงที่ทุกระดับ concurrency (ตัวเลขส่วนนี้มาจากการรันบันทึกเพียงรอบเดียว ซึ่งต่างจากชุด TPC-C/OLTP ที่ commit ผลดิบเป็น artifact ไว้ จึงควรตีความเป็นค่าบ่งชี้เชิงออกแบบที่รอการวัดซ้ำ) (conc 5 → 0.51, conc 10 → 0.58 TPS; goodput 100%, ไม่มี revert บนเชน, CU ราว 86–89k) ทั้งยังไม่ขยายตามจำนวนธุรกรรมที่ส่งพร้อมกัน แม้กระจายการชำระข้ามทั้ง 16 ชาร์ดก็ได้ตัวเลขใกล้เดิม (0.57–0.59 TPS) เพราะคอขวดมิใช่ชาร์ด แต่เป็นชุดบัญชีส่วนกลางที่ทุกการชำระต้องเขียนเสมอ ได้แก่ บัญชีสะสมยอด `total_settled_thbg` และบัญชีผู้เก็บค่าธรรมเนียม/ค่าผ่านสาย/การสูญเสีย การชำระจึงถูกผูกกับการเขียนส่วนกลาง (global-write-bound) โดยการออกแบบ การแบ่งชาร์ดขนานได้เฉพาะการส่งคำสั่ง (order submission) ที่ใช้ PDA รายเอนทิตี มิใช่การกระทบยอดของการชำระ

ทั้งใน TPC-C sweep หน่วย compute ต่อธุรกรรมคงที่ราว 21,000 CU ทุกระดับ concurrency ชี้ว่าคอขวดของปริมาณงานคือเวลาในการผลิตบล็อก (block time ราว 400–600 มิลลิวินาที) ร่วมกับการ serialize การเขียนบัญชีส่วนกลาง มิใช่การประมวลผลบนเชน ด้วยเหตุนี้หน่วย compute ต่อธุรกรรม (@sec:settlement-cost) จึงเป็นตัวชี้วัดต้นทุนที่ไม่ขึ้นกับภาระงานและเครื่อง ขณะที่ TPS เป็นตัวเลขที่ขึ้นกับ validator เดี่ยวที่ใช้ทดสอบ การกวาดค่ายังแสดงการขยายแบบ sublinear (concurrency 5 → 40 เพิ่มขึ้น 8 เท่า ให้ TPS เพิ่มเพียง 3.45 เท่า) และจุดอิ่มตัว (saturation knee) ระหว่าง concurrency 10 ถึง 20 ที่ส่วนเบี่ยงเบนของความหน่วงและ p95 เพิ่มขึ้นชัดเจน ดังแสดงเทียบกับเส้นอ้างอิงเชิงเส้นใน@fig:tpc-tps

เมื่อเทียบกับหน้าต่างการเคลียร์ตลาด 900 วินาที แม้อัตราการชำระจริง ~0.5 TPS ยังรองรับได้ราว 450 การชำระต่อหน้าต่าง ซึ่งเกินความต้องการของภาระงาน 80 มาตรวัดในการประเมินนี้มาก ส่วนเพดาน proxy ที่ 29.9 TPS เทียบเท่าราว 2.69 × 10#super[4] ธุรกรรมต่อหน้าต่าง อย่างไรก็ตามผลทั้งหมดมาจาก validator เดี่ยว จึงควรตีความภายใต้ข้อจำกัดสี่ประการ ประการแรก การวัดบน validator เดี่ยวไม่สะท้อนต้นทุน consensus (PoH ร่วมกับ Tower BFT) ของเครือข่าย permissioned หลายโหนด ซึ่งเป็นที่มาของข้อสังเกตว่า block time เป็นคอขวด ประการที่สอง BlockBench, SmallBank และ TPC-C เป็น proxy ทั่วไปมิใช่ภาระงานพลังงาน อัตรา TPS ของเส้นทางชำระจริงจึงต่ำกว่าตัวเลข proxy อย่างมีนัย ประการที่สาม เส้นทางแบบลำดับใน@tbl:oltp-bench ที่ ~1.4–1.7 TPS เป็น latency-bound มิใช่เพดาน throughput และประการที่สี่ ตัวเลข TPS ของการกวาด TPC-C เป็นค่าจุดเดียวต่อระดับ concurrency โดยรายงานช่วงความเชื่อมั่นเฉพาะของความหน่วง (latency CI95) เท่านั้น ยังไม่ได้ทำซ้ำหลายรอบเพื่อรายงานช่วงความเชื่อมั่นของ TPS การวัดแบบ open-loop หลายโหนดพร้อมทำซ้ำเพื่อหา peak TPS ที่ระดับ SLA เป็นงานในลำดับถัดไป (ดู@sec:discussion_limitations)

== Per-instruction Compute-unit Profile <sec:cu-profile>
นอกจากต้นทุนของเส้นทางชำระหลักใน@sec:settlement-cost ผู้วิจัยวัดต้นทุน compute ต่อ instruction ของโปรแกรมบนเชนทุกตัวในเส้นทางการทำงานจริง เพื่อยืนยันด้วยการวัดว่าภาระ compute บนเชนถูกจำกัดให้บางตามการออกแบบ ค่าทั้งหมดอ่านจาก `computeUnitsConsumed` ของธุรกรรม โดยวัดในกระบวนการ (in-process) ด้วย litesvm เหนือไบนารีที่ build แบบ default-feature ที่ commit `58cfc79` ของ gridtokenx-anchor ยกเว้นคำสั่งชำระ `settle_offchain_match` ที่วัดบน validator จริง (@sec:settlement-cost) เนื่องจาก compute unit เป็นค่าที่กำหนดได้แน่นอน (deterministic) จึงเทียบกันได้ระหว่างสองวิธี ผลสรุปใน@fig:cu-profile

#figure(
  caption: [Measured per-instruction compute-unit cost across the on-chain programs (litesvm `computeUnitsConsumed`, default-feature build; `settle_offchain_match` measured on a live validator per @sec:settlement-cost), sorted by cost. Only the signature-verifying settlement path approaches half the 200,000 CU per-instruction budget (dashed); every other instruction stays well below — the measured signature of a thin settlement layer.],
  text(size: 6.5pt)[
    #show raw: set text(font: ("Courier New", "Courier"), size: 5.5pt)
    #let names = ([`update_meter_reading`], [`record_settlement_sharded`], [`burn_tokens`], [`aggregate_readings`], [`trigger_market_clearing`], [`create_sell_order`], [`match_orders`], [`update_erc_limits`], [`submit_meter_reading`], [`mint_to_wallet`], [`register_meter`], [`swap_grx_for_thbg`], [`deposit_escrow`], [`settle_offchain_match`])
    #let cu = (3899, 5370, 6537, 8362, 8390, 11508, 11746, 13283, 13376, 13700, 20104, 21488, 27658, 96707)
    #lq.diagram(
      width: 7.2cm, height: 5.4cm,
      xlabel: [compute units (CU)], xlim: (0, 205000),
      yaxis: (ticks: range(14).zip(names)),
      ylim: (-0.8, 13.8),
      lq.hbar(cu, range(14), fill: c-blue.lighten(55%), stroke: 0.5pt + c-blue),
      lq.vlines(200000, stroke: (paint: c-vermillion, dash: "dashed", thickness: 0.7pt), label: [200k budget]),
    )
  ],
) <fig:cu-profile>

จาก@fig:cu-profile ทุก instruction ยกเว้นเส้นทางชำระที่ตรวจลายเซ็น (`settle_offchain_match`) ใช้ compute ไม่เกินประมาณ 28k CU หรือราว 14% ของงบตั้งต้น 200k CU โดยเส้นทางที่มีความถี่สูงอยู่ในระดับต่ำสุด ได้แก่ `update_meter_reading` (3.9k) และ `record_settlement_sharded` (5.4k) ซึ่งเป็นไปตามการออกแบบให้บัญชี PDA รายเอนทิตีบนเส้นทางร้อนไม่ล็อกเขียนบัญชีส่วนกลาง ผลนี้ยืนยันด้วยการวัดจริง (มิใช่การคาดการณ์) ว่างานประมวลผลหนัก เช่น การตรวจรูปแบบข้อมูล การประเมินเงื่อนไข Grid stability และการจัดคิวคำสั่งซื้อขาย ถูกย้ายไปทำในชั้น Backend ก่อน ขณะที่ Smart Contract บังคับใช้เฉพาะเงื่อนไขขั้นต่ำที่ตรวจสอบได้บนเชน (account ownership, ลายเซ็น Ed25519, order nullifier และสถานะ escrow) จึงทำหน้าที่เป็นชั้น settlement และ audit ที่ใช้ compute ต่ำตามที่ออกแบบไว้

ในด้าน I/O และ storage สถาปัตยกรรมส่งข้อมูลมาตรวัดความถี่สูงผ่าน Aggregator Bridge เพื่อคัดกรองก่อน แล้วบันทึกเฉพาะ Event log ของธุรกรรมที่จำเป็นต่อการตรวจสอบย้อนหลังลงบนเชน (ดู@fig:telemetry-dissemination) การวัดปริมาณ record, retention policy และ storage cost เชิงปริมาณยังเป็นงานในอนาคต
