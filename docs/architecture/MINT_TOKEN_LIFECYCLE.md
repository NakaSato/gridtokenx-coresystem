# Token Minting Lifecycle: Protocol & Data Flow

This document details the specific technical protocols and data flows required to transition from a physical energy generation event to a minted **Energy Token** on the Solana blockchain.

## Minting Lifecycle Diagram

```mermaid
graph TD
    subgraph "Physical Domain (IoT)"
        Meter[Smart Meter Simulator] --
        Edge -- "Ed25519 Signed JSON / mTLS" --> Envoy[Envoy Proxy :4002]
    end

    subgraph "Validation Domain (Oracle)"
        Envoy -- "HTTP/2 (gRPC)" --> Oracle[Oracle Bridge]
        Oracle -- "Signature & Zone Verification" --> Kafka{Kafka: telemetry}
    end

    subgraph "Logic Domain (Trading)"
        Kafka -- "Avro/JSON Event" --> Trading[Trading Service]
        Trading -- "VPP Aggregation (15m window)" --> Settlement[Settlement Logic]
    end

    subgraph "Execution Domain (Chain)"
        Settlement -- "ConnectRPC (gRPC)" --> Bridge[Chain Bridge]
        Bridge -- "Transit Sign Request" --> Vault[HashiCorp Vault]
        Vault -- "Ed25519 Signature" --> Bridge
        Bridge -- "JSON-RPC (HTTPS)" --> Solana[Solana Validator]
    end

    subgraph "On-Chain (Solana)"
        Solana -- "Invoke MintTo" --> SPL[SPL-2022 Energy Token]
        SPL -- "Balance Updated" --> Wallet[Prosumer Wallet]
    end

    style Meter fill:#f9f,stroke:#333
    style Edge fill:#f9f,stroke:#333
    style Oracle fill:#bbf,stroke:#333
    style Trading fill:#bbf,stroke:#333
    style Bridge fill:#bbf,stroke:#333
    style Solana fill:#fdd,stroke:#333
    style Wallet fill:#dfd,stroke:#333
```

## Protocol Specifications

| Segment              | Protocol          | Data Format     | Security                     |
| :------------------- | :---------------- | :-------------- | :--------------------------- |
| **Meter → Edge**     | DLMS/COSEM        | Binary (A-XDR)  | Physical / Serial            |
| **Edge → Oracle**    | HTTPS/2 (mTLS)    | Signed JSON     | Ed25519 + Client Certs       |
| **Internal Comms**   | ConnectRPC (gRPC) | Protobuf        | Shared Secret + Role Headers |
| **Oracle → Kafka**   | Kafka Protocol    | Avro            | SASL/SSL                     |
| **Service → Bridge** | ConnectRPC        | Protobuf        | Internal mTLS                |
| **Bridge → Vault**   | REST              | JSON            | AppRole / Token              |
| **Bridge → Solana**  | JSON-RPC          | Binary (Base64) | TLS 1.3                      |

## Detailed Data Flow

### 1. Generation Event (IoT)

A solar inverter or smart meter records energy generation. The **Edge Gateway** packages this into a "Telemetry Reading" object.

- **Protocol**: DLMS/COSEM over TCP or Serial.
- **Action**: Edge Gateway signs the payload hash with its local **Ed25519** private key.

### 2. Trust Validation (Oracle)

The payload is sent to the **Oracle Bridge** via the **Envoy** proxy.

- **Security**: Envoy enforces **mTLS**; the Oracle Bridge verifies the **Ed25519** signature.
- **Integrity**: Oracle checks the `timestamp` (anti-replay) and `meter_id` (registry lookup).

### 3. Proof of Generation (Trading)

The **Trading Service** consumes the validated readings from Kafka.

- **Aggregation**: It waits for a 15-minute window to close. If the aggregated `kilowatt_hours` is > 0, a minting requirement is generated.
- **Logic**: The service calculates the exact number of **Energy Tokens** (usually 1 token = 1 Wh or 1 kWh depending on configuration).

### 4. Signing & Submission (Chain Bridge)

The Trading Service sends a `MintEnergyToken` request to the **Chain Bridge**.

- **Request**: `mint_to: <prosumer_wallet>`, `amount: <aggregated_wh>`, `proof_id: <kafka_offset>`.
- **Signing**: Chain Bridge sends the transaction hash to **HashiCorp Vault**. Vault signs it using the platform's **Mint Authority** key (never exported).

### 5. On-Chain Settlement (Solana)

The signed transaction is broadcast to the Solana cluster.

- **Program**: The **Energy Token Program** (Anchor) executes the `mint_to` instruction.
- **Result**: The Prosumer's balance of **SPL-2022** tokens increases. These tokens can now be sold in the marketplace or used to offset consumption.
