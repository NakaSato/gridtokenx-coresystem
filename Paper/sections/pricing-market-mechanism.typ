= PRICING AND MARKET MECHANISM <sec:pricing-market-mechanism>

== Pricing and Settlement Model <sec:pricing-model>
แบบจำลองราคาของระบบแบ่งเป็นสามส่วน คือ การกำหนดราคาเคลียร์ในกลไก CDA การคำนวณค่าธรรมเนียมและยอดสุทธิในการ settlement และกลไกราคาของโทเคนในชั้น treasury สัญลักษณ์ที่ใช้ในสมการสรุปไว้ใน@tbl:nomenclature

#figure(
  text(size: 8pt)[
    // Override the template's global `show math.equation: set text(size: 10pt)`
    // so symbols match the (smaller) table text instead of staying at 10pt.
    #show math.equation: set text(size: 8pt)
    #table(
    columns: (auto, 1fr),
    inset: (x: 4pt, y: 3pt),
    align: (center + horizon, left + horizon),
    table.header([สัญลักษณ์], [ความหมาย]),
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
$ V &= q dot p^* #<eq:value> \
  f &= (V dot phi) / 10000 #<eq:fee> \
  "net" &= V - f - W - L #<eq:net> $
โดย $phi$ คือค่าธรรมเนียมตลาดในหน่วย basis point (ค่าตั้งต้นบนเชน 25 bps หรือ 0.25%), $W = q dot w$ คือค่าผ่านสายรวม และ $L = q dot c_("loss")$ คือต้นทุนการสูญเสียรวม ยอด $f$, $W$, $L$ และ net ถูกโอนแยกไปยังบัญชีผู้เก็บค่าธรรมเนียม ค่าผ่านสาย การสูญเสีย และผู้ขายตามลำดับ พารามิเตอร์ของโซนถูกตีความในหน่วย bps คือ $m = m_("bps") slash 10000$ และ $w = w_("bps") slash 10000$ โดยค่าตั้งต้นของ wheeling charge เท่ากับ 0 ภายในโซนและ 0.02 ข้ามโซน ส่วน loss factor เท่ากับ 1.01 ภายในโซนและ 1.03 ข้ามโซน

เพื่อให้เห็นภาพการใช้สมการข้างต้น พิจารณาตัวอย่างการจับคู่ภายในโซนเดียวกัน โดยกำหนดราคาเสนอขาย $p_s = 4.00$ บาทต่อ kWh ปริมาณ $q = 10$ kWh และใช้ค่าตั้งต้นภายในโซน ($lambda = 1.01$, $w = 0$, $m = 1$, $delta = 0.95$, $phi = 25$ bps) จาก@eq:loss-cost ได้ $c_("loss") = 4.00(1.01 - 1) = 0.04$ และจาก@eq:clearing ได้ราคาเคลียร์ $p^* = (4.00 + 0 + 0.04) dot 1 dot 0.95 = 3.838$ บาทต่อ kWh ซึ่งจับคู่ได้เมื่อราคาเสนอซื้อ $p_b >= 3.838$ จากนั้นมูลค่ารวม $V = 10 dot 3.838 = 38.38$ บาท ค่าธรรมเนียม $f = 38.38 dot 25 slash 10000 approx 0.096$ บาท ค่าผ่านสายรวม $W = 0$ และต้นทุนการสูญเสียรวม $L = 10 dot 0.04 = 0.40$ บาท ทำให้ยอดสุทธิที่ผู้ขายได้รับเท่ากับ $"net" = 38.38 - 0.096 - 0 - 0.40 approx 37.88$ บาท ทั้งนี้การคำนวณจริงในโค้ดใช้เลขทศนิยมตายตัวแบบปัดลง ค่าที่ได้จึงอาจต่างจากตัวอย่างนี้ในระดับเศษปัด

กลไกราคาของโทเคนในชั้น treasury ครอบคลุมการแลกเปลี่ยนระหว่าง GRX และ THBG stablecoin ที่ตรึงค่ากับเงินบาท โดยใช้อัตรา $r$ (จำนวน GRX atom ต่อ THBG) และค่าธรรมเนียม swap $psi$ (bps)
$ "thbg" &= (g dot r) / 10^9 dot (1 - psi slash 10000) #<eq:swap> \
  g &= ("thbg" dot 10^9) / r #<eq:redeem> $
โดยการ redeem ตาม@eq:redeem ไม่มีค่าธรรมเนียม และการรักษาค่าตรึงใช้เงื่อนไข supply ต่อ reserve แบบ 1:1 คือ $"supply"_("thbg") <= "reserve"_("attested")$ ส่วนรางวัลการ stake ใช้ตัวสะสม (accumulator) แบบ MasterChef โดยรางวัลค้างรับของผู้ stake คำนวณจากจำนวนที่ stake $s$
$ "reward" = s dot A slash 10^12 - "debt" $ <eq:reward>
เมื่อมีการเติมรางวัล $R$ ตัวสะสม $A$ จะถูกปรับเป็น $A <- A + (R dot 10^12) slash s_("total")$ แบบ pro-rata ตามสัดส่วนการ stake และการ slash จะหักจำนวนที่ร้องขอแต่ไม่เกินเงินต้นที่ stake ไว้ (capped ที่ principal) แล้วกระจายคืนสู่ผู้ stake ที่เหลือผ่านตัวสะสมเดียวกัน

ในเส้นทาง CDA ที่ใช้งานจริง ตัวคูณจูงใจถูกตั้งเป็น $m = 1$ กล่าวคือ incentive multiplier มีผลเฉพาะเส้นทาง settlement แบบ feed-in หรือ grid-export มิใช่การจับคู่ CDA นอกจากนี้ค่าตั้งต้นของค่าธรรมเนียมตลาดบนเชน (25 bps) แตกต่างจากค่าตั้งต้นในไฟล์ตั้งค่านอกเชน (50 bps) และพารามิเตอร์โซนในโปรแกรม governance จัดเก็บแบบสเกล ×1000 ขณะที่ผู้บริโภคค่าจริงในชั้น trading ตีความแบบ bps ($slash 10000$) ซึ่งเป็นค่าที่ระบบใช้งานจริง ทั้งนี้การคำนวณในโค้ดใช้เลขทศนิยมตายตัว (fixed-point integer) แบบปัดลง (floor division) และยอดสุทธิของผู้ขายใช้ checked arithmetic ที่ปฏิเสธธุรกรรมเมื่อค่าธรรมเนียมรวมเกินมูลค่าจับคู่ (พร้อมเพดานค่าธรรมเนียมเครือข่าย 20%) แทนการปัดยอดลงเป็นศูนย์ ดังนั้นสมการข้างต้นจึงเป็นแบบจำลองเชิงค่าจริงที่อาจต่างจากผลคำนวณจริงในระดับเศษปัด

== การวิเคราะห์ความไวของยอดสุทธิและส่วนเพิ่มจากการซื้อขายแบบ P2P <sec:revenue-sensitivity>
เพื่อแสดงนัยเชิงเศรษฐศาสตร์ของแบบจำลองราคาข้างต้น ส่วนนี้วิเคราะห์ความไว (sensitivity) ของยอดสุทธิที่ผู้ขายได้รับต่อพารามิเตอร์ของโซนและค่าธรรมเนียม โดยเป็นการคำนวณเชิงแบบจำลองล้วน (model-derived) จากสมการ settlement ตาม@eq:clearing และ@eq:net มิใช่การวัดรายได้จากการรันระบบจริง กำหนดราคาเสนอขายฐาน $p_s = 4.00$ บาทต่อ kWh ปริมาณจับคู่ $q = 10$ kWh และตัวคูณจูงใจ $m = 1$ (ตามเส้นทาง CDA จริง) คงที่ แล้วแปรค่าสถานะภายในโซน/ข้ามโซน อัตราค่าธรรมเนียม $phi$ และ loss factor $lambda$ ตาม@tbl:revenue-sensitivity

#figure(
  caption: [Model-derived seller-net sensitivity computed from @eq:clearing and @eq:net at $p_s = 4.00$ ฿/kWh, $q = 10$ kWh, $m = 1$. "net" is the seller's settled amount; wheeling ($w$) and loss ($lambda$) are pass-through to the buyer via the landed price $p^*$.],
  text(size: 8pt)[
    #show math.equation: set text(size: 8pt)
    // Each scenario is computed from the settlement equations — never hand-typed —
    // so the table cannot drift from the model. m = 1 on the CDA path.
    #import "../metrics.typ": pricing
    #let scen(name, lambda, w, delta, phi) = {
      let ps = pricing.ps
      let q = pricing.q
      let closs = ps * (lambda - 1)            // eq:loss-cost
      let pstar = (ps + w + closs) * delta     // eq:clearing (m = 1)
      let value = q * pstar                    // eq:value
      let fee = value * phi / 10000            // eq:fee
      let wheel = q * w
      let loss = q * closs
      let net = value - fee - wheel - loss     // eq:net
      (name, delta, w, lambda, phi, pstar, net, net / q)
    }
    #let rows = (
      scen([S1 ภายในโซน], 1.01, 0.0, 0.95, 25),
      scen([S2 ข้ามโซน], 1.03, 0.02, 1.0, 25),
      scen([S3 ภายในโซน, ค่าธรรมเนียมสูง], 1.01, 0.0, 0.95, 100),
      scen([S4 ข้ามโซน, loss สูง], 1.05, 0.02, 1.0, 25),
    )
    // Guard: S1 must reproduce the worked example in @sec:pricing-model (37.88 ฿).
    #assert(
      calc.round(rows.at(0).at(6), digits: 2) == 37.88,
      message: "revenue table S1 drifted from the worked example (37.88 ฿)",
    )
    #table(
      columns: 8,
      inset: (x: 4pt, y: 3pt),
      align: (left + horizon,) + (center + horizon,) * 7,
      table.header(
        [สถานการณ์], [$delta$], [$w$], [$lambda$], [$phi$ (bps)],
        [$p^*$], [net (฿)], [net/kWh],
      ),
      ..rows.map(r => (
        r.at(0),
        [#calc.round(r.at(1), digits: 2)],
        [#calc.round(r.at(2), digits: 2)],
        [#calc.round(r.at(3), digits: 2)],
        [#calc.round(r.at(4))],
        [#calc.round(r.at(5), digits: 3)],
        [#calc.round(r.at(6), digits: 2)],
        [#calc.round(r.at(7), digits: 2)],
      )).flatten(),
    )
  ],
) <tbl:revenue-sensitivity>

จาก@tbl:revenue-sensitivity เห็นรูปแบบสำคัญสองประการ ประการแรก ยอดสุทธิของผู้ขายแทบไม่เปลี่ยนเมื่อเพิ่มค่าผ่านสาย $w$ หรือ loss factor $lambda$ (เทียบ S2 กับ S4 ที่ต่างกันในระดับเศษสตางค์) เพราะต้นทุนทั้งสองถูกบวกเข้าไปในราคา landed $p^*$ ที่ผู้ซื้อจ่าย แล้วถูกแยกออกไปยังบัญชีผู้เก็บค่าผ่านสายและการสูญเสีย จึงเป็นต้นทุนแบบส่งผ่าน (pass-through) ที่ไม่ลดทอนยอดผู้ขายโดยตรง ผู้ขายจึงได้รับยอดใกล้เคียง $q dot p_s$ เสมอ ประการที่สอง ตัวแปรที่กระทบยอดผู้ขายอย่างมีนัยคือส่วนลดภายในโซน $delta$ และอัตราค่าธรรมเนียม $phi$ โดยการจับคู่ภายในโซน ($delta = 0.95$) ลดยอดผู้ขายลงประมาณ 5% เพื่อจูงใจการบริโภคในพื้นที่ ขณะที่การขึ้นค่าธรรมเนียมจาก 25 เป็น 100 bps (S1 → S3) ลดยอดสุทธิเพียงเล็กน้อย

เมื่อเทียบกับการรับซื้อไฟส่วนเกินแบบอัตราคงที่ (flat feed-in tariff) ของโครงการโซลาร์ภาคประชาชนที่สมมติไว้ราว 2.20 บาทต่อ kWh ยอดสุทธิต่อหน่วยของผู้ขายในตลาด P2P (ประมาณ 3.76–3.99 บาทต่อ kWh) คิดเป็นส่วนเพิ่ม (uplift) ประมาณ 72–81% ขณะเดียวกันผู้ซื้อยังจ่ายราคา landed $p^*$ (ประมาณ 3.84–4.22 บาทต่อ kWh) ต่ำกว่าค่าไฟขายปลีกตามปกติ จึงเกิดส่วนเกินจากการซื้อขาย (gains from trade) ทั้งสองฝั่ง ทั้งนี้อัตรารับซื้อ 2.20 บาทเป็นเพียงค่าอ้างอิงเชิงสมมติเพื่อการเปรียบเทียบ มิใช่ค่าที่วัดจากตลาดจริง

ข้อจำกัดของการวิเคราะห์นี้คือ ตัวเลขใน@tbl:revenue-sensitivity เป็นผลเชิงแบบจำลองภายใต้พารามิเตอร์คงที่และปริมาณจับคู่เดียว (10 kWh) อีกทั้งการคำนวณจริงในโค้ดใช้เลขทศนิยมตายตัวแบบปัดลง ค่าที่ได้จึงอาจต่างในระดับเศษปัด และยังไม่ใช่การวัดการกระจายของรายได้ (revenue distribution) บนภาระงานจำลองเต็มรูปแบบ ซึ่งเปิดไว้เป็นงานในอนาคต (ดู@sec:discussion_limitations)

== Continuous Double Auction Matching <sec:cda-matching>
กลไกตลาดใช้การจับคู่แบบ Continuous Double Auction (CDA) ที่จัดลำดับตามหลัก price-time priority และคำนึงถึงข้อจำกัดเชิงโทโพโลยีของโครงข่ายไฟฟ้า คำสั่งขายถูกแบ่งสมุดคำสั่ง (order book) ตามโซนแบบ zone-segmented โดยแต่ละโซนเก็บคำสั่งขายในโครงสร้างเรียงลำดับ (BTreeMap) ด้วยกุญแจ `(price, created_at, id)` ทำให้ลำดับของกุญแจให้ความสำคัญกับราคาต่ำสุดก่อน แล้วจึงเป็นเวลาสร้างคำสั่งที่เก่ากว่า และใช้ order id เป็นตัวตัดสินขั้นสุดท้าย จึงได้ price-time priority โดยปริยายโดยไม่ต้องเรียงลำดับซ้ำ คำสั่งที่เหลือปริมาณต่ำกว่าเกณฑ์ขั้นต่ำ (MIN_TRADE_AMOUNT) หรือหมดอายุแล้วจะไม่ถูกใส่ในสมุด

สำหรับคำสั่งซื้อแต่ละรายการ เครื่องจับคู่รวบรวมผู้ขายที่เป็นผู้สมัคร (candidate) จากเฉพาะโซนที่โครงข่ายสามารถส่งพลังงานถึงโซนของผู้ซื้อได้ ผ่านการตรวจ topology pre-filtering สองชั้น คือชั้นแรกตรวจที่ปริมาณขั้นต่ำเพื่อตัดโซนที่ส่งถึงกันไม่ได้ออกทันที และชั้นที่สองตรวจซ้ำที่ปริมาณจับคู่จริง (`can_accommodate_flow(sell_zone, buy_zone, amount)`) เพื่อบังคับเพดานความจุสายส่ง ภายในแต่ละโซนที่เข้าถึงได้ ใช้การสืบค้นช่วง (range query) ดึงเฉพาะคำสั่งขายที่ราคาเสนอไม่เกินราคาเสนอซื้อ แล้วคำนวณ landed cost ตาม@eq:clearing (รวม wheeling, ต้นทุน loss, ตัวคูณ และส่วนลดภายในโซน $delta = 0.95$) คำสั่งขายที่มี landed cost ไม่เกินราคาเสนอซื้อ ($p^* <= p_b$) เท่านั้นที่ผ่านเข้าเป็น candidate ระบบป้องกันการจับคู่กับตนเอง (self-trade) โดยข้ามคู่ที่ผู้ซื้อและผู้ขายเป็นผู้ใช้รายเดียวกัน

เมื่อได้ candidate จากทุกโซนที่เข้าถึงได้ ระบบรวมรายการแล้วเรียงตาม landed cost จากต่ำไปสูง เพื่อให้ผู้ซื้อได้ราคารวมส่งถึง (landed) ที่ถูกที่สุดก่อน ไม่ว่าคำสั่งขายนั้นจะอยู่โซนใด จากนั้นทยอยจับคู่โดยปริมาณต่อคู่เท่ากับส่วนเหลือที่น้อยกว่าของสองฝั่ง ($q = min(q_b, q_s)$) แบบ partial-fill และตัดคำสั่งขายที่ปริมาณเหลือต่ำกว่าเกณฑ์ออกจากสมุดทันที กรณีคำสั่งซื้อแบบ Fill-or-Kill (FOK) ระบบจะตรวจก่อนว่าปริมาณรวมของ candidate เพียงพอต่อทั้งคำสั่ง หากไม่พอจะไม่จับคู่เลย นอกจากนี้มีการรวมผลลัพธ์ (match consolidation) เมื่อคู่ผู้ซื้อ-ผู้ขายและราคาเดียวกันต่อเนื่องกัน เพื่อลดจำนวนรายการ settlement ที่ต้องส่งขึ้นเชน ผลการจับคู่แต่ละรายการบันทึก match price (landed cost), wheeling charge, loss cost และโซนต้นทาง/ปลายทาง ก่อนส่งคู่ที่จับแล้วไปชำระแบบ atomic ตาม@sec:settlement-model ต้นทุนการประมวลผลบนเชนของเส้นทาง settlement ที่เครื่องจับคู่ป้อนเข้ารายงานใน@sec:settlement-cost ส่วนอัตราการจับคู่ (matching throughput) ของเครื่องจับคู่ในชั้นหน่วยความจำรายงานใน@sec:matching-throughput
