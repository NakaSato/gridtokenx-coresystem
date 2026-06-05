= Security Analysis and Provenance (การวิเคราะห์ความปลอดภัยและแหล่งที่มา)

GridTokenX implements a "Defense-in-Depth" security strategy across all layers of the stack. This section provides a comprehensive analysis of the threat model, attack vectors, and corresponding mitigations.
GridTokenX นำกลยุทธ์ความปลอดภัยแบบ "Defense-in-Depth" (การป้องกันในเชิงลึก) มาใช้ในทุกชั้นของระบบ ส่วนนี้จะนำเสนอการวิเคราะห์แบบจำลองภัยคุกคาม เวกเตอร์การโจมตี และการบรรเทาผลกระทบที่สอดคล้องกันอย่างครอบคลุม

== Threat Model (แบบจำลองภัยคุกคาม)

The platform's threat model considers four categories of adversaries:
แบบจำลองภัยคุกคามของแพลตฟอร์มพิจารณาผู้ไม่ประสงค์ดีเป็นสี่ประเภท:

*External Attackers* (ผู้โจมตีภายนอก): Malicious actors with no privileged access attempting to exploit network-facing services, smart contracts, or the blockchain layer.
ผู้ไม่ประสงค์ดีที่ไม่มีสิทธิ์การเข้าถึงพิเศษ ซึ่งพยายามหาช่องโหว่จากบริการที่เชื่อมต่อกับเครือข่าย, สัญญาอัจฉริยะ (smart contracts), หรือในชั้นของบล็อกเชน

*Compromised Devices* (อุปกรณ์ที่ถูกแทรกแซง): Edge Gateways or smart meters that have been physically tampered with or whose software has been compromised.
เอดจ์เกตเวย์ (Edge Gateways) หรือสมาร์ทมิเตอร์ที่ถูกดัดแปลงทางกายภาพ หรืออุปกรณ์ที่ซอฟต์แวร์ถูกเจาะระบบ

*Malicious Insiders* (คนในที่ไม่ประสงค์ดี): Platform operators or service accounts attempting to manipulate market data, steal user funds, or issue fraudulent tokens.
ผู้ดูแลแพลตฟอร์มหรือบัญชีบริการที่พยายามบิดเบือนข้อมูลตลาด ขโมยเงินของผู้ใช้ หรือออกโทเคนปลอม

*Economic Attackers* (ผู้โจมตีทางเศรษฐศาสตร์): Sophisticated actors attempting to manipulate market prices, exploit smart contract logic, or destabilize the gTHB peg through large-scale coordinated trading.
ผู้ไม่ประสงค์ดีที่มีความเชี่ยวชาญสูง ซึ่งพยายามบิดเบือนราคาตลาด หาช่องโหว่จากตรรกะของสัญญาอัจฉริยะ หรือทำให้การผูกมูลค่าของ gTHB ขาดเสถียรภาพผ่านการประสานงานการซื้อขายในระดับสเกลขนาดใหญ่

== Layer 1: Physical and Edge Security (ความปลอดภัยทางกายภาพและระดับเอดจ์)

=== Hardware Tamper Protection (การป้องกันการดัดแปลงฮาร์ดแวร์)

Edge Gateways are housed in tamper-evident enclosures with physical intrusion detection sensors. Upon detection of physical tampering:
เอดจ์เกตเวย์ถูกบรรจุอยู่ในเคสที่มีระบบป้องกันการงัดแงะ (tamper-evident enclosures) พร้อมเซ็นเซอร์ตรวจจับการบุกรุกทางกายภาพ เมื่อตรวจพบการดัดแปลงทางกายภาพ:
1. The HSM immediately zeroizes all stored private keys.
   HSM จะลบกุญแจส่วนตัวที่เก็บไว้ทั้งหมดทิ้งให้กลายเป็นศูนย์โดยทันที
2. The gateway transmits a tamper alert to the platform's device management service.
   เกตเวย์จะส่งการแจ้งเตือนการงัดแงะไปยังบริการจัดการอุปกรณ์ของแพลตฟอร์ม
3. The device's certificate is revoked via OCSP, preventing further data submission.
   ใบรับรองของอุปกรณ์จะถูกเพิกถอนผ่าน OCSP เพื่อป้องกันการส่งข้อมูลเพิ่มเติม
4. The IAM Service flags the associated prosumer account for manual review.
   บริการ IAM จะติดธงเตือนบัญชีผู้ผลิตและผู้บริโภค (prosumer) ที่เกี่ยวข้อง เพื่อให้ทำการตรวจสอบด้วยตนเอง

This ensures that even if an attacker gains physical access to a gateway, they cannot extract the signing key or submit fraudulent readings using the device's identity.
สิ่งนี้ทำให้มั่นใจได้ว่าแม้ผู้โจมตีจะสามารถเข้าถึงเกตเวย์ทางกายภาพได้ แต่ก็ไม่สามารถดึงกุญแจสำหรับการลงนาม (signing key) หรือส่งข้อมูลการอ่านมิเตอร์ปลอมแปลงโดยใช้ข้อมูลระบุตัวตนของอุปกรณ์ได้

=== Anomaly Detection (การตรวจจับความผิดปกติ)

The Oracle Bridge implements statistical anomaly detection for incoming telemetry:
ออราเคิลบริดจ์ (Oracle Bridge) ใช้ระบบตรวจจับความผิดปกติทางสถิติสำหรับข้อมูลโทรมาตร (telemetry) ที่เข้ามา:
- *Capacity Bounds Check* (การตรวจสอบขีดจำกัดความจุ): Readings exceeding 110% of the device's rated capacity are flagged and quarantined for manual review.
  การอ่านค่าที่เกิน 110% ของความจุพิกัดอุปกรณ์จะถูกติดธงเตือนและกักกันไว้เพื่อรอการตรวจสอบด้วยตนเอง
- *Temporal Consistency Check* (การตรวจสอบความสอดคล้องตามเวลา): Energy readings must be monotonically increasing (for cumulative meters). Decreasing readings indicate meter tampering or rollover.
  ค่าการอ่านพลังงานต้องเพิ่มขึ้นตามลำดับอย่างต่อเนื่อง (สำหรับมิเตอร์แบบสะสม) การอ่านค่าที่ลดลงบ่งบอกถึงการดัดแปลงมิเตอร์หรือการรีเซ็ตตัวเลข
- *Peer Comparison* (การเปรียบเทียบกับอุปกรณ์ใกล้เคียง): Readings from a device are compared against neighboring devices in the same zone. Significant deviations (>3σ from zone average) trigger an alert.
  ข้อมูลที่อ่านได้จากอุปกรณ์จะถูกนำไปเปรียบเทียบกับอุปกรณ์ที่อยู่ใกล้เคียงในโซนเดียวกัน ความเบี่ยงเบนที่สูงอย่างมีนัยสำคัญ (>3σ จากค่าเฉลี่ยของโซน) จะทำให้เกิดการแจ้งเตือน
- *Velocity Check* (การตรวจสอบอัตราความเร็ว): Sudden spikes in generation (e.g., 10× normal output) are flagged as potentially fraudulent.
  การพุ่งสูงขึ้นอย่างฉับพลันในการผลิตพลังงาน (เช่น 10 เท่าของผลผลิตปกติ) จะถูกติดธงเตือนว่าอาจเป็นการฉ้อโกง

Flagged readings are not published to Kafka and do not trigger token minting until cleared by a human reviewer or automated re-validation.
ข้อมูลที่มีการแจ้งเตือนจะไม่ถูกเผยแพร่ไปยัง Kafka และจะไม่กระตุ้นให้เกิดการออกโทเคน (minting) จนกว่าจะผ่านการตรวจสอบจากผู้ดูแลหรือการตรวจสอบซ้ำโดยระบบอัตโนมัติ

== Layer 2: Network and Transport Security (ความปลอดภัยระดับเครือข่ายและการรับส่งข้อมูล)

=== mTLS Everywhere (การใช้ mTLS ในทุกจุด)

All network communication within the GridTokenX platform uses mutual TLS (mTLS):
การสื่อสารผ่านเครือข่ายทั้งหมดภายในแพลตฟอร์ม GridTokenX ใช้ mutual TLS (mTLS):
- *Edge-to-Cloud*: Edge Gateways authenticate with client certificates issued by the platform CA.
  *เอดจ์สู่คลาวด์*: เอดจ์เกตเวย์จะยืนยันตัวตนด้วยใบรับรองไคลเอ็นต์ที่ออกโดยผู้ให้บริการออกใบรับรอง (CA) ของแพลตฟอร์ม
- *Service-to-Service*: All microservices authenticate with service certificates managed by cert-manager and rotated every 90 days.
  *บริการสู่บริการ*: ไมโครเซอร์วิสทั้งหมดจะยืนยันตัวตนด้วยใบรับรองบริการที่จัดการโดย cert-manager และจะถูกหมุนเวียน (rotated) ทุกๆ 90 วัน
- *External APIs*: Public-facing APIs use standard TLS with certificate pinning in the mobile application.
  *API ภายนอก*: API สำหรับการใช้งานสาธารณะจะใช้ TLS มาตรฐานร่วมกับเทคนิค certificate pinning ในแอปพลิเคชันบนมือถือ

=== DDoS Protection (การป้องกัน DDoS)

The Envoy Proxy ingress implements rate limiting at multiple levels:
ตัวเชื่อมต่อ (ingress) ของ Envoy Proxy จะทำการจำกัดอัตราการส่งข้อมูล (rate limiting) ในหลายระดับ:
- *Per-Device Rate Limit*: Maximum 1 telemetry submission per 30 seconds per device (configurable per device type).
  *จำกัดอัตราต่ออุปกรณ์*: อนุญาตให้ส่งข้อมูลโทรมาตรได้สูงสุด 1 ครั้งต่อ 30 วินาทีต่ออุปกรณ์ (สามารถกำหนดค่าได้ตามประเภทของอุปกรณ์)
- *Per-IP Rate Limit*: Maximum 100 requests per second per source IP.
  *จำกัดอัตราต่อไอพี*: อนุญาตคำขอสูงสุด 100 คำขอต่อวินาทีต่อที่อยู่ไอพีต้นทาง
- *Global Rate Limit*: Circuit breaker that activates if total ingress exceeds 10,000 requests per second, protecting downstream services.
  *จำกัดอัตรารวม*: ระบบตัดการทำงาน (Circuit breaker) จะเริ่มทำงานเมื่อปริมาณการเข้าถึงทั้งหมดเกิน 10,000 คำขอต่อวินาที เพื่อป้องกันบริการปลายทาง (downstream services)

=== Network Segmentation (การแบ่งส่วนเครือข่าย)

The platform is deployed in a Kubernetes cluster with strict NetworkPolicy rules:
แพลตฟอร์มถูกติดตั้งบนคลัสเตอร์ Kubernetes โดยใช้กฎนโยบายเครือข่าย (NetworkPolicy) ที่เข้มงวด:
- Edge-facing services (Envoy Proxy, Oracle Bridge) are isolated in a dedicated namespace with no direct access to the database tier.
  บริการที่เชื่อมต่อกับส่วนเอดจ์ (Envoy Proxy, Oracle Bridge) จะถูกแยกไว้ใน namespace เฉพาะ ซึ่งไม่มีสิทธิ์การเข้าถึงชั้นฐานข้อมูลโดยตรง
- The Chain Bridge has no inbound network access — it only makes outbound connections to Solana RPC nodes and HashiCorp Vault.
  เชนบริดจ์ (Chain Bridge) ไม่มีการเข้าถึงเครือข่ายขาเข้า โดยจะทำการเชื่อมต่อขาออกไปยังโหนด Solana RPC และ HashiCorp Vault เท่านั้น
- Database services are accessible only from their designated application services.
  บริการฐานข้อมูลสามารถเข้าถึงได้จากแอปพลิเคชันที่ได้รับมอบหมายเท่านั้น

== Layer 3: Application and Smart Contract Security (ความปลอดภัยระดับแอปพลิเคชันและสัญญาอัจฉริยะ)

=== Ed25519 Cross-Instruction Verification (การตรวจสอบความถูกต้องข้ามคำสั่ง Ed25519)

The most critical security mechanism in the on-chain settlement layer is the use of Solana's `instructions` sysvar for cross-instruction Ed25519 signature verification. This prevents unauthorized settlement in the following way:
กลไกความปลอดภัยที่สำคัญที่สุดในระดับการชำระราคาบนเชน (on-chain settlement layer) คือการใช้ sysvar ที่ชื่อว่า `instructions` ของ Solana เพื่อตรวจสอบลายเซ็น Ed25519 ข้ามคำสั่ง ซึ่งสิ่งนี้จะป้องกันการชำระราคาที่ไม่ได้รับอนุญาตดังต่อไปนี้:

When the Chain Bridge constructs a `match_orders` transaction, it prepends an `Ed25519Program.createInstructionWithPublicKey` instruction for each order being settled. This instruction verifies that the order payload (containing order ID, price, quantity, and expiry) was signed by the order creator's private key.
เมื่อเชนบริดจ์สร้างธุรกรรม `match_orders` มันจะแทรกคำสั่ง `Ed25519Program.createInstructionWithPublicKey` ไว้ด้านหน้าสำหรับแต่ละคำสั่งซื้อขายที่กำลังถูกชำระ คำสั่งนี้ทำหน้าที่ตรวจสอบว่าข้อมูลเพย์โหลด (ประกอบด้วยรหัสคำสั่งซื้อขาย, ราคา, ปริมาณ และวันหมดอายุ) ได้รับการลงนามด้วยกุญแจส่วนตัวของผู้สร้างคำสั่งนั้นแล้ว

The `match_orders` instruction then reads the `instructions` sysvar to confirm that the required Ed25519 verification instructions are present and that the verified public keys match the order creators' registered wallet addresses. If any verification is missing or fails, the entire transaction is rejected.
หลังจากนั้นคำสั่ง `match_orders` จะอ่าน sysvar `instructions` เพื่อยืนยันว่ามีคำสั่งตรวจสอบ Ed25519 ที่จำเป็นอยู่ครบ และกุญแจสาธารณะที่ถูกตรวจสอบตรงกับที่อยู่กระเป๋าเงิน (wallet addresses) ของผู้สร้างคำสั่งที่ลงทะเบียนไว้ หากการตรวจสอบใดขาดหายไปหรือล้มเหลว ธุรกรรมทั้งหมดจะถูกปฏิเสธ

This mechanism ensures that:
กลไกนี้ทำให้มั่นใจได้ว่า:
1. Only the legitimate order creator can authorize settlement of their order.
   เฉพาะผู้สร้างคำสั่งซื้อขายที่ถูกต้องเท่านั้นที่สามารถอนุมัติการชำระราคาของคำสั่งซื้อขายของตนได้
2. The order parameters cannot be modified between signing and settlement.
   ตัวแปรของคำสั่งซื้อขายไม่สามารถถูกปรับเปลี่ยนได้ระหว่างกระบวนการลงนามและการชำระราคา
3. A compromised Chain Bridge cannot settle orders without valid user signatures.
   เชนบริดจ์ที่ถูกเจาะระบบไม่สามารถดำเนินการชำระราคาสำหรับคำสั่งที่ปราศจากลายเซ็นผู้ใช้ที่ถูกต้อง

=== Nullifier-Based Replay Protection (การป้องกันการทำซ้ำโดยใช้ Nullifier)

Every settled order generates a `Nullifier` PDA with the order UUID as the seed. The `match_orders` instruction checks for the existence of this PDA before processing. If the PDA already exists, the instruction returns a `OrderAlreadySettled` error.
ทุกๆ คำสั่งซื้อขายที่ชำระราคาเสร็จสิ้นแล้ว จะสร้าง PDA ที่เรียกว่า `Nullifier` โดยใช้ UUID ของคำสั่งเป็นเมล็ด (seed) คำสั่ง `match_orders` จะตรวจสอบการมีอยู่ของ PDA นี้ก่อนการประมวลผล หากพบว่า PDA มีอยู่แล้ว คำสั่งดังกล่าวจะส่งคืนข้อผิดพลาด `OrderAlreadySettled`

This prevents replay attacks where an attacker captures a valid settlement transaction and rebroadcasts it to drain funds. Even if the same signed order payload is submitted multiple times, only the first settlement succeeds.
สิ่งนี้ช่วยป้องกันการโจมตีแบบ Replay Attack ซึ่งผู้โจมตีอาจจับข้อมูลธุรกรรมการชำระที่ถูกต้องและทำการเผยแพร่ซ้ำเพื่อดึงเงินทุน แม้จะมีการส่งเพย์โหลดคำสั่งที่มีการลงนามชุดเดียวกันหลายครั้ง จะมีเพียงการชำระราคาครั้งแรกเท่านั้นที่สำเร็จ

=== Smart Contract Audit Trail (การตรวจสอบสัญญาอัจฉริยะ)

All on-chain programs have undergone independent security audits by recognized Solana security firms. Audit reports are published publicly and referenced on-chain via IPFS content hashes stored in the `ProtocolConfig` PDA. The platform maintains a bug bounty program with rewards up to \$500,000 for critical vulnerabilities.
โปรแกรมบนเชน (on-chain programs) ทั้งหมดได้ผ่านการตรวจสอบความปลอดภัยอย่างอิสระโดยบริษัทรักษาความปลอดภัยของ Solana ที่ได้รับการยอมรับ รายงานการตรวจสอบจะถูกเผยแพร่สู่สาธารณะและอ้างอิงบนเชนผ่านแฮชข้อมูล (content hashes) ของ IPFS ที่เก็บไว้ใน `ProtocolConfig` PDA แพลตฟอร์มยังคงดำเนินโครงการเงินรางวัลค้นหาช่องโหว่ (bug bounty) ที่มีรางวัลสูงถึง \$500,000 สำหรับช่องโหว่ระดับวิกฤต

=== Integer Overflow Protection (การป้องกัน Integer Overflow)

All arithmetic in on-chain programs uses Rust's checked arithmetic operations (`checked_add`, `checked_mul`, `checked_div`). Any overflow or underflow returns an error rather than wrapping, preventing economic exploits based on integer overflow.
การดำเนินการทางคณิตศาสตร์ทั้งหมดในโปรแกรมบนเชนจะใช้การตรวจสอบข้อผิดพลาด (checked arithmetic operations) ของภาษา Rust (`checked_add`, `checked_mul`, `checked_div`) กรณีใดๆ ที่เกิด overflow หรือ underflow จะส่งคืนข้อผิดพลาดแทนที่จะเป็นการวนรอบค่า (wrapping) เพื่อป้องกันการหาผลประโยชน์ทางเศรษฐกิจจากข้อบกพร่องประเภท integer overflow

=== Account Validation (การตรวจสอบบัญชี)

Every instruction handler validates all input accounts using Anchor's constraint system:
ตัวจัดการคำสั่งแต่ละตัวจะตรวจสอบความถูกต้องของบัญชีนำเข้าข้อมูลทั้งหมด โดยใช้ระบบข้อจำกัด (constraint system) ของ Anchor:
```rust
#[account(
    mut,
    seeds = [b"meter_state", device_id.as_ref()],
    bump = meter_state.bump,
    constraint = meter_state.device_id == device_id @ ErrorCode::DeviceMismatch,
)]
pub meter_state: AccountLoader<'info, MeterState>,
```

This prevents account substitution attacks where an attacker passes a malicious account in place of a legitimate one.
สิ่งนี้ป้องกันการโจมตีโดยการสลับเปลี่ยนบัญชี (account substitution attacks) ซึ่งผู้โจมตีอาจใส่บัญชีประสงค์ร้ายเข้ามาแทนที่บัญชีที่ถูกต้อง

== Layer 4: Key Management and HSM Security (การจัดการกุญแจและระบบความปลอดภัย HSM)

=== HashiCorp Vault Architecture (สถาปัตยกรรม HashiCorp Vault)

The platform's cryptographic key management is centralized in HashiCorp Vault, deployed in a high-availability configuration across three availability zones:
การจัดการกุญแจเข้ารหัสลับ (cryptographic key management) ของแพลตฟอร์มจะถูกรวมศูนย์ไว้ที่ HashiCorp Vault ซึ่งติดตั้งอยู่ในโครงร่างการทำงานแบบความพร้อมใช้งานสูง (high-availability configuration) กระจายอยู่ใน 3 พื้นที่จัดเก็บ (availability zones):

- *Solana Operator Key* (กุญแจผู้ดำเนินการ Solana): Stored in Vault's Transit Secrets Engine. The Chain Bridge requests signatures via the Transit API — the private key never leaves Vault.
  จัดเก็บไว้ใน Transit Secrets Engine ของ Vault เชนบริดจ์จะขอรับลายเซ็นผ่าน Transit API — กุญแจส่วนตัวจะไม่มีวันออกจาก Vault
- *gTHB Multisig Keys* (กุญแจ Multisig ของ gTHB): Each of the 5 multisig participants holds their key in a separate Vault instance or hardware HSM. Signing requires 5 independent API calls to 5 separate Vault instances.
  ผู้มีส่วนร่วมใน multisig ทั้ง 5 คน แต่ละคนจะเก็บกุญแจของตนไว้ในอินสแตนซ์ของ Vault ที่แยกจากกัน หรือในระบบฮาร์ดแวร์ HSM การลงนามจำเป็นต้องใช้การเรียก API แบบอิสระจำนวน 5 ครั้ง ไปยัง 5 อินสแตนซ์ Vault ที่แยกกัน
- *TLS Certificates* (ใบรับรอง TLS): Managed by Vault's PKI Secrets Engine, with automatic rotation.
  จัดการโดย PKI Secrets Engine ของ Vault พร้อมด้วยการหมุนเวียนเปลี่ยนค่าโดยอัตโนมัติ
- *Database Credentials* (ข้อมูลรับรองฐานข้อมูล): Managed by Vault's Database Secrets Engine, with dynamic credential generation and automatic rotation every 24 hours.
  จัดการโดย Database Secrets Engine ของ Vault โดยมีการสร้างข้อมูลรับรองแบบไดนามิกและหมุนเวียนใหม่โดยอัตโนมัติทุกๆ 24 ชั่วโมง

=== gTHB Multisig Security (ความปลอดภัย gTHB Multisig)

The gTHB stablecoin's mint and burn operations currently require a 5-of-9 multisig. The 9 signers are:
ปฏิบัติการออก (mint) และทำลาย (burn) เหรียญสเตเบิลคอยน์ gTHB ในปัจจุบันต้องอาศัยการลงนามแบบ 5-of-9 multisig โดยผู้ลงนามทั้ง 9 คนประกอบด้วย:
- 3 GridTokenX team members (geographically distributed)
  สมาชิกทีม GridTokenX 3 คน (กระจายตามพื้นที่ภูมิศาสตร์)
- 3 independent board members
  สมาชิกคณะกรรมการอิสระ 3 คน
- 3 institutional custodians
  ผู้ดูแลรับฝากทรัพย์สินสถาบัน (institutional custodians) 3 คน

Each signer holds their key in a hardware HSM. While this arrangement provides strong security guarantees, it introduces a latency bottleneck that is architecturally inconsistent with the sub-400ms settlement finality achieved elsewhere in the stack: coordinating 5 independent signers across time zones imposes delays of minutes to hours, and large-volume mints have historically required synchronous coordination ceremonies.
ผู้ลงนามแต่ละคนจะเก็บกุญแจของตนไว้ในฮาร์ดแวร์ HSM แม้ว่าการจัดเตรียมนี้จะให้การรับประกันความปลอดภัยที่แข็งแกร่ง แต่ก็ทำให้เกิดปัญหาคอขวดในด้านความล่าช้า (latency) ซึ่งไม่สอดคล้องกับสถาปัตยกรรมของการชำระราคาสุดท้ายที่ต่ำกว่า 400 มิลลิวินาที ที่สำเร็จในชั้นส่วนอื่นๆ ของระบบ: การประสานงานผู้ลงนาม 5 คนซึ่งอยู่ในเขตเวลาที่ต่างกันทำให้เกิดความล่าช้าเป็นนาทีจนถึงชั่วโมง และการออกโทเคนในปริมาณมากจำเป็นต้องมีพิธีการประสานงานแบบซิงโครนัสเสมอมา

*Planned Improvement — Programmable MPC Custody* (การปรับปรุงที่วางแผนไว้ — ระบบการดูแลโดยใช้ Programmable MPC): The roadmap targets replacing the static multisig with a threshold Multi-Party Computation (MPC) signing pipeline. Under this model, signing shares are held by geographically distributed nodes running a threshold signature scheme (e.g., FROST or GG20). Routine mints below a configurable threshold (e.g., 1,000,000 gTHB) are processed fully automatically once bank deposit confirmation and KYC/AML checks pass, with no human coordination required. Large institutional mints above the threshold trigger an asynchronous approval workflow where signers respond via authenticated mobile push rather than in-person ceremony. Reserve attestations remain continuous and on-chain regardless of mint size, preserving auditability while eliminating the synchronous bottleneck.
แผนงานที่ตั้งเป้าไว้คือการแทนที่กระบวนการ multisig แบบเดิมด้วยขั้นตอนการลงนามที่ใช้เทคโนโลยี Multi-Party Computation (MPC) ภายใต้เกณฑ์กำหนด ในแบบจำลองนี้ ส่วนแบ่งของการลงนาม (signing shares) จะถูกเก็บรักษาโดยโหนด (nodes) ที่กระจายอยู่ตามพื้นที่ต่างๆ และทำงานตามโครงการลายเซ็นแบบเกณฑ์กำหนด (threshold signature scheme) เช่น FROST หรือ GG20 สำหรับการออกโทเคนตามปกติที่มีจำนวนต่ำกว่าเกณฑ์ที่กำหนดได้ (เช่น 1,000,000 gTHB) ระบบจะประมวลผลโดยอัตโนมัติทั้งหมดทันทีที่การฝากเงินผ่านธนาคารได้รับการยืนยันและการตรวจสอบ KYC/AML ผ่าน โดยไม่ต้องใช้มนุษย์มาประสานงาน การออกโทเคนปริมาณมากให้กับสถาบันที่เกินกว่าเกณฑ์กำหนดจะสั่งการทำงานขั้นตอนการอนุมัติแบบอะซิงโครนัส ซึ่งผู้ลงนามสามารถตอบสนองผ่านการแจ้งเตือน (mobile push) ที่ผ่านการยืนยันตัวตน แทนที่จะต้องมารวมตัวกัน การพิสูจน์ยืนยันทุนสำรอง (reserve attestations) จะคงอยู่อย่างต่อเนื่องและอยู่บนเชน ไม่ว่าปริมาณการออกโทเคนจะมากแค่ไหน ทำให้ยังคงการตรวจสอบได้และขจัดปัญหาคอขวดแบบซิงโครนัสไปในเวลาเดียวกัน

== Layer 5: Monitoring and Incident Response (การตรวจสอบและตอบสนองต่อเหตุการณ์)

=== Real-Time Security Monitoring (การตรวจสอบความปลอดภัยแบบเรียลไทม์)

The platform operates a 24/7 Security Operations Center (SOC) with:
แพลตฟอร์มมีการดำเนินการศูนย์ปฏิบัติการความปลอดภัย (SOC) ตลอด 24 ชั่วโมงในทุกวัน โดยมี:
- *On-Chain Monitoring* (การตรวจสอบบนเชน): Automated alerts for unusual transaction patterns (e.g., large single-block settlements, unusual account drains).
  การแจ้งเตือนอัตโนมัติสำหรับรูปแบบธุรกรรมที่ผิดปกติ (เช่น การชำระราคาจำนวนมากภายในบล็อกเดียว, การดึงเงินออกจากบัญชีผิดปกติ)
- *Off-Chain Monitoring* (การตรวจสอบนอกเชน): SIEM integration with alerts for failed authentication attempts, anomalous API access patterns, and infrastructure anomalies.
  การทำงานร่วมกับระบบ SIEM พร้อมการแจ้งเตือนสำหรับความพยายามยืนยันตัวตนที่ล้มเหลว, รูปแบบการเข้าถึง API ที่ผิดปกติ และความผิดปกติของโครงสร้างพื้นฐาน
- *Smart Contract Event Monitoring* (การตรวจสอบเหตุการณ์สัญญาอัจฉริยะ): All on-chain events are indexed and monitored for anomalies using a dedicated blockchain analytics service.
  เหตุการณ์ทั้งหมดบนเชนจะถูกจัดทำดัชนีและตรวจสอบหาความผิดปกติโดยใช้บริการวิเคราะห์บล็อกเชนโดยเฉพาะ

=== Incident Response (การตอบสนองต่อเหตุการณ์ฉุกเฉิน)

The platform maintains a documented incident response plan with defined severity levels and response times:
แพลตฟอร์มมีเอกสารแผนการตอบสนองต่อเหตุการณ์ฉุกเฉิน ซึ่งได้กำหนดระดับความรุนแรงและระยะเวลาการตอบสนองไว้:
- *Critical (P0)* (วิกฤต (P0)): Active fund drain or peg break. Response time: 15 minutes. Actions: Emergency circuit breaker activation, multisig freeze.
  เหตุการณ์ดึงเงินทุนที่เกิดขึ้นอยู่จริง หรืออัตราตรึงมูลค่าเสียไป เวลาการตอบสนอง: 15 นาที การดำเนินการ: เปิดใช้งานระบบตัดการทำงานฉุกเฉิน, อายัดบัญชี multisig
- *High (P1)* (สูง (P1)): Confirmed vulnerability with no active exploit. Response time: 4 hours. Actions: Coordinated disclosure, patch deployment.
  มีการยืนยันช่องโหว่แต่ยังไม่มีการโจมตีใช้งาน เวลาการตอบสนอง: 4 ชั่วโมง การดำเนินการ: ประสานงานการเปิดเผยข้อมูลอย่างเป็นระบบ และการติดตั้งแพตช์ (patch deployment)
- *Medium (P2)* (ปานกลาง (P2)): Anomalous behavior under investigation. Response time: 24 hours.
  พฤติกรรมผิดปกติที่อยู่ระหว่างการสืบสวน เวลาการตอบสนอง: 24 ชั่วโมง
