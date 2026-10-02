# Implementation rationale

The JSON specification supplies the same test cases to every port. The runner must remain independent of the library it tests; otherwise its own comparison and traversal helpers can hide defects in that library.

Explicit absence and null handling belong to the specification's runner flags. Do not collapse them in groups that distinguish them.

Source: [agent guide](AGENTS.md).

Validate corpus shape separately from generating corpus JSON. Unifying a shape into the build can omit optional empty containers and change what an entry asserts. Shape checks constrain field names and types; runners enforce cross-field semantics. Artifact checks must also verify the corpus version marker is present, because unification can fill a missing value.

The Rust library sources read no file outside `rust/src/` at compile time. `@voxgig/sdkgen` vendors those files alone into each generated SDK as a module, where an `include_str!` of a document beside the crate does not resolve. The crate root therefore carries no crate-level documentation: a description and a usage example are in `rust/README.md`, and `rust/tests/fib.rs` exercises the same API.
