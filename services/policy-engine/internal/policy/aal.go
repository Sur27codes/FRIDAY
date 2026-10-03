package policy

import "time"

// Freshness windows per assurance factor (ST §S.13, closure-pass addition).
// TBD — benchmark required for the exact active-user-confirmation window,
// per docs/D-srs.md's discipline of never inventing a number without a
// benchmark; a conservative placeholder is used here and MUST be replaced
// via a benchmarked value before this leaves Phase 1, not silently trusted.
const activeUserConfirmWindow = 30 * time.Second

// requiredAAL implements ST §S.13's risk-class -> required-AAL table.
// The capability's own registered risk_level is the caller's
// responsibility to supply as PolicyInput.Risk (ST §S.13's closure-pass
// clarification: risk_level is authoritative from the capability registry,
// never from the IR's self-reported value, cross-validated upstream at
// IR validation stage 4 before Evaluate() is ever called).
func requiredAAL(risk RiskLevel) AAL {
	switch risk {
	case RiskNone:
		return AAL0
	case RiskLow:
		return AAL1
	case RiskExternalSideEffect:
		return AAL2
	case RiskHigh:
		return AAL3
	case RiskCritical:
		return AAL4
	default:
		// Fail closed: an unrecognized risk level is treated as the
		// strictest requirement, never the weakest. This should be
		// unreachable if upstream validation (IR stage 4) is correct;
		// it is not removed, because "unreachable in theory" is not the
		// same guarantee as "structurally impossible" — see the review's
		// own finding about the Response Validation Gate's weaker
		// enforcement for why defense-in-depth here matters.
		return AAL4
	}
}

// factorFresh reports whether a presented factor is still valid at
// evaluatedAt, applying the per-factor freshness rule from ST §S.13.
func factorFresh(pf PresentedFactor, evaluatedAt time.Time) bool {
	if !pf.Available {
		return false
	}
	switch pf.Factor {
	case FactorOSBiometric, FactorSecurityKey:
		// Single-use: valid only for the exact call it was collected for.
		// In this package's model that means "collected at essentially
		// the same evaluation," which we treat as a zero-tolerance
		// freshness window — any nonzero elapsed time is stale, since a
		// biometric/security-key result is never meant to be reused
		// across separate Evaluate() calls at all.
		return !pf.EstablishedAt.Before(evaluatedAt) || pf.EstablishedAt.Equal(evaluatedAt)
	case FactorActiveUserConfirm:
		return evaluatedAt.Sub(pf.EstablishedAt) <= activeUserConfirmWindow &&
			evaluatedAt.Sub(pf.EstablishedAt) >= 0
	case FactorDeviceTrustedSession:
		// Phase-1 definition (ST §S.13): satisfied for the lifetime of the
		// local FRIDAY process — no expiry modeled in M1, since there is
		// no Device Mesh session concept yet to expire. Always fresh if
		// present at all.
		return true
	case FactorVoiceMatch:
		// No freshness requirement of its own — it is excluded from AAL2+
		// satisfaction regardless (see satisfiesAAL below), so staleness
		// is moot for this factor in Phase 1.
		return true
	default:
		return false
	}
}

// satisfiesAAL implements the AAL0-AAL4 satisfaction rules from ST §S.13,
// including the load-bearing rule: voice_match, at any confidence, SHALL
// NOT by itself satisfy AAL2 or above.
func satisfiesAAL(required AAL, factors []PresentedFactor, evaluatedAt time.Time) bool {
	fresh := map[AssuranceFactor]bool{}
	for _, pf := range factors {
		if factorFresh(pf, evaluatedAt) {
			fresh[pf.Factor] = true
		}
	}

	switch required {
	case AAL0:
		return true
	case AAL1:
		return fresh[FactorDeviceTrustedSession]
	case AAL2:
		return fresh[FactorDeviceTrustedSession] && fresh[FactorActiveUserConfirm]
	case AAL3:
		return fresh[FactorDeviceTrustedSession] &&
			(fresh[FactorOSBiometric] || fresh[FactorSecurityKey])
	case AAL4:
		return fresh[FactorDeviceTrustedSession] &&
			(fresh[FactorOSBiometric] || fresh[FactorSecurityKey]) &&
			fresh[FactorActiveUserConfirm]
	default:
		return false
	}
}
