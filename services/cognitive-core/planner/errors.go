package planner

import "fmt"

type ErrorCode string

const (
	ErrPlanFailed ErrorCode = "PLAN_FAILED"
	ErrCancelled  ErrorCode = "CANCELLED"
)

type PlanError struct {
	Code    ErrorCode
	Message string
}

func (e *PlanError) Error() string {
	return fmt.Sprintf("[%s] %s", e.Code, e.Message)
}
