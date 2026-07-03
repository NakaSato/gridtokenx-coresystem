//! NTP-synchronized wall-clock time for GridTokenX services.
//!
//! The system previously trusted the host/container OS clock everywhere
//! (`chrono::Utc::now()`), which on a peer-to-peer energy ledger is a real
//! hazard: 15-minute aggregation windows, settlement freshness, Ed25519 reading
//! timestamps and audit hash-chains all assume monotonic, *agreed* wall time.
//! A drifting container clock silently mis-buckets readings and mis-orders
//! settlements.
//!
//! This module makes an external NTP server the **primary** time reference.
//! A background thread polls `time.cloudflare.com` (primary) and
//! `time.google.com` (fallback) over SNTPv4 (RFC 4330), computes the clock
//! offset, and publishes it in an atomic. [`now()`] returns
//! `OS clock + offset`, so callers get NTP-corrected UTC without blocking.
//!
//! ## Design
//!
//! - **Self-contained SNTP client** — no external NTP crate; the 48-byte
//!   request/response is hand-rolled against the kernel UDP stack, so there is
//!   no dependency-resolution or version-churn risk.
//! - **Non-blocking reads** — `now()` is a single atomic load plus an add; the
//!   network poll happens off the hot path on a daemon thread.
//! - **Safe degradation** — if every server is unreachable the offset stays at
//!   its last good value (0 before the first successful sync), so `now()` is
//!   never worse than the old `Utc::now()` behaviour. Failure is logged, not
//!   fatal.
//!
//! ## Usage
//!
//! Call [`init_default`] once at process startup (right after telemetry init),
//! then replace `chrono::Utc::now()` with [`now()`] at wall-clock timestamp
//! sites:
//!
//! ```no_run
//! gridtokenx_telemetry::init("aggregator-bridge");
//! gridtokenx_telemetry::time::init_default();
//! let ts = gridtokenx_telemetry::time::now(); // NTP-corrected DateTime<Utc>
//! ```
//!
//! Env overrides: `NTP_SERVERS` (comma-separated `host:port`),
//! `NTP_POLL_SECS` (poll interval), `NTP_TIMEOUT_MS` (per-query timeout),
//! `NTP_DISABLE=1` (skip sync entirely; `now()` == OS clock).

use std::net::{ToSocketAddrs, UdpSocket};
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::Once;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Utc};

/// Offset to add to the OS clock to obtain NTP time, in milliseconds.
/// `ntp_time = os_time + OFFSET_MILLIS`. Zero until the first successful sync.
static OFFSET_MILLIS: AtomicI64 = AtomicI64::new(0);

/// Whether at least one NTP sync has succeeded this process lifetime.
static SYNCED: AtomicBool = AtomicBool::new(false);

/// Guards single-spawn of the background poller.
static SPAWN_ONCE: Once = Once::new();

/// Seconds between the NTP and Unix epochs (1900-01-01 → 1970-01-01).
const NTP_UNIX_EPOCH_DELTA: u64 = 2_208_988_800;

/// Default NTP servers: Cloudflare primary, Google fallback.
const DEFAULT_SERVERS: &[&str] = &["time.cloudflare.com:123", "time.google.com:123"];

/// Reject an NTP offset larger than this as corrupted rather than apply it.
/// Real clock drift is milliseconds to low seconds; a magnitude this large
/// can only come from a broken measurement (e.g. `unix_now_seconds` reading
/// before the Unix epoch), not a genuinely unsynced OS clock. Deliberately
/// generous — this guards against corruption, not tuning normal drift.
const MAX_PLAUSIBLE_OFFSET_MS: i64 = 24 * 60 * 60 * 1000;

/// Configuration for the background NTP poller.
#[derive(Debug, Clone)]
pub struct NtpConfig {
    /// Servers to try in order each poll; first success wins.
    pub servers: Vec<String>,
    /// Interval between polls after a successful sync.
    pub poll_interval: Duration,
    /// Interval between polls while no server has answered yet.
    pub retry_interval: Duration,
    /// Per-query UDP read timeout.
    pub query_timeout: Duration,
}

impl Default for NtpConfig {
    fn default() -> Self {
        Self {
            servers: DEFAULT_SERVERS.iter().map(|s| s.to_string()).collect(),
            poll_interval: Duration::from_secs(64),
            retry_interval: Duration::from_secs(8),
            query_timeout: Duration::from_millis(3000),
        }
    }
}

impl NtpConfig {
    /// Build config from env, falling back to defaults.
    ///
    /// `NTP_SERVERS` (comma-separated `host:port`), `NTP_POLL_SECS`,
    /// `NTP_TIMEOUT_MS`.
    pub fn from_env() -> Self {
        let mut cfg = Self::default();
        if let Ok(servers) = std::env::var("NTP_SERVERS") {
            let parsed: Vec<String> = servers
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(with_default_port)
                .collect();
            if !parsed.is_empty() {
                cfg.servers = parsed;
            }
        }
        if let Some(secs) = env_u64("NTP_POLL_SECS") {
            cfg.poll_interval = Duration::from_secs(secs.max(1));
        }
        if let Some(ms) = env_u64("NTP_TIMEOUT_MS") {
            cfg.query_timeout = Duration::from_millis(ms.max(100));
        }
        cfg
    }
}

/// NTP-corrected current UTC time.
///
/// Returns `OS clock + synced offset`. Before the first successful sync (or
/// when `NTP_DISABLE=1`) the offset is zero, so this equals `Utc::now()` —
/// never worse than the legacy behaviour, and self-correcting once a server
/// answers.
#[inline]
pub fn now() -> DateTime<Utc> {
    let offset = OFFSET_MILLIS.load(Ordering::Relaxed);
    Utc::now() + chrono::Duration::milliseconds(offset)
}

/// Current NTP correction applied to the OS clock, in milliseconds
/// (`ntp_time - os_time`). Useful for health/metrics endpoints.
#[inline]
pub fn offset_millis() -> i64 {
    OFFSET_MILLIS.load(Ordering::Relaxed)
}

/// Whether at least one NTP sync has succeeded.
#[inline]
pub fn is_synced() -> bool {
    SYNCED.load(Ordering::Relaxed)
}

/// Start the background NTP poller with [`NtpConfig::from_env`].
///
/// Idempotent: only the first call spawns a thread. Honors `NTP_DISABLE=1`,
/// in which case it is a no-op and [`now()`] stays on the OS clock.
pub fn init_default() {
    if env_flag("NTP_DISABLE") {
        tracing::info!("ntp sync disabled via NTP_DISABLE; using OS clock");
        return;
    }
    spawn_sync(NtpConfig::from_env());
}

/// Start the background NTP poller with an explicit config.
///
/// Idempotent across the process: subsequent calls are ignored so multiple
/// services/crates wiring this up cannot spawn duplicate threads.
pub fn spawn_sync(config: NtpConfig) {
    SPAWN_ONCE.call_once(|| {
        let builder = std::thread::Builder::new().name("ntp-sync".into());
        let spawned = builder.spawn(move || poll_loop(config));
        if let Err(e) = spawned {
            tracing::warn!(error = %e, "failed to spawn ntp-sync thread; using OS clock");
        }
    });
}

/// Background poll loop: query servers, publish offset, sleep, repeat.
fn poll_loop(config: NtpConfig) {
    loop {
        match query_first(&config) {
            Some((server, offset_ms)) if offset_ms.abs() > MAX_PLAUSIBLE_OFFSET_MS => {
                tracing::error!(
                    server = %server,
                    offset_ms,
                    max_plausible_ms = MAX_PLAUSIBLE_OFFSET_MS,
                    "ntp offset implausibly large; discarding as corrupted, retaining last offset"
                );
                std::thread::sleep(config.retry_interval);
            }
            Some((server, offset_ms)) => {
                OFFSET_MILLIS.store(offset_ms, Ordering::Relaxed);
                let first = !SYNCED.swap(true, Ordering::Relaxed);
                if first {
                    tracing::info!(
                        server = %server,
                        offset_ms,
                        "ntp sync established (primary time source)"
                    );
                } else {
                    tracing::debug!(server = %server, offset_ms, "ntp resync");
                }
                std::thread::sleep(config.poll_interval);
            }
            None => {
                tracing::warn!(
                    servers = ?config.servers,
                    synced = is_synced(),
                    "ntp sync failed for all servers; retaining last offset"
                );
                std::thread::sleep(config.retry_interval);
            }
        }
    }
}

/// Try each configured server in order, returning the first
/// `(server, offset_ms)` that answers.
fn query_first(config: &NtpConfig) -> Option<(String, i64)> {
    for server in &config.servers {
        match query_offset_ms(server, config.query_timeout) {
            Ok(offset_ms) => return Some((server.clone(), offset_ms)),
            Err(e) => tracing::debug!(server = %server, error = %e, "ntp query failed"),
        }
    }
    None
}

/// Perform one SNTPv4 exchange and return the clock offset in milliseconds
/// (`server_time - local_time`), per the RFC 4330 four-timestamp formula.
fn query_offset_ms(server: &str, timeout: Duration) -> std::io::Result<i64> {
    let addr = server
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no addr resolved"))?;

    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.set_read_timeout(Some(timeout))?;
    socket.set_write_timeout(Some(timeout))?;
    socket.connect(addr)?;

    // SNTPv4 client request: LI=0, VN=4, Mode=3 (client) → 0b00_100_011 = 0x23.
    let mut packet = [0u8; 48];
    packet[0] = 0x23;

    // t1 = client transmit time (originate). Stamp it into the Transmit
    // Timestamp field so we can match and so servers behave; we also keep it
    // locally for the offset calculation.
    let t1 = unix_now_seconds();
    write_ntp_timestamp(&mut packet[40..48], t1);

    socket.send(&packet)?;

    let mut buf = [0u8; 48];
    let n = socket.recv(&mut buf)?;
    let t4 = unix_now_seconds();
    if n < 48 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::UnexpectedEof,
            "short ntp response",
        ));
    }

    // Reject a server that reports an unsynchronized clock (stratum 0 / kiss-o'-death).
    let stratum = buf[1];
    if stratum == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "server stratum 0 (kiss-o'-death / unsynced)",
        ));
    }

    // t2 = server receive timestamp (bytes 32..40), t3 = server transmit (bytes 40..48).
    let t2 = read_ntp_timestamp(&buf[32..40]);
    let t3 = read_ntp_timestamp(&buf[40..48]);

    // offset = ((t2 - t1) + (t3 - t4)) / 2   (server clock minus local clock)
    let offset_secs = ((t2 - t1) + (t3 - t4)) / 2.0;
    Ok((offset_secs * 1000.0).round() as i64)
}

/// Current Unix time as fractional seconds from the OS clock.
///
/// `duration_since` only fails if the OS clock reads before 1970-01-01,
/// which would otherwise silently corrupt the NTP offset calculation in
/// [`query_offset_ms`] — log loudly so a broken container clock is visible
/// instead of manifesting as a mysterious platform-wide timestamp skew.
fn unix_now_seconds() -> f64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(d) => d.as_secs_f64(),
        Err(e) => {
            tracing::error!(error = %e, "OS clock reads before the Unix epoch; NTP offset calculation will be corrupted");
            0.0
        }
    }
}

/// Write a 64-bit NTP timestamp (seconds since 1900, 32.32 fixed point) for a
/// Unix-epoch fractional-seconds value into `out` (8 bytes, big-endian).
fn write_ntp_timestamp(out: &mut [u8], unix_seconds: f64) {
    let ntp_seconds = unix_seconds + NTP_UNIX_EPOCH_DELTA as f64;
    let secs = ntp_seconds.trunc() as u32;
    let frac = ((ntp_seconds.fract()) * (u32::MAX as f64 + 1.0)) as u32;
    out[0..4].copy_from_slice(&secs.to_be_bytes());
    out[4..8].copy_from_slice(&frac.to_be_bytes());
}

/// Read an 8-byte big-endian NTP timestamp and return Unix fractional seconds.
fn read_ntp_timestamp(bytes: &[u8]) -> f64 {
    let secs = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as f64;
    let frac = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) as f64;
    secs + frac / (u32::MAX as f64 + 1.0) - NTP_UNIX_EPOCH_DELTA as f64
}

/// Append `:123` if the entry has no explicit port.
fn with_default_port(s: &str) -> String {
    if s.contains(':') {
        s.to_string()
    } else {
        format!("{s}:123")
    }
}

fn env_u64(key: &str) -> Option<u64> {
    std::env::var(key).ok().and_then(|v| v.trim().parse().ok())
}

fn env_flag(key: &str) -> bool {
    matches!(
        std::env::var(key).ok().as_deref(),
        Some("1") | Some("true") | Some("TRUE") | Some("yes")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ntp_timestamp_roundtrip() {
        let unix = 1_700_000_000.5_f64;
        let mut buf = [0u8; 8];
        write_ntp_timestamp(&mut buf, unix);
        let back = read_ntp_timestamp(&buf);
        assert!((back - unix).abs() < 1e-3, "roundtrip drift: {back} vs {unix}");
    }

    #[test]
    fn now_equals_os_clock_before_sync() {
        // Offset starts at zero, so now() tracks Utc::now() within a tick.
        let delta = (now() - Utc::now()).num_milliseconds().abs();
        assert!(delta < 50, "unsynced now() should track OS clock, delta={delta}ms");
    }

    #[test]
    fn with_default_port_adds_123() {
        assert_eq!(with_default_port("time.cloudflare.com"), "time.cloudflare.com:123");
        assert_eq!(with_default_port("1.2.3.4:5000"), "1.2.3.4:5000");
    }

    /// Spawn a one-shot mock SNTP server on loopback that answers a single query.
    /// `stratum` and the server-time offset (seconds added to its OS clock when
    /// stamping t2/t3) are configurable; `truncate` sends a short (<48B) reply.
    fn spawn_mock_ntp(stratum: u8, server_offset_secs: f64, truncate: bool) -> String {
        let socket = UdpSocket::bind("127.0.0.1:0").expect("bind mock ntp");
        let addr = socket.local_addr().expect("local addr").to_string();
        std::thread::spawn(move || {
            let mut req = [0u8; 48];
            if let Ok((_n, peer)) = socket.recv_from(&mut req) {
                let mut resp = [0u8; 48];
                resp[0] = 0x24; // LI=0, VN=4, Mode=4 (server)
                resp[1] = stratum;
                // Server stamps receive (t2) and transmit (t3) with its (offset) clock.
                let server_now = unix_now_seconds() + server_offset_secs;
                write_ntp_timestamp(&mut resp[32..40], server_now);
                write_ntp_timestamp(&mut resp[40..48], server_now);
                let out = if truncate { &resp[..20] } else { &resp[..] };
                let _ = socket.send_to(out, peer);
            }
        });
        addr
    }

    #[test]
    fn query_offset_ms_computes_server_offset() {
        // Server clock runs +5s ahead; the RFC-4330 four-timestamp formula should
        // recover ~+5000ms over fast loopback.
        let addr = spawn_mock_ntp(1, 5.0, false);
        let offset = query_offset_ms(&addr, Duration::from_secs(2)).expect("query ok");
        assert!(
            (offset - 5000).abs() < 500,
            "expected ~+5000ms offset, got {offset}ms"
        );
    }

    #[test]
    fn query_offset_ms_rejects_stratum_zero() {
        // Stratum 0 = kiss-o'-death / unsynced server → must be rejected, not trusted.
        let addr = spawn_mock_ntp(0, 0.0, false);
        let err = query_offset_ms(&addr, Duration::from_secs(2)).expect_err("stratum 0 rejected");
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn query_offset_ms_rejects_short_response() {
        let addr = spawn_mock_ntp(1, 0.0, true);
        let err = query_offset_ms(&addr, Duration::from_secs(2)).expect_err("short response rejected");
        assert_eq!(err.kind(), std::io::ErrorKind::UnexpectedEof);
    }

    #[test]
    fn from_env_parses_overrides() {
        // Mutating process env: scope the vars and clean up to limit cross-test bleed.
        std::env::set_var("NTP_SERVERS", "a.example , b.example:5000");
        std::env::set_var("NTP_POLL_SECS", "30");
        std::env::set_var("NTP_TIMEOUT_MS", "750");
        let cfg = NtpConfig::from_env();
        std::env::remove_var("NTP_SERVERS");
        std::env::remove_var("NTP_POLL_SECS");
        std::env::remove_var("NTP_TIMEOUT_MS");

        assert_eq!(cfg.servers, vec!["a.example:123".to_string(), "b.example:5000".to_string()]);
        assert_eq!(cfg.poll_interval, Duration::from_secs(30));
        assert_eq!(cfg.query_timeout, Duration::from_millis(750));
    }
}
