#heading(level: 1)[PRICING AND MARKET MECHANISM] <sec:pricing-market-mechanism>

#heading(level: 2)[Pricing and Settlement Model] <sec:pricing-model>
แบบจำลองราคาของระบบแบ่งเป็นสามส่วน คือ การกำหนดราคาเคลียร์ในกลไก CDA การคำนวณค่าธรรมเนียมและยอดสุทธิในการ settlement และกลไกราคาของโทเคนในชั้น treasury สัญลักษณ์ที่ใช้ในสมการสรุปไว้ใน @tbl:nomenclature

#figure(
  text(size: 8pt)[
    // Override the template's global `show math.equation: set text(size: 10pt)`
    // so symbols match the (smaller) table text instead of staying at 10pt.
    #show math.equation: set text(size: 8pt)
    #table(
    columns: (auto, 1fr),
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

เพื่อให้เห็นภาพการใช้สมการข้างต้น พิจารณาตัวอย่างการจับคู่ภายในโซนเดียวกัน โดยกำหนดราคาเสนอขาย $p_s = 4.00$ บาทต่อ kWh ปริมาณ $q = 10$ kWh และใช้ค่าตั้งต้นภายในโซน ($lambda = 1.01$, $w = 0$, $m = 1$, $delta = 0.95$, $phi = 25$ bps) จาก @eq:loss-cost ได้ $c_("loss") = 4.00(1.01 - 1) = 0.04$ และจาก @eq:clearing ได้ราคาเคลียร์ $p^* = (4.00 + 0 + 0.04) dot 1 dot 0.95 = 3.838$ บาทต่อ kWh ซึ่งจับคู่ได้เมื่อราคาเสนอซื้อ $p_b >= 3.838$ จากนั้นมูลค่ารวม $V = 10 dot 3.838 = 38.38$ บาท ค่าธรรมเนียม $f = 38.38 dot 25 slash 10000 approx 0.096$ บาท ค่าผ่านสายรวม $W = 0$ และต้นทุนการสูญเสียรวม $L = 10 dot 0.04 = 0.40$ บาท ทำให้ยอดสุทธิที่ผู้ขายได้รับเท่ากับ $"net" = 38.38 - 0.096 - 0 - 0.40 approx 37.88$ บาท ทั้งนี้การคำนวณจริงในโค้ดใช้เลขทศนิยมตายตัวแบบปัดลง ค่าที่ได้จึงอาจต่างจากตัวอย่างนี้ในระดับเศษปัด

กลไกราคาของโทเคนในชั้น treasury ครอบคลุมการแลกเปลี่ยนระหว่าง GRX และ THBG stablecoin ที่ตรึงค่ากับเงินบาท โดยใช้อัตรา $r$ (จำนวน GRX atom ต่อ THBG) และค่าธรรมเนียม swap $psi$ (bps)
$ "thbg" &= (g dot r) / 10^9 dot (1 - psi slash 10000) #<eq:swap> \
  g &= ("thbg" dot 10^9) / r #<eq:redeem> $
โดยการ redeem ตาม @eq:redeem ไม่มีค่าธรรมเนียม และการรักษาค่าตรึงใช้เงื่อนไข supply ต่อ reserve แบบ 1:1 คือ $"supply"_("thbg") <= "reserve"_("attested")$ ส่วนรางวัลการ stake ใช้ตัวสะสม (accumulator) แบบ MasterChef โดยรางวัลค้างรับของผู้ stake คำนวณจากจำนวนที่ stake $s$
$ "reward" = s dot A slash 10^12 - "debt" $ <eq:reward>
เมื่อมีการเติมรางวัล $R$ ตัวสะสม $A$ จะถูกปรับเป็น $A <- A + (R dot 10^12) slash s_("total")$ แบบ pro-rata ตามสัดส่วนการ stake และการ slash จะหักจำนวนที่ร้องขอแต่ไม่เกินเงินต้นที่ stake ไว้ (capped ที่ principal) แล้วกระจายคืนสู่ผู้ stake ที่เหลือผ่านตัวสะสมเดียวกัน

ในเส้นทาง CDA ที่ใช้งานจริง ตัวคูณจูงใจถูกตั้งเป็น $m = 1$ กล่าวคือ incentive multiplier มีผลเฉพาะเส้นทาง settlement แบบ feed-in หรือ grid-export มิใช่การจับคู่ CDA นอกจากนี้ค่าตั้งต้นของค่าธรรมเนียมตลาดบนเชน (25 bps) แตกต่างจากค่าตั้งต้นในไฟล์ตั้งค่านอกเชน (50 bps) และพารามิเตอร์โซนในโปรแกรม governance จัดเก็บแบบสเกล ×1000 ขณะที่ผู้บริโภคค่าจริงในชั้น trading ตีความแบบ bps ($slash 10000$) ซึ่งเป็นค่าที่ระบบใช้งานจริง ทั้งนี้การคำนวณในโค้ดใช้เลขทศนิยมตายตัว (fixed-point integer) แบบปัดลง (floor division) และยอดสุทธิถูกจำกัดไม่ให้ติดลบด้วย saturating subtraction ดังนั้นสมการข้างต้นจึงเป็นแบบจำลองเชิงค่าจริงที่อาจต่างจากผลคำนวณจริงในระดับเศษปัด
