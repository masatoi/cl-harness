# develop-benchmarks/

Greenfield-shaped fixtures for `cl-harness:develop` (Phase P3 of the
planner+orchestrator extension; see
`docs/notes/2026-05-06-planner-orchestrator.md`).

Each subdirectory under here is a tiny ASDF project whose **source is
intentionally empty** (only a `defpackage` and `in-package`) and whose
**tests file is the same — empty stub**, ready to receive
planner-authored deftest forms via `cl-harness:develop`'s
`:test-file` argument.

A `develop-task.json` per subdirectory captures the canonical inputs:

```json
{
  "id":          "<task-id>",
  "goal":        "<one-paragraph natural-language goal>",
  "system":      "<asdf system name>",
  "test-system": "<asdf test-system name>",
  "test-file":   "<relative path; planner deftest forms get appended here>",
  "fixture-dir": "fixture"
}
```

There is **no benchmark runner yet**: these fixtures are starter
material so callers can copy one to a tmpdir and feed it to
`cl-harness:develop` manually. A future `cl-harness:develop-bench`
analogous to `cl-harness:bench` is on the v0.4 wish-list.

## Available fixtures

| Task | Goal (one-line) |
|---|---|
| 100-greet | Add a `greet` function returning `"Hello, NAME!"`, exported from package `greet`. |
| 101-double | Add a `double` function returning `2 * N`, exported from package `double`. |

## Manual invocation example

```bash
SANDBOX=$(mktemp -d)
cp -r develop-benchmarks/100-greet/fixture/. "$SANDBOX"

cl-harness develop \
  --goal "$(jq -r .goal develop-benchmarks/100-greet/develop-task.json)" \
  --project-root "$SANDBOX" \
  --system greet \
  --test-system greet/tests \
  --test-file "$SANDBOX/tests/main-test.lisp" \
  --max-replans 3
```

(Or programmatically via `(cl-harness:develop :goal ... :project-root
... ...)`.)
