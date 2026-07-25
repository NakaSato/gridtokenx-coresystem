#import "../metrics.typ": nominal-rate

= EXPERIMENTAL SETUP <sec:experimental-setup>

ส่วนนี้สรุปรายละเอียดการพัฒนา (implementation) เวอร์ชันของสิ่งประดิษฐ์ (artifact) ตัวแปรของภาระงาน (workload parameters) และนิยามของตัวชี้วัด เพื่อให้การประเมินใน@sec:evaluation ทำซ้ำได้ ทั้งนี้ผู้วิจัยระบุข้อจำกัดด้านการทำซ้ำที่ยังเหลืออยู่ไว้อย่างตรงไปตรงมาในตอนท้ายของส่วนนี้

== Implementation and Artifact
บริการฝั่ง Backend ทุกตัวพัฒนาด้วยภาษา Rust (Axum) บน Tokio async runtime และสื่อสารระหว่างกันผ่าน ConnectRPC บน mTLS ส่วนเส้นทางเขียนข้อมูลลงบล็อกเชนแยกออกผ่าน NATS JetStream @natsio2024 ส่วนชุดจำลองโครงข่ายและ Smart Meter พัฒนาด้วย Python 3.11 @python311 (รายละเอียดเครื่องมือใน@sec:grid-simulator) ระบบทั้งหมดจัดเรียงเป็น superproject ที่รวมแต่ละบริการเป็น git submodule ทำให้ระบุเวอร์ชันของสิ่งประดิษฐ์ได้จาก commit ของ superproject ร่วมกับ pointer ของแต่ละ submodule บทความนี้ระบุเวอร์ชันของสิ่งประดิษฐ์แยกรายการทดลอง มิใช่เป็น pin เดียวสำหรับทั้งบทความ เพราะการวัดแต่ละชุดเกิดขึ้นคนละจุดบนสายการพัฒนาเดียวกัน การทดลองเส้นทาง telemetry ingest (@sec:ingest-throughput และ@sec:ingest-saturation) อ้างอิงสถานะของ superproject ที่ commit `4b05661` ซึ่งตรึง pointer ของบริการหลัก ได้แก่ Aggregator Bridge, Chain Bridge, Anchor programs, blockchain-core และ Smart Meter Simulator ไว้อย่างเฉพาะเจาะจง ส่วนการวัดต้นทุนและปริมาณงานบนเชน (@sec:settlement-cost, @sec:onchain-throughput และ@sec:cu-profile) ดำเนินการบนชุดเบนช์มาร์กของ gridtokenx-anchor ที่ commit `58cfc79` ซึ่งเป็นบรรพบุรุษ (ancestor) ของ pointer ที่ superproject `4b05661` ตรึงไว้ ขณะที่การทดลองระดับฟลีตทั้ง live mint และการเขียน telemetry บนเชน (@sec:scale-onchain-validation) อยู่หลัง `4b05661` โดยจำเป็น เพราะวัดเส้นทางโค้ดที่เพิ่งเพิ่มหรือปรับจูนระหว่างการรันเหล่านั้นเอง ได้แก่ การเพิ่ม concurrency ของ mint consumer งบเวลารอตอบกลับของ aggregator และการแก้ label ของ request metrics ที่รายงานไว้ในหัวข้อดังกล่าว จึงอ้างอิงสถานะของ superproject ถึง commit `cdd9d00` การทำซ้ำตัวเลขใดตัวเลขหนึ่งจึงต้องใช้ commit ที่ระบุไว้กับการทดลองนั้น มิใช่ pin เดียวของทั้งบทความ

== Topology and Endpoints
ในเส้นทางที่ประเมิน Smart Meter Simulator ส่งค่าอ่านเข้าสู่ Aggregator Bridge ผ่าน IoT gateway (HTTP) และช่องทาง gRPC สำหรับ ingest จากนั้น Aggregator Bridge ตรวจลายเซ็นและกระจายค่าอ่านที่ผ่านการตรวจสอบเข้าสู่ Redis Streams ที่แบ่งตามโซน ส่วนเส้นทางเขียนเชนถูกส่งผ่าน Chain Bridge ด้วยหัวข้อ NATS ตระกูล `chain.tx.*` (เช่น `chain.tx.submit` และ `chain.tx.mint`) การแยกพอร์ตและช่องทางในลักษณะนี้ทำให้เส้นทางรับข้อมูล (ingest) ขยายขนาดได้อิสระจากเส้นทาง settlement

== Deployed Components Outside the Measured Scope <sec:out-of-scope-components>
เส้นทางที่ประเมินข้างต้นเป็นเพียงส่วนหนึ่งของระบบที่ติดตั้งใช้งานจริง เพื่อให้อ่านผลใน@sec:evaluation ได้ตรงตามขอบเขต บทความนี้ระบุอย่างชัดเจนว่าองค์ประกอบใดที่รันอยู่แต่อยู่นอกขอบเขตการวัด การติดตั้งจริงยังประกอบด้วย API gateway (APISIX) เป็นทางเข้าฝั่งผู้ใช้ (เส้นทาง ingest ที่วัดข้ามส่วนนี้ไปและเรียก IoT gateway ของ Aggregator Bridge โดยตรง), แกนกลางเหตุการณ์ Kafka สามโบรกเกอร์ที่รับส่งเหตุการณ์ตัวตนผู้ใช้ read model ของเจ้าของมาตรวัด และสายงานการแจ้งเตือน, บริการ meter-service ที่เป็นเจ้าของการลงทะเบียนและทะเบียนมาตรวัด, การแยกฐานข้อมูลรายบริการ (แต่ละบริการเป็นเจ้าของ schema ของตนเองผ่านตัวจัดเส้นทางการเชื่อมต่อ) แทนฐานข้อมูลร่วมหนึ่งชุด, Chain Bridge สองเรพลิกาที่ใช้กลไกกันงานซ้ำร่วมกันเพื่อความ idempotent ของการส่งธุรกรรม, mint outbox แบบคงทนที่ส่งซ้ำจนกว่าเชนจะยืนยัน, ชุดสังเกตการณ์ระบบ (metrics/log/trace) และเว็บฟรอนต์เอนด์สามตัว (ส่วนติดต่อการซื้อขาย, block explorer และส่วนติดต่อของชุดจำลอง) องค์ประกอบเหล่านี้ไม่ถูกใช้เป็นตัวแปรในการทดลองใดของบทความนี้และไม่มีการรายงานผล อย่างไรก็ตามสององค์ประกอบมีผลต่อตัวเลขที่รายงานไว้และถูกอ้างถึงตรงจุดที่เกี่ยวข้อง กล่าวคือ mint outbox แบบคงทนคือกลไกที่พาส่วนหางที่ล่าช้าใน@tbl:fleet-mint ให้สำเร็จครบ และชุดสังเกตการณ์ระบบคือจุดที่วินิจฉัยเหตุ metrics cardinality ใน@sec:scale-onchain-validation การวัด gateway แกนกลางเหตุการณ์ และเส้นทางหลายฐานข้อมูล เป็นงานในอนาคต (@sec:discussion_limitations)

== Workload Parameters
ภาระงานในการประเมินกำหนดด้วย Smart Meter จำนวน 80 เครื่อง (`NUM_METERS=80`) ที่ส่งค่าอ่านทุก 15 วินาทีของเวลาจำลอง (`SIMULATION_INTERVAL=15`) ตามค่าตั้งต้นของชุดจำลอง รอบการส่งทุก 15 วินาทีของเวลาจำลองสอดคล้องกับการบีบอัดเวลา (time compression) ประมาณ 60 เท่าเมื่อเทียบกับหน้าต่างเวลา 15 นาที (900 วินาที) ของรอบการส่งข้อมูลของมาตรวัดจริง ในที่นี้นิยาม "ค่าอ่าน" (reading) ที่ใช้เป็นหน่วยวัดปริมาณงานว่าหมายถึงค่าอ่านมาตรวัดหนึ่งรายการที่ลงนามด้วย Ed25519 แล้วผ่านการตรวจสอบลายเซ็นและถูกกระจายเข้าสู่ Redis Stream ที่ Aggregator Bridge มิใช่คำสั่งซื้อขายที่จับคู่แล้วหรือธุรกรรม settlement บนบล็อกเชน ตัวแปรหลักของภาระงานสรุปไว้ใน@tbl:workload

#figure(
  caption: [Workload parameters for the telemetry-ingest evaluation.],
  text(size: 8pt)[
    #show math.equation: set text(size: 8pt)
    // env-var names render as monospace code (override the template's serif-italic inline raw)
    #show raw: set text(font: ("Courier New", "Courier"), style: "normal")
    #table(
    columns: (auto, auto, 1fr),
    inset: (x: 4pt, y: 3pt),
    align: (left + horizon, left + horizon, left + horizon),
    table.header([พารามิเตอร์], [ค่า], [ความหมาย]),
    [`NUM_METERS`], [80], [จำนวน Smart Meter ในการจำลอง],
    [`SIMULATION_INTERVAL`], [15 s], [รอบการส่งค่าอ่านในเวลาจำลอง],
    [Time compression], [≈ 60 ×], [เทียบกับหน้าต่างจริง 900 s],
    [Nominal ingest rate], [#nominal-rate readings/s], [80 ÷ 15 ในเวลาจำลอง],
    [Run duration], [≈ 27 min], [เวลานาฬิกาจริงของการรันหนึ่งรอบ],
    [Total readings], [26,240], [ตรวจลายเซ็นสำเร็จ ไม่มีการสูญหาย],
    )
  ],
) <tbl:workload>

== Metrics
ตัวชี้วัดหลักของการประเมินเส้นทางรับข้อมูลคืออัตราการรับข้อมูล (ingest rate) ในสองนิยาม ได้แก่ อัตราเชิงออกแบบในเวลาจำลอง (nominal) เท่ากับ $80 div 15 = 5.33$ รายการต่อวินาที และอัตราที่วัดจากเวลานาฬิกาจริง (wall-clock) ซึ่งสูงกว่าเนื่องจากรอบการส่งของ simulator ถูกเร่งให้เร็วกว่าช่วง 15 วินาทีของเวลาจำลอง ร่วมกับจำนวนค่าอ่านสะสมที่ตรวจสอบสำเร็จและสัดส่วนการสูญหายของข้อมูล รายละเอียดผลการวัดอยู่ใน@sec:ingest-throughput

== Reproducibility Limitations
การทดลองเส้นทางรับข้อมูลแบบรันยาวใน@sec:ingest-throughput เป็นการรันจริงเพียงรอบเดียว ส่วนการทดลองเพิ่มภาระงานแบบขั้นบันไดใน@sec:ingest-saturation ทำซ้ำ 5 รอบต่อขนาดฟลีตและรายงานค่าเฉลี่ยพร้อมส่วนเบี่ยงเบนมาตรฐานบนเครื่อง Apple M2 (8 cores, หน่วยความจำ 16 GiB) ที่บันทึกไว้ ข้อจำกัดด้านการทำซ้ำที่ยังเหลืออยู่คือ ภาระงานถูกสร้างจากไคลเอนต์ผู้ส่งเพียงตัวเดียว (ยังไม่ได้ทดสอบผู้ส่งแบบขนาน) ตัวเลขอัตราการรับข้อมูลที่รายงานจึงเป็น lower bound ของเส้นทางรับข้อมูลมากกว่าขอบเขตความสามารถสูงสุด และการวัดเส้นทาง settlement บนเชนยังจำกัดอยู่ที่ต้นทุน compute-unit ต่อคำสั่ง โดยยังไม่ครอบคลุม latency และ throughput แบบ end-to-end การทดลองถัดไปจึงควรเพิ่มผู้ส่งแบบขนานเพื่อหาเพดานที่แท้จริง บันทึกการตั้งค่า validator และขยายการวัดให้ครอบคลุมเส้นทาง settlement บนเชนแบบ end-to-end (ดู@sec:discussion_limitations)
