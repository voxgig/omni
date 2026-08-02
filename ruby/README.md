# omni - Ruby

Ruby port of the canonical TypeScript implementation.

```sh
ruby test/test_fib.rb
```

## Use

```ruby
require 'voxgig_omni'

provider = { subject: ->(name) { SUBJECTS[name] } }

R = VoxgigOmni.make_runner('spec/fib.json', provider).call('fib')

R[:runset].call(R[:spec]['basic'], FIB)
R[:runsetflags].call(R[:spec]['nulls'], { null: false }, FIBINFO)
```

A failing check raises `VoxgigOmni::OmniError`, which minitest, RSpec and
Test::Unit all report as a failure.

## Layout

| File | Contents |
|---|---|
| `lib/voxgig_omni/runner.rb` | the runner |
| `lib/voxgig_omni/util.rb` | clone, deep equality, path lookup, walk, stringify |
| `lib/voxgig_omni.rb` | the public API |
| `test/fib.rb` | the system under test |
| `test/test_fib.rb` | the shared conformance suite |

## Notes

- Standard library only (`json`, `minitest`).
- Spec data uses string keys; flags and the provider use symbol keys, which
  is the idiomatic Ruby split between data and options.
- Absence is the `VoxgigOmni::ABSENT` singleton - `nil` means a real JSON
  null.
