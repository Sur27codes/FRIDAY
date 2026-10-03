package store

import (
	"context"
	"crypto/rand"
	"database/sql"
	"errors"
	"fmt"

	_ "modernc.org/sqlite" // registers the "sqlite" database/sql driver
)

// Store wraps a *sql.DB against the schema in schema.go. All state
// mutations (task transitions, audit appends, idempotency registration)
// go through this type's methods — there is no exported way to reach the
// underlying *sql.DB and issue an arbitrary statement, which is the
// concrete mechanism behind "no ordinary application API silently
// rewrites historical audit events" (M6 brief §13): the only INSERT into
// audit_events this package exposes is AppendAuditEvent, and there is no
// UpdateAuditEvent/DeleteAuditEvent method anywhere in this package.
type Store struct {
	db *sql.DB
}

// Open opens (creating if necessary) a SQLite database at path and
// verifies/applies the schema. WAL mode + synchronous=FULL is used
// deliberately for the strongest practical local crash-durability SQLite
// offers (M6 brief §16's crash-recovery emphasis outweighs the write-
// latency cost at Phase-1's local, low-volume scale) — busy_timeout gives
// concurrent local writers a bounded wait instead of an immediate
// SQLITE_BUSY failure (M6 brief §25).
func Open(path string) (*Store, error) {
	dsn := path + "?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)&_pragma=synchronous(FULL)&_pragma=foreign_keys(ON)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, newStoreErr(ErrPersistenceUnavailable, "opening database", err)
	}
	db.SetMaxOpenConns(1) // modernc.org/sqlite + WAL: one writer connection avoids SQLITE_BUSY storms under this package's own transaction discipline; correctness relies on real transactions below, not on connection count, but this keeps behavior predictable for a local, single-process Phase-1 store

	if err := db.Ping(); err != nil {
		db.Close()
		return nil, newStoreErr(ErrPersistenceUnavailable, "pinging database", err)
	}

	s := &Store{db: db}
	if err := s.ensureSchema(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) ensureSchema() error {
	var count int
	err := s.db.QueryRow(`SELECT count(*) FROM sqlite_master WHERE type='table' AND name='schema_meta'`).Scan(&count)
	if err != nil {
		return newStoreErr(ErrPersistenceUnavailable, "checking schema_meta existence", err)
	}

	if count == 0 {
		// Fresh database: apply the full schema and record the version,
		// atomically.
		tx, err := s.db.Begin()
		if err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "beginning schema migration", err)
		}
		if _, err := tx.Exec(schemaDDL); err != nil {
			tx.Rollback()
			return newStoreErr(ErrMigrationRequired, "applying initial schema", err)
		}
		if _, err := tx.Exec(`INSERT INTO schema_meta (version) VALUES (?)`, CurrentSchemaVersion); err != nil {
			tx.Rollback()
			return newStoreErr(ErrMigrationRequired, "recording schema version", err)
		}
		if err := tx.Commit(); err != nil {
			return newStoreErr(ErrPersistenceUnavailable, "committing schema migration", err)
		}
		return nil
	}

	var version int
	if err := s.db.QueryRow(`SELECT version FROM schema_meta LIMIT 1`).Scan(&version); err != nil {
		return newStoreErr(ErrCorruptRecord, "reading schema_meta.version", err)
	}
	if version != CurrentSchemaVersion {
		// Fail closed: an unrecognized schema version is never silently
		// treated as compatible (M6 brief §24).
		return newStoreErr(ErrMigrationRequired,
			fmt.Sprintf("database schema is at version %d, this build requires version %d", version, CurrentSchemaVersion), nil)
	}
	return nil
}

// newID generates a random hex identifier for records this package
// itself must mint (audit events, decision/invocation/verification
// records) — task_id/ir_id are always caller-supplied (the not-yet-built
// Runtime, or a test harness), matching the established pattern from
// M3/M4. Same technique as policy-engine's newTokenID: crypto/rand, no
// new dependency for something the standard library already does well.
func newID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x", b), nil
}

// withTx runs fn inside a real database transaction, committing on
// success and rolling back on any error or panic — the mechanism behind
// M6 brief §15's transactional-consistency requirement (a task
// transition and its required audit event are never observably
// half-done).
func (s *Store) withTx(ctx context.Context, fn func(tx *sql.Tx) error) (err error) {
	tx, beginErr := s.db.BeginTx(ctx, nil)
	if beginErr != nil {
		return newStoreErr(ErrPersistenceUnavailable, "beginning transaction", beginErr)
	}
	defer func() {
		if p := recover(); p != nil {
			tx.Rollback()
			panic(p)
		}
	}()

	if err = fn(tx); err != nil {
		tx.Rollback()
		return err
	}
	if cerr := tx.Commit(); cerr != nil {
		if errors.Is(cerr, sql.ErrTxDone) {
			return newStoreErr(ErrPersistenceConflict, "transaction already completed", cerr)
		}
		return newStoreErr(ErrPersistenceUnavailable, "committing transaction", cerr)
	}
	return nil
}
