package store

// CurrentSchemaVersion is this package's schema version (M6 brief §24: an
// explicit, simple versioning strategy suitable for Phase 1 — not an
// elaborate multi-year migration platform, but not an unversioned layout
// either). Open() refuses to operate against a database whose recorded
// version differs from this constant (ErrMigrationRequired) rather than
// guessing how to reconcile an unknown layout.
const CurrentSchemaVersion = 1

const schemaDDL = `
CREATE TABLE IF NOT EXISTS schema_meta (
	version INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tasks (
	task_id                 TEXT PRIMARY KEY,
	correlation_id          TEXT NOT NULL,
	causation_id            TEXT,
	actor                   TEXT NOT NULL,
	capability_id           TEXT NOT NULL,
	ir_id                   TEXT NOT NULL,
	state                   TEXT NOT NULL,
	idempotency_key         TEXT NOT NULL,
	cancellation_requested  INTEGER NOT NULL DEFAULT 0,
	created_at              TEXT NOT NULL,
	updated_at              TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_tasks_correlation ON tasks(correlation_id);
CREATE INDEX IF NOT EXISTS idx_tasks_idempotency ON tasks(idempotency_key);

CREATE TABLE IF NOT EXISTS ir_snapshots (
	ir_id                TEXT PRIMARY KEY,
	task_id              TEXT NOT NULL REFERENCES tasks(task_id),
	capability_id        TEXT NOT NULL,
	risk_level           TEXT NOT NULL,
	reversible           INTEGER NOT NULL,
	arguments_json       TEXT NOT NULL,
	arguments_digest     TEXT NOT NULL,
	data_classification  TEXT NOT NULL,
	forgotten            INTEGER NOT NULL DEFAULT 0,
	forgotten_at         TEXT,
	created_at           TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS policy_decisions (
	decision_id       TEXT PRIMARY KEY,
	task_id           TEXT NOT NULL REFERENCES tasks(task_id),
	decision          TEXT NOT NULL,
	required_aal      TEXT NOT NULL,
	reason            TEXT NOT NULL,
	token_id          TEXT,
	token_expires_at  TEXT,
	evaluated_at      TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_policy_decisions_task ON policy_decisions(task_id);

CREATE TABLE IF NOT EXISTS capability_invocations (
	invocation_id   TEXT PRIMARY KEY,
	task_id         TEXT NOT NULL REFERENCES tasks(task_id),
	capability_id   TEXT NOT NULL,
	started_at      TEXT NOT NULL,
	completed_at    TEXT,
	outcome_status  TEXT
);
CREATE INDEX IF NOT EXISTS idx_capability_invocations_task ON capability_invocations(task_id);

CREATE TABLE IF NOT EXISTS verification_results (
	verification_id         TEXT PRIMARY KEY,
	task_id                 TEXT NOT NULL REFERENCES tasks(task_id),
	method                  TEXT NOT NULL,
	started_at              TEXT NOT NULL,
	completed_at            TEXT,
	result                  TEXT,
	side_effect_confirmed   INTEGER
);
CREATE INDEX IF NOT EXISTS idx_verification_results_task ON verification_results(task_id);

CREATE TABLE IF NOT EXISTS audit_events (
	seq             INTEGER PRIMARY KEY AUTOINCREMENT,
	event_id        TEXT NOT NULL UNIQUE,
	timestamp       TEXT NOT NULL,
	correlation_id  TEXT NOT NULL,
	causation_id    TEXT,
	task_id         TEXT,
	actor           TEXT NOT NULL,
	event_type      TEXT NOT NULL,
	result_status   TEXT,
	sensitivity     TEXT NOT NULL,
	payload_json    TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_events_task ON audit_events(task_id);
CREATE INDEX IF NOT EXISTS idx_audit_events_correlation ON audit_events(correlation_id);

CREATE TABLE IF NOT EXISTS idempotency_records (
	idempotency_key    TEXT PRIMARY KEY,
	task_id            TEXT NOT NULL,
	capability_id      TEXT NOT NULL,
	arguments_digest   TEXT NOT NULL,
	status             TEXT NOT NULL,
	created_at         TEXT NOT NULL,
	completed_at       TEXT
);
`
