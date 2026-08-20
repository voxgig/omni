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

## struct compatibility

[`lib/voxgig_omni/compat/struct.rb`](lib/voxgig_omni/compat/struct.rb)
exposes omni behind the exact runner API used by `voxgig/struct`'s Ruby
port, so that port switches over by changing one require:

```diff
-require_relative 'voxgig_runner'
+require_relative 'omni'
```

where `omni.rb` resolves the local omni checkout and mixes the shim into
struct's own `VoxgigRunner` namespace. The shim also translates the two
places where the ports' value models differ: struct's Ruby tests write
flags with string keys (`{ 'null' => false }`) where omni uses symbols,
and struct models absence with `VoxgigStruct::UNDEF` where omni uses
`VoxgigOmni::ABSENT`.

## Layout

| File | Contents |
|---|---|
| `lib/voxgig_omni/runner.rb` | the runner |
| `lib/voxgig_omni/util.rb` | clone, deep equality, path lookup, walk, stringify |
| `lib/voxgig_omni.rb` | the public API |
| `lib/voxgig_omni/compat/struct.rb` | drop-in replacement for struct's runner |
| `test/fib.rb` | the system under test |
| `test/test_fib.rb` | the shared conformance suite |

## Notes

- Standard library only (`json`, `minitest`).
- Spec data uses string keys; flags and the provider use symbol keys, which
  is the idiomatic Ruby split between data and options.
- Absence is the `VoxgigOmni::ABSENT` singleton - `nil` means a real JSON
  null.
