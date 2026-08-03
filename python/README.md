# omni - Python

Python port of the canonical TypeScript implementation.

```sh
PYTHONPATH=.:tests python3 -m unittest discover -s tests
```

## Use

```python
from voxgig_omni import makeRunner

provider = {'subject': lambda name: subjects.get(name)}

R = makeRunner('spec/fib.json', provider)('fib')

R['runset'](R['spec']['basic'], fib)
R['runsetflags'](R['spec']['nulls'], {'null': False}, fibinfo)
```

`OmniError` extends `AssertionError`, so unittest and pytest report a
failing entry as a *failure* rather than an error.

## Layout

| File | Contents |
|---|---|
| `voxgig_omni/runner.py` | the runner |
| `voxgig_omni/util.py` | clone, deep equality, path lookup, walk, stringify |
| `voxgig_omni/__init__.py` | the public API |
| `tests/fib.py` | the system under test |
| `tests/test_fib.py` | the shared conformance suite |

## Notes

- Standard library only.
- `bool` is a subclass of `int` in Python, so `deepequal` and `isnum`
  check for booleans first: `True` never equals `1`.
- Python has no `undefined`, so absence is the `ABSENT` singleton in
  `util.py`. `getpath` returns it for a missing step.
- The provider is a plain dict of callables.
