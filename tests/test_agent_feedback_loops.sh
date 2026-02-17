#!/usr/bin/env bash
# Test suite for issue #28 — agent feedback loops
#
# @decision DEC-TEST-028
# @title Test agent feedback loop requirements
# @status accepted
# @rationale Validates that agent instruction files contain feedback checkpoints.
#   Planner gets strong gates (Alternatives Gate, Challenge Requirements) because
#   that's where decisions happen. Implementer gets Output Rules and judgment-based
#   check-ins — not perfunctory gates that slow down execution of approved plans.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
AGENTS_DIR="$PROJECT_ROOT/agents"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

pass() {
  echo -e "${GREEN}✓${NC} $1"
  TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
  echo -e "${RED}✗${NC} $1"
  TESTS_FAILED=$((TESTS_FAILED + 1))
}

info() {
  echo -e "${YELLOW}ℹ${NC} $1"
}

# Test implementer.md feedback loops
test_implementer_output_rules() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q "Always paste raw test output" "$AGENTS_DIR/implementer.md" && \
     grep -q 'never say "tests pass"' "$AGENTS_DIR/implementer.md"; then
    pass "Implementer has explicit output rules"
  else
    fail "Implementer missing explicit output rules"
  fi
}

test_implementer_judgment_not_gates() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q "judgment, not gates" "$AGENTS_DIR/implementer.md" && \
     grep -q "Don't pause perfunctorily" "$AGENTS_DIR/implementer.md"; then
    pass "Implementer uses judgment-based check-ins, not rigid gates"
  else
    fail "Implementer missing judgment-based check-in guidance"
  fi
}

# Test planner.md feedback loops
test_planner_alternatives_gate() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q "Alternatives Gate" "$AGENTS_DIR/planner.md" || \
     grep -q "2+ reasonable approaches" "$AGENTS_DIR/planner.md"; then
    pass "Planner has Alternatives Gate section"
  else
    fail "Planner missing Alternatives Gate section"
  fi
}

test_planner_challenge_requirements() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q "Challenge Requirements" "$AGENTS_DIR/planner.md" || \
     grep -q "right scope" "$AGENTS_DIR/planner.md"; then
    pass "Planner has Challenge Requirements section"
  else
    fail "Planner missing Challenge Requirements section"
  fi
}

# Test tester.md feedback loops
test_tester_no_summarize() {
  TESTS_RUN=$((TESTS_RUN + 1))
  if grep -q "Never summarize output" "$AGENTS_DIR/tester.md" || \
     grep -q "paste it verbatim" "$AGENTS_DIR/tester.md"; then
    pass "Tester has explicit no-summarize rule"
  else
    fail "Tester missing explicit no-summarize rule"
  fi
}

# Run all tests
info "Testing implementer.md feedback improvements..."
test_implementer_output_rules
test_implementer_judgment_not_gates

info "Testing planner.md feedback improvements..."
test_planner_alternatives_gate
test_planner_challenge_requirements

info "Testing tester.md feedback improvements..."
test_tester_no_summarize

# Summary
echo ""
echo "═══════════════════════════════════════"
echo "Test Results"
echo "═══════════════════════════════════════"
echo "Total:  $TESTS_RUN"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo "═══════════════════════════════════════"

if [ $TESTS_FAILED -eq 0 ]; then
  echo -e "${GREEN}All tests passed!${NC}"
  exit 0
else
  echo -e "${RED}Some tests failed.${NC}"
  exit 1
fi
