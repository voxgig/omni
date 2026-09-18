# Implementation rationale

The JSON specification supplies the same test cases to every port. The runner must remain independent of the library it tests; otherwise its own comparison and traversal helpers can hide defects in that library.

Explicit absence and null handling belong to the specification's runner flags. Do not collapse them in groups that distinguish them.

The Rust API example remains compiled as a documentation test through [the included crate documentation](rust/COMMENT-NOTES.md).

Source: [agent guide](AGENTS.md).

Validate corpus shape separately from generating corpus JSON. Unifying a shape into the build can omit optional empty containers and change what an entry asserts. Shape checks constrain field names and types; runners enforce cross-field semantics. Artifact checks must also verify the corpus version marker is present, because unification can fill a missing value.
