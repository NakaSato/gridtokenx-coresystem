#heading(level: 1)[EXPERIMENTAL SETUP] <sec:experimental-setup>

ส่วนนี้สรุปรายละเอียดการพัฒนา (implementation) เวอร์ชันของสิ่งประดิษฐ์ (artifact) ตัวแปรของภาระงาน (workload parameters) และนิยามของตัวชี้วัด เพื่อให้การประเมินใน @sec:evaluation ทำซ้ำได้ ทั้งนี้ผู้วิจัยระบุข้อจำกัดด้านการทำซ้ำที่ยังเหลืออยู่ไว้อย่างตรงไปตรงมาในตอนท้ายของส่วนนี้

#heading(level: 2)[Implementation and Artifact]
บริการฝั่ง Backend ทุกตัวพัฒนาด้วยภาษา Rust (Axum) บน Tokio async runtime และสื่อสารระหว่างกันผ่าน ConnectRPC บน mTLS ส่วนเส้นทางเขียนข้อมูลลงบล็อกเชนแยกออกผ่าน NATS JetStream @natsio2024 ส่วนชุดจำลองโครงข่ายและสมาร์ทมิเตอร์พัฒนาด้วย Python 3.11 @python311 (รายละเอียดเครื่องมือใน @sec:grid-simulator) ระบบทั้งหมดจัดเรียงเป็น superproject ที่รวมแต่ละบริการเป็น git submodule ทำให้ระบุเวอร์ชันของสิ่งประดิษฐ์ได้จาก commit ของ superproject ร่วมกับ pointer ของแต่ละ submodule การทดลองในบทความนี้อ้างอิงสถานะของ superproject ที่ commit `4b05661` ซึ่งตรึง pointer ของบริการหลัก ได้แก่ Aggregator Bridge, Chain Bridge, Anchor programs, blockchain-core และ Smart Meter Simulator ไว้อย่างเฉพาะเจาะจง

#heading(level: 2)[Topology and Endpoints]
ในเส้นทางที่ประเมิน Smart Meter Simulator ส่งค่าอ่านเข้าสู่ Aggregator Bridge ผ่าน IoT gateway (HTTP) และช่องทาง gRPC สำหรับ ingest จากนั้น Aggregator Bridge ตรวจลายเซ็นและกระจายค่าอ่านที่ผ่านการตรวจสอบเข้าสู่ Redis Streams ที่แบ่งตามโซน ส่วนเส้นทางเขียนเชนถูกส่งผ่าน Chain Bridge ด้วยหัวข้อ NATS ตระกูล `chain.tx.*` (เช่น `chain.tx.submit` และ `chain.tx.mint`) การแยกพอร์ตและช่องทางในลักษณะนี้ทำให้เส้นทางรับข้อมูล (ingest) ขยายขนาดได้อิสระจากเส้นทาง settlement

#heading(level: 2)[Workload Parameters]
ภาระงานในการประเมินกำหนดด้วยสมาร์ทมิเตอร์จำนวน 80 เครื่อง (`NUM_METERS=80`) ที่ส่งค่าอ่านทุก 15 วินาทีของเวลาจำลอง (`SIMULATION_INTERVAL=15`) ตามค่าตั้งต้นของชุดจำลอง รอบการส่งทุก 15 วินาทีของเวลาจำลองสอดคล้องกับการบีบอัดเวลา (time compression) ประมาณ 60 เท่าเมื่อเทียบกับหน้าต่างเวลา 15 นาที (900 วินาที) ของรอบการส่งข้อมูลของมาตรวัดจริง ในที่นี้นิยาม "ค่าอ่าน" (reading) ที่ใช้เป็นหน่วยวัดปริมาณงานว่าหมายถึงค่าอ่านมาตรวัดหนึ่งรายการที่ลงนามด้วย Ed25519 แล้วผ่านการตรวจสอบลายเซ็นและถูกกระจายเข้าสู่ Redis Stream ที่ Aggregator Bridge มิใช่คำสั่งซื้อขายที่จับคู่แล้วหรือธุรกรรม settlement บนบล็อกเชน ตัวแปรหลักของภาระงานสรุปไว้ใน @tbl:workload

#figure(
  caption: [Workload parameters for the telemetry-ingest evaluation.],
  text(size: 8pt)[
    #show math.equation: set text(size: 8pt)
    #table(
    columns: (auto, auto, 1fr),
    align: (left + horizon, left + horizon, left + horizon),
    table.header([พารามิเตอร์], [ค่า], [ความหมาย]),
    [`NUM_METERS`], [80], [จำนวนสมาร์ทมิเตอร์ในการจำลอง],
    [`SIMULATION_INTERVAL`], [15 s], [รอบการส่งค่าอ่านในเวลาจำลอง],
    [Time compression], [$approx 60 times$], [เทียบกับหน้าต่างจริง 900 s],
    [Nominal ingest rate], [5.33 readings/s], [$80 div 15$ ในเวลาจำลอง],
    [Run duration], [$approx 27$ min], [เวลานาฬิกาจริงของการรันหนึ่งรอบ],
    [Total readings], [26,240], [ตรวจลายเซ็นสำเร็จ ไม่มีการสูญหาย],
    )
  ],
) <tbl:workload>

#heading(level: 2)[Metrics]
ตัวชี้วัดหลักของการประเมินเส้นทางรับข้อมูลคืออัตราการรับข้อมูล (ingest rate) ในสองนิยาม ได้แก่ อัตราเชิงออกแบบในเวลาจำลอง (nominal) เท่ากับ $80 div 15 = 5.33$ รายการต่อวินาที และอัตราที่วัดจากเวลานาฬิกาจริง (wall-clock) ซึ่งสูงกว่าเนื่องจากรอบการส่งของ simulator ถูกเร่งให้เร็วกว่าช่วง 15 วินาทีของเวลาจำลอง ร่วมกับจำนวนค่าอ่านสะสมที่ตรวจสอบสำเร็จและสัดส่วนการสูญหายของข้อมูล รายละเอียดผลการวัดอยู่ใน @sec:ingest-throughput

#heading(level: 2)[Reproducibility Limitations]
การทดลองเส้นทางรับข้อมูลแบบรันยาวใน @sec:ingest-throughput เป็นการรันจริงเพียงรอบเดียว ส่วนการทดลองเพิ่มภาระงานแบบขั้นบันไดใน @sec:ingest-saturation ทำซ้ำ 5 รอบต่อขนาดฟลีตและรายงานค่าเฉลี่ยพร้อมส่วนเบี่ยงเบนมาตรฐานบนเครื่อง Apple M2 (8 cores, หน่วยความจำ 16 GiB) ที่บันทึกไว้ ข้อจำกัดด้านการทำซ้ำที่ยังเหลืออยู่คือ ภาระงานถูกสร้างจากไคลเอนต์ผู้ส่งเพียงตัวเดียว (ยังไม่ได้ทดสอบผู้ส่งแบบขนาน) ตัวเลขอัตราการรับข้อมูลที่รายงานจึงเป็น lower bound ของเส้นทางรับข้อมูลมากกว่าขอบเขตความสามารถสูงสุด และการวัดเส้นทาง settlement บนเชนยังจำกัดอยู่ที่ต้นทุน compute-unit ต่อคำสั่ง โดยยังไม่ครอบคลุม latency และ throughput แบบ end-to-end การทดลองถัดไปจึงควรเพิ่มผู้ส่งแบบขนานเพื่อหาเพดานที่แท้จริง บันทึกการตั้งค่า validator และขยายการวัดให้ครอบคลุมเส้นทาง settlement บนเชนแบบ end-to-end (ดู @sec:discussion_limitations)
