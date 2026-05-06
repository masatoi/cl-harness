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

A loader lives at `cl-harness/src/develop-bench` (also re-exported
from the `cl-harness` facade). The high-level entry points are:

- `cl-harness:discover-develop-tasks suite-dir` — walk a directory and
  return all `develop-task`s sorted by id.
- `cl-harness:load-develop-task path` — parse a single `develop-task.json`.
- `cl-harness:prepare-develop-task-sandbox task &key into` — copy
  `fixture/` to a fresh tmpdir so re-runs do not pollute the in-repo
  fixture; returns the sandbox path. Caller deletes when done.

A turnkey multi-model `develop-bench` runner is on the v0.4.1
wish-list; for now wire `cl-harness:develop` per task in a shell
script (see `Manual invocation example` below).

## Available fixtures

| Task | Goal (one-line) | Shape |
|---|---|---|
| 100-greet | Add a `greet` function returning `"Hello, NAME!"`. | pure function |
| 101-double | Add a `double` function returning `2 * N`. | pure function |
| 102-counter-class | Add a `counter` defclass with `make-counter`, `increment`, `reset-counter`. | defclass + 2 methods |
| 103-fizz-buzz | Add a `fizz-buzz` function returning the FizzBuzz list of length N. | control flow + strings |
| 104-cache-simple | Add a `simple-cache` defclass with `cache-put` and `cache-get` generic functions. | defclass + 2 generics |
| 105-validate-email | Add a `validate-email` predicate with the standard simple rules. | small parser |
| 106-format-currency | Add a `format-currency` function rendering `"$1,234.56"`. | pure function + edge cases |

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
