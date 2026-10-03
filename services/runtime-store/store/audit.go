package store

import (
	"context"
	"database/sql"
	"encoding/json"
	"time"
)

// EventType is PHASE-1-EXECUTION-SPEC.md §5's "exactly these event
// types" list, EXTENDED with 5 additional types PHASE-1-EMERGENCY-STOP-TEST-SPEC.md's
// own literal test cases require (StopRequested, CompensationAttempted,
// TaskCompensated, TaskRequiresManualReview, StopRequestIgnored — see
// STOP-006, STOP-007, STOP-010, STOP-011).
//
// Disclosed, not silent: §5 says "Phase 1 emits exactly these event
// types — no more... no fewer," a closed list of 12, written before the
// emergency-stop spec's later remediation pass added the COMPENSATING/
// COMPENSATED/requires_manual_review states to K.2. Those states are
// already an approved, implemented part of K.2 (state.go) and the
// emergency-stop spec — itself one of M6's named authoritative sources —
// explicitly names the audit events needed to represent transitions into
// and out of them. Treating §5's list as silently exhaustive would make
// it structurally impossible to audit a compensation or manual-review
// outcome the state machine itself allows, which is a worse outcome than
// extending the list. This is recorded here, in the traceability matrix,
// and is available for owner review — the same class of judgment call as
// M3's policytoken extraction, not a silent scope change.
type EventType string

const (
	EventIntentReceived        EventType = "IntentReceived"
	EventIRCompiled            EventType = "IRCompiled"
	EventIRValidated           EventType = "IRValidated"
	EventPlanCreated           EventType = "PlanCreated"
	EventPolicyEvaluated       EventType = "PolicyEvaluated"
	EventCapabilityAuthorized  EventType = "CapabilityAuthorized"
	EventCapabilityStarted     EventType = "CapabilityStarted"
	EventCapabilityCompleted   EventType = "CapabilityCompleted"
	EventVerificationStarted   EventType = "VerificationStarted"
	EventVerificationCompleted EventType = "VerificationCompleted"
	EventTaskSucceeded         EventType = "TaskSucceeded"
	EventTaskFailed            EventType = "TaskFailed"
	EventTaskCancelled         EventType = "TaskCancelled"

	// Emergency-stop-spec extensions (see doc comment above).
	EventStopRequested            EventType = "StopRequested"
	EventStopRequestIgnored       EventType = "StopRequestIgnored"
	EventCompensationAttempted    EventType = "CompensationAttempted"
	EventTaskCompensated          EventType = "TaskCompensated"
	EventTaskRequiresManualReview EventType = "TaskRequiresManualReview"

	// M8 closure-milestone extensions — same disclosed-extension pattern
	// as the emergency-stop additions above: PHASE-1-EXECUTION-SPEC.md
	// §5's original 12-event list predates the M8 components entirely, so
	// neither event name could have been anticipated there. Each records
	// exactly one new M8 pipeline stage's outcome, mirrored on the same
	// event_schema (§5) as every other event — no separate taxonomy.
	EventContextCompiled  EventType = "ContextCompiled"  // Context Compiler + Firewall ran (FR-CONTEXT-001/002)
	EventContentForgotten EventType = "ContentForgotten" // forgetting.Forget succeeded (FR-MEM-004)
)

func (e EventType) valid() bool {
	switch e {
	case EventIntentReceived, EventIRCompiled, EventIRValidated, EventPlanCreated, EventPolicyEvaluated,
		EventCapabilityAuthorized, EventCapabilityStarted, EventCapabilityCompleted,
		EventVerificationStarted, EventVerificationCompleted,
		EventTaskSucceeded, EventTaskFailed, EventTaskCancelled,
		EventStopRequested, EventStopRequestIgnored, EventCompensationAttempted,
		EventTaskCompensated, EventTaskRequiresManualReview,
		EventContextCompiled, EventContentForgotten:
		return true
	}
	return false
}

// Sensitivity mirrors O.2's classification, restricted to the two values
// PHASE-1-EXECUTION-SPEC.md §5 actually gates payload logging on.
type Sensitivity string

const (
	SensitivityPublic          Sensitivity = "PUBLIC"
	SensitivityInternal        Sensitivity = "INTERNAL"
	SensitivityPersonal        Sensitivity = "PERSONAL"
	SensitivityHighlySensitive Sensitivity = "HIGHLY_SENSITIVE"
)

// AuditEvent mirrors PHASE-1-EXECUTION-SPEC.md §5's event_schema exactly.
// Payload is deliberately separate from the required fields above it —
// AppendAuditEvent enforces §5's sensitivity rule itself (see below), so
// callers cannot accidentally leak a PERSONAL-or-above payload into the
// audit log merely by supplying one.
type AuditEvent struct {
	EventID       string
	Timestamp     time.Time
	CorrelationID string
	CausationID   string // "" if none
	TaskID        string // "" if not yet task-scoped (e.g. IntentReceived before a task exists)
	Actor         string
	EventType     EventType
	ResultStatus  string
	Sensitivity   Sensitivity
	Payload       map[string]interface{} // only ever persisted if Sensitivity is PUBLIC or INTERNAL
}

// AppendAuditEvent is the ONLY way to write into audit_events — there is
// no exported Update/Delete for this table anywhere in this package (M6
// brief §13's "append-oriented... no ordinary application API silently
// rewrites historical audit events"). event_id is minted here, never
// caller-supplied, so a caller cannot collide with or overwrite an
// existing event's ID.
//
// M6 brief §12's "do not automatically store... full user text, note
// content..." is enforced here, not left to caller discipline: if
// ev.Sensitivity is PERSONAL or HIGHLY_SENSITIVE, ev.Payload is silently
// dropped before the INSERT (never persisted), regardless of what the
// caller passed — the metadata fields (event_type, result_status,
// correlation/causation/task IDs) are always recorded either way, per
// §5's "an event's result_status and metadata are always recorded."
func (s *Store) AppendAuditEvent(ctx context.Context, ev AuditEvent) (string, error) {
	if !ev.EventType.valid() {
		return "", newStoreErr(ErrAuditAppendFailed, "unrecognized event_type", nil)
	}
	if ev.CorrelationID == "" || ev.Actor == "" {
		return "", newStoreErr(ErrAuditAppendFailed, "correlation_id and actor are required", nil)
	}
	if ev.Sensitivity == "" {
		ev.Sensitivity = SensitivityInternal
	}

	id, err := newID()
	if err != nil {
		return "", newStoreErr(ErrAuditAppendFailed, "generating event_id", err)
	}
	ts := ev.Timestamp
	if ts.IsZero() {
		ts = time.Now().UTC()
	}

	var payloadJSON sql.NullString
	if ev.Sensitivity == SensitivityPublic || ev.Sensitivity == SensitivityInternal {
		if ev.Payload != nil {
			b, err := json.Marshal(ev.Payload)
			if err != nil {
				return "", newStoreErr(ErrAuditAppendFailed, "marshaling payload", err)
			}
			payloadJSON = sql.NullString{String: string(b), Valid: true}
		}
	}

	err = s.withTx(ctx, func(tx *sql.Tx) error {
		_, err := tx.ExecContext(ctx, `
			INSERT INTO audit_events (event_id, timestamp, correlation_id, causation_id, task_id, actor, event_type, result_status, sensitivity, payload_json)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
			id, ts.Format(time.RFC3339Nano), ev.CorrelationID, nullIfEmpty(ev.CausationID), nullIfEmpty(ev.TaskID),
			ev.Actor, string(ev.EventType), nullIfEmpty(ev.ResultStatus), string(ev.Sensitivity), payloadJSON)
		if err != nil {
			return newStoreErr(ErrAuditAppendFailed, "inserting audit event", err)
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	return id, nil
}

// GetAuditTrail returns every event for a task, oldest first — the
// mechanism behind STOP-010's "the audit trail alone... is sufficient to
// answer what actually happened."
func (s *Store) GetAuditTrail(ctx context.Context, taskID string) ([]AuditEvent, error) {
	// Ordered by seq (an AUTOINCREMENT column), not by timestamp — two
	// events appended in quick succession can share an identical
	// RFC3339Nano timestamp on a coarse system clock, and tie-breaking on
	// event_id (random hex) would then reorder them nondeterministically.
	// seq reflects true insertion order unconditionally.
	rows, err := s.db.QueryContext(ctx, `
		SELECT event_id, timestamp, correlation_id, causation_id, task_id, actor, event_type, result_status, sensitivity, payload_json
		FROM audit_events WHERE task_id = ? ORDER BY seq ASC`, taskID)
	if err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "querying audit trail", err)
	}
	defer rows.Close()

	var events []AuditEvent
	for rows.Next() {
		ev, err := scanAuditEvent(rows)
		if err != nil {
			return nil, err
		}
		events = append(events, ev)
	}
	if err := rows.Err(); err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "iterating audit trail", err)
	}
	return events, nil
}

func scanAuditEvent(rows *sql.Rows) (AuditEvent, error) {
	var ev AuditEvent
	var causationID, taskID, resultStatus, payloadJSON sql.NullString
	var ts, eventType, sensitivity string
	err := rows.Scan(&ev.EventID, &ts, &ev.CorrelationID, &causationID, &taskID, &ev.Actor,
		&eventType, &resultStatus, &sensitivity, &payloadJSON)
	if err != nil {
		return AuditEvent{}, newStoreErr(ErrPersistenceUnavailable, "scanning audit event", err)
	}
	ev.CausationID = causationID.String
	ev.TaskID = taskID.String
	ev.ResultStatus = resultStatus.String
	ev.EventType = EventType(eventType)
	if !ev.EventType.valid() {
		return AuditEvent{}, newStoreErr(ErrCorruptRecord, "stored audit event has an unrecognized event_type", nil)
	}
	ev.Sensitivity = Sensitivity(sensitivity)
	ev.Timestamp, err = time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return AuditEvent{}, newStoreErr(ErrCorruptRecord, "stored audit event has an unparseable timestamp", err)
	}
	if payloadJSON.Valid {
		if err := json.Unmarshal([]byte(payloadJSON.String), &ev.Payload); err != nil {
			return AuditEvent{}, newStoreErr(ErrCorruptRecord, "stored audit event has an unparseable payload", err)
		}
	}
	return ev, nil
}
