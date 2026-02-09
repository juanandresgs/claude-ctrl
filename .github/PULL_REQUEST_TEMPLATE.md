## What Changed

Brief description of the change and its purpose.

## Type

- [ ] New hook
- [ ] Hook bug fix
- [ ] Agent definition change
- [ ] Skill addition/modification
- [ ] Settings/configuration change
- [ ] Documentation
- [ ] CI/testing

## Checklist

- [ ] Tested manually with `echo '...' | bash hooks/<name>.sh`
- [ ] Updated `hooks/HOOKS.md` if adding/modifying a hook
- [ ] Added test fixture(s) in `tests/fixtures/` if applicable
- [ ] No breaking changes to existing hooks
- [ ] `python3 -m json.tool settings.json` validates (if settings changed)
- [ ] `shellcheck hooks/<name>.sh` passes (if hook changed)

## Manual Test Output

```bash
# Command used:
echo '{"tool_name":"...","tool_input":{...}}' | bash hooks/<name>.sh

# Stdout:
(paste output)

# Exit code:
(0, 1, or 2)
```

## Notes

Anything reviewers should know: chain position reasoning, interaction with other hooks, edge cases.
