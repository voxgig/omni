# omni - PHP

PHP port of the canonical TypeScript implementation.

```sh
php test/run.php
```

## Use

```php
use Voxgig\Omni\Runner;

$provider = ['subject' => fn(string $name) => $subjects[$name] ?? null];

$R = (Runner::makeRunner('spec/fib.json', $provider))('fib');

($R['runset'])($R['spec']['basic'], $fib);
($R['runsetflags'])($R['spec']['nulls'], ['null' => false], $fibinfo);
```

A failing check throws `Voxgig\Omni\OmniError`, which PHPUnit reports as a
failure. `test/run.php` is a dependency-free harness so that `make test`
needs no composer install.

## Layout

| File | Contents |
|---|---|
| `src/Runner.php` | the runner |
| `src/Util.php` | clone, deep equality, path lookup, walk, stringify |
| `test/Fib.php` | the system under test |
| `test/run.php` | the shared conformance suite |

## Notes

- Standard library only; PHP 8.1+ (`array_is_list`).
- JSON decodes to associative arrays, so an empty map and an empty list are
  the same PHP value. This is the one spec distinction the PHP port cannot
  make; see `DOCS.md`, per-port variance.
- Absence is the `Voxgig\Omni\Absent` singleton.
