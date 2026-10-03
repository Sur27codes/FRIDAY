// Package envelope implements the Execution Envelope
// (docs/PHASE-1-EXECUTION-SPEC.md §1) and its documented 11-check
// validation order (§1.2). This is the concrete enforcement of
// PHASE-1-EXECUTION-SPEC.md §1.1's three statements:
//
//	PLANNER OUTPUT                                   != EXECUTION AUTHORITY
//	FRIDAY IR                                        != EXECUTION AUTHORITY
//	EXECUTION ENVELOPE WITHOUT VALID POLICY AUTHORIZATION != EXECUTION AUTHORITY
//
// Neither friday/ir.RawIR nor friday/ir.ValidatedIR is accepted anywhere
// in this package's API — there is no function that takes either type,
// which is the type-system half of "do not treat FRIDAY IR ... as an
// execution envelope" (M3 brief §6).
package envelope

import (
	"time"

	"friday/capability-bus/internal/contract"
	"friday/capability-bus/internal/registry"
	"friday/capability-bus/internal/store"
	"friday/ir"
	"friday/policytoken"
)

// Envelope mirrors PHASE-1-EXECUTION-SPEC.md §1's schema.
type Envelope struct {
	ExecutionID   string
	RequestID     string
	CorrelationID string
	Actor         string
	GoalID        string
	TaskID        string
	IRVersion     string
	IRID          string
	Capability    string

	// ValidatedArguments is what the caller (the not-yet-built Runtime
	// Scheduler, M5+) supplied. Check 4 below NEVER trusts this field for
	// execution — it is compared against a fresh re-fetch from the IR
	// store and only the re-fetched value is ever passed to an adapter.
	ValidatedArguments map[string]interface{}

	PolicyToken *policytoken.PolicyToken

	Purpose  string
	Risk     contract.RiskLevel
	Deadline *time.Time
	Timeout  time.Duration

	IdempotencyKey string
	SafeToRetry    bool

	ExpectedOutcomeDescription string
	ExpectedSuccessCondition   interface{}

	VerificationMethod string

	Cancellable        bool
	CancellationEffect string

	CreatedAt          time.Time
	CreatedByComponent string
}

const SupportedIRVersion = "0.2"

// ValidationContext bundles the read-only stores/verifier the 11 checks
// consult. None of these let the Bus mint anything — Verifier is
// verify-only (friday/policytoken), and both stores are read paths for
// state the (not-yet-built) Runtime/Policy Engine processes would have
// written.
type ValidationContext struct {
	Registry           registry.Registry
	Verifier           policytoken.Verifier
	IRStore            *store.IRStore
	TaskStore          *store.TaskStore
	Now                time.Time
	LiveConsentPurpose string // live Consent Ledger state for the actor+capability, "" if none
}

// Validate runs the 11 checks from PHASE-1-EXECUTION-SPEC.md §1.2, in
// order, short-circuiting on the first failure, and returns the resolved
// contract.Contract plus the RE-FETCHED canonical arguments (never the
// envelope's own ValidatedArguments field) that dispatch must use.
func Validate(env Envelope, ctx ValidationContext) (contract.Contract, map[string]interface{}, *DispatchError) {
	// 1. schema_version supported.
	if env.IRVersion != SupportedIRVersion {
		return contract.Contract{}, nil, newErr("1_schema_version", CategoryInvalidExecutionEnvelope,
			"unsupported ir_version")
	}

	// 2. task_id resolves to a real, currently-non-terminal task.
	if env.TaskID == "" {
		return contract.Contract{}, nil, newErr("2_task_id", CategoryInvalidExecutionEnvelope, "task_id missing")
	}
	taskState, ok := ctx.TaskStore.Get(env.TaskID)
	if !ok {
		return contract.Contract{}, nil, newErr("2_task_id", CategoryInvalidExecutionEnvelope, "task_id does not resolve to a known task")
	}
	if taskState.Terminal() {
		if taskState == store.TaskCancelled {
			return contract.Contract{}, nil, newErr("2_task_id", CategoryCancelled, "owning task is cancelled")
		}
		return contract.Contract{}, nil, newErr("2_task_id", CategoryInvalidExecutionEnvelope, "owning task already reached a terminal state")
	}

	// 3. capability exists.
	cap, ok := ctx.Registry.Get(env.Capability)
	if !ok {
		return contract.Contract{}, nil, newErr("3_capability_exists", CategoryUnknownCapability,
			"capability_id is not registered")
	}

	// 4. validated_arguments RE-FETCHED from the immutable IR store by
	// ir_id — the envelope's own ValidatedArguments field is used only
	// for a pre-check comparison below (check 6, argument digest), never
	// passed to the adapter directly.
	rec, ok := ctx.IRStore.Get(env.IRID)
	if !ok {
		return contract.Contract{}, nil, newErr("4_arguments_refetch", CategoryInvalidExecutionEnvelope,
			"ir_id does not resolve to a stored IR record")
	}
	if rec.CapabilityID != env.Capability {
		return contract.Contract{}, nil, newErr("4_arguments_refetch", CategoryAuthorizationScopeMismatch,
			"stored IR record targets a different capability than this envelope")
	}
	canonicalArgs := rec.Arguments
	digest, digestErr := ir.ArgumentsDigest(canonicalArgs)
	if digestErr != nil {
		return contract.Contract{}, nil, newErr("4_arguments_refetch", CategoryInvalidExecutionEnvelope,
			"failed to canonicalize re-fetched arguments")
	}

	// Argument shape check against the capability's own input schema —
	// using the RE-FETCHED arguments, not the envelope's.
	if derr := validateArgsAgainstSchema(canonicalArgs, cap); derr != nil {
		return contract.Contract{}, nil, derr
	}

	// 5. authorization.policy_token present.
	if env.PolicyToken == nil {
		return contract.Contract{}, nil, newErr("5_token_presence", CategoryAuthorizationMissing, "no policy_token in envelope")
	}

	// 6. policy_token passes all 6 checks (policytoken.Verifier.Validate),
	// including 6d: the digest of the RE-FETCHED arguments (not the
	// envelope's own field) must match what the token was issued for —
	// this is the concrete defense against argument tampering (POL-017 /
	// M3-POL-007).
	valReq := policytoken.ValidationRequest{
		Token:              env.PolicyToken,
		Now:                ctx.Now,
		ExpectedIRID:       env.IRID,
		ExpectedCapability: env.Capability,
		ExpectedActor:      env.Actor,
		ExpectedArgsDigest: digest,
		LiveConsentPurpose: ctx.LiveConsentPurpose,
		TaskCancelled:      taskState == store.TaskCancelled,
	}
	if verr := ctx.Verifier.Validate(valReq); verr != nil {
		ve, _ := verr.(*policytoken.ValidationError)
		cat := CategoryAuthorizationInvalid
		if ve != nil {
			switch ve.Check {
			case "6b_expiry":
				cat = CategoryAuthorizationExpired
			case "6c_scope":
				cat = CategoryAuthorizationScopeMismatch
			case "6d_arguments":
				cat = CategoryArgumentDigestMismatch
			case "6e_purpose":
				cat = CategoryPurposeMismatch
			case "6f_task_state":
				cat = CategoryCancelled
			}
		}
		return contract.Contract{}, nil, newErr("6_token_validate", cat, "policy token failed validation")
	}

	// 7. risk classification on the token matches the capability's own
	// registered risk_level — defense in depth, re-verified here even
	// though upstream (M2 stage 4) should already guarantee it.
	if string(env.PolicyToken.RiskLevel) != string(cap.RiskLevel) {
		return contract.Contract{}, nil, newErr("7_risk_match", CategoryAuthorizationScopeMismatch,
			"token risk_level does not match capability's registered risk_level")
	}

	// 8. idempotency_key present and non-empty.
	if env.IdempotencyKey == "" {
		return contract.Contract{}, nil, newErr("8_idempotency", CategoryInvalidExecutionEnvelope, "idempotency_key missing")
	}

	// 9. expected_outcome.success_condition present.
	if env.ExpectedSuccessCondition == nil {
		return contract.Contract{}, nil, newErr("9_expected_outcome", CategoryInvalidExecutionEnvelope, "expected_outcome.success_condition missing")
	}

	// 10. verification_contract present and refers to the capability's
	// own declared method.
	if env.VerificationMethod == "" || env.VerificationMethod != cap.VerificationMethod {
		return contract.Contract{}, nil, newErr("10_verification_contract", CategoryInvalidExecutionEnvelope,
			"verification_method missing or does not match the capability's declared method")
	}

	// 11. cancellation state permits execution.
	if !env.Cancellable && env.CancellationEffect == "" {
		return contract.Contract{}, nil, newErr("11_cancellation_state", CategoryInvalidExecutionEnvelope,
			"cancellation fields missing")
	}

	return cap, canonicalArgs, nil
}

func validateArgsAgainstSchema(args map[string]interface{}, cap contract.Contract) *DispatchError {
	for name, spec := range cap.InputSchema {
		val, present := args[name]
		if !present {
			if spec.Required {
				return newErr("4_arguments_refetch", CategoryCapabilityInputInvalid, "required argument missing: "+name)
			}
			continue
		}
		s, isString := val.(string)
		if spec.Type == "string" && !isString {
			return newErr("4_arguments_refetch", CategoryCapabilityInputInvalid, "argument not a string: "+name)
		}
		if spec.MaxLength > 0 && len(s) > spec.MaxLength {
			return newErr("4_arguments_refetch", CategoryCapabilityInputInvalid, "argument exceeds max length: "+name)
		}
	}
	if !cap.AllowAdditionalArgs {
		for name := range args {
			if _, declared := cap.InputSchema[name]; !declared {
				return newErr("4_arguments_refetch", CategoryCapabilityInputInvalid, "undeclared argument: "+name)
			}
		}
	}
	return nil
}
