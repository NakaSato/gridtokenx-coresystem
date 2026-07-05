//! ASSA — Adaptive Step-Size Search for batch P2P market clearing.
//!
//! Port of Algorithm 2 from arXiv:2510.02985 (Huang et al., 2025),
//! "Real-Time P2P Energy Trading for Multi-Microgrids".
//!
//! NOT a CDA order book. This is a *batch* uniform-price auction:
//!   - operator announces a price `λ`
//!   - every participant returns its best-response NET quantity at `λ`
//!       (sign convention: + = wants to BUY/import, − = wants to SELL/export)
//!   - operator nudges `λ` along the supply–demand imbalance until |Σq| ≤ δ
//!
//! Theory (Appendix C): the iteration is the fixed point λ ← g(λ) = λ + σ·F(λ),
//! F(λ)=Σ best-responses. Local convergence needs 0 < σ < 2/|F'(λ*)|. Because
//! F' is time-varying and unknown, a FIXED σ can oscillate — so σ is halved on
//! every sign flip of the imbalance (Case B). Monotone + bounded ⇒ finite steps.
//!
//! Guarantees rest on Prop 1: each best-response must be CONTINUOUS and
//! MONOTONICALLY NON-INCREASING in price (higher price ⇒ buy less / sell more).
//! Break that and uniqueness + convergence are gone.

/// A market participant: maps an announced price to a signed net quantity.
/// + = net buyer (import), − = net seller (export). MUST be non-increasing in λ.
pub trait BestResponse {
    fn quantity_at(&self, price: f64) -> f64;
}

/// Result of a clearing round.
#[derive(Debug, Clone, Copy)]
pub struct Clearing {
    pub price: f64,        // λ* — clearing price, ∈ [fit, tou]
    pub imbalance: f64,    // residual Σq absorbed by the grid (≈0 if interior clear)
    pub iterations: u32,   // ASSA steps taken
    pub at_boundary: bool, // true ⇒ pinned to FiT or ToU (grid trade), not interior eq.
}

/// ASSA configuration. Defaults track the paper (σ₀=5e-6, δ=5 kW).
#[derive(Debug, Clone, Copy)]
pub struct AssaConfig {
    pub fit: f64,          // λ_FiT — feed-in tariff (lower price bound)
    pub tou: f64,          // λ_ToU — time-of-use tariff (upper price bound)
    pub init_price: f64,   // λ₀ — seed; use last interval's clearing price
    pub init_step: f64,    // σ₀ — initial step size
    pub tol: f64,          // δ — imbalance tolerance (same unit as quantities)
    pub max_iters: u32,    // hard cap (real-time safety; paper avg ≈ 2.07)
}

impl Default for AssaConfig {
    fn default() -> Self {
        Self { fit: 0.0, tou: 0.0, init_price: 0.0, init_step: 5e-6, tol: 5.0, max_iters: 64 }
    }
}

/// Run ASSA to find the uniform clearing price.
///
/// `participants` each expose a best-response. Aggregate imbalance
/// F(λ) = Σ qᵢ(λ). Price clamps to [fit, tou]; hitting a bound ends the
/// round at that boundary (grid-complementarity condition 6 of the paper).
pub fn clear<P: BestResponse>(participants: &[P], cfg: &AssaConfig) -> Clearing {
    let imbalance = |price: f64| -> f64 {
        participants.iter().map(|p| p.quantity_at(price)).sum()
    };

    let mut price = cfg.init_price.clamp(cfg.fit, cfg.tou);
    let mut step = cfg.init_step;
    let mut prev_f: Option<f64> = None;

    for k in 0..cfg.max_iters {
        let f = imbalance(price);

        // Converged: supply ≈ demand.
        if f.abs() <= cfg.tol {
            return Clearing { price, imbalance: f, iterations: k, at_boundary: false };
        }

        // Sign flip ⇒ we straddled the equilibrium ⇒ halve step (anti-oscillation).
        if let Some(pf) = prev_f {
            if f * pf < 0.0 {
                step *= 0.5;
            }
        }
        prev_f = Some(f);

        // Price update: λ ← λ + σ·F(λ).  F>0 (excess demand) pushes price UP.
        let next = price + step * f;

        // Clamp to tariff band; a boundary hit means the grid absorbs the residual.
        if next < cfg.fit {
            let f_b = imbalance(cfg.fit);
            return Clearing { price: cfg.fit, imbalance: f_b, iterations: k + 1, at_boundary: true };
        }
        if next > cfg.tou {
            let f_b = imbalance(cfg.tou);
            return Clearing { price: cfg.tou, imbalance: f_b, iterations: k + 1, at_boundary: true };
        }
        price = next;
    }

    // Hit the iteration cap — return best effort (should be rare; paper avg ~2 iters).
    let f = imbalance(price);
    Clearing { price, imbalance: f, iterations: cfg.max_iters, at_boundary: false }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Linear prosumer: q(λ) = base − slope·λ  (slope ≥ 0 ⇒ non-increasing, satisfies Prop 1).
    struct Linear { base: f64, slope: f64 }
    impl BestResponse for Linear {
        fn quantity_at(&self, price: f64) -> f64 { self.base - self.slope * price }
    }

    #[test]
    fn converges_to_interior_equilibrium() {
        // Two buyers, two sellers; aggregate F(λ)=Σ(base) − Σ(slope)·λ.
        // Σbase = 300+200−100−150 = 250 ; Σslope = 1000+800+1200+900 = 3900.
        // F(λ*)=0 ⇒ λ* = 250/3900 ≈ 0.0641 $/kWh, inside [0.05, 0.12].
        let ps = vec![
            Linear { base: 300.0, slope: 1000.0 },
            Linear { base: 200.0, slope: 800.0 },
            Linear { base: -100.0, slope: 1200.0 },
            Linear { base: -150.0, slope: 900.0 },
        ];
        // init_step 1e-4 < 2/|F'| = 2/3900 ≈ 5.1e-4 ⇒ satisfies eq (60), converges fast.
        let cfg = AssaConfig {
            fit: 0.05, tou: 0.12, init_price: 0.08,
            init_step: 1e-4, tol: 0.5, max_iters: 200,
            ..Default::default()
        };
        let c = clear(&ps, &cfg);
        assert!(!c.at_boundary, "should clear in the interior");
        assert!((c.price - 0.0641).abs() < 1e-3, "got {}", c.price);
        assert!(c.imbalance.abs() <= cfg.tol);
    }

    #[test]
    fn pins_to_tou_under_excess_demand() {
        // All net buyers at any feasible price ⇒ F>0 everywhere ⇒ price rises to ToU,
        // residual import absorbed by grid (condition 6).
        let ps = vec![
            Linear { base: 500.0, slope: 10.0 },
            Linear { base: 400.0, slope: 10.0 },
        ];
        let cfg = AssaConfig { fit: 0.05, tou: 0.12, init_price: 0.08, tol: 0.5, max_iters: 200, ..Default::default() };
        let c = clear(&ps, &cfg);
        assert!(c.at_boundary);
        assert_eq!(c.price, 0.12);
    }

    #[test]
    fn init_price_does_not_change_equilibrium() {
        // Prop / Remark 4: equilibrium independent of seed (only iteration count differs).
        let ps = vec![
            Linear { base: 300.0, slope: 1000.0 },
            Linear { base: -290.0, slope: 1000.0 },
        ];
        let base = AssaConfig { fit: 0.05, tou: 0.12, tol: 0.1, max_iters: 500, init_step: 5e-6, ..Default::default() };
        let from_fit = clear(&ps, &AssaConfig { init_price: 0.05, ..base });
        let from_tou = clear(&ps, &AssaConfig { init_price: 0.12, ..base });
        assert!((from_fit.price - from_tou.price).abs() < 1e-2);
    }
}
