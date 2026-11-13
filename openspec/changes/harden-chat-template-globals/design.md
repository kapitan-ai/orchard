## Scope

Apply the limited dictionary callable and validated Namespace-subclass pattern
used by Transformers 5.22.2 to Orchard's own `ProvenanceSandbox`. Updating an
upstream renderer alone would not change Orchard's renderer.

The dictionary facade returns ordinary dictionaries and supports `fromkeys`;
it is not a Python type. The Namespace subclass validates constructor inputs
and item assignment, which is how Jinja compiles namespace attribute writes.
It keeps Jinja's namespace identity and permits ordinary names, including `self`.
Existing Jinja attribute-read restrictions remain in force. Validation errors
do not echo template-controlled names.

Marker-aware calls admit the limited constructors and dictionary `fromkeys`
without permitting new transformations of caller strings. No blanket ban on
underscore-prefixed dictionary keys applies: tool schemas and caller data may
legitimately contain those keys.

## Alternatives and boundaries

Removing the dictionary and namespace globals outright would break legitimate
templates. Relying only on attribute-read checks would not constrain namespace
construction or assignment. A Python upgrade and a template-trust policy are
separate owner decisions, not consequences of this implementation.

## Validation

Exercise dictionary restrictions and namespace constructor/assignment rejection
in both plain and marker-aware rendering. Verify the regressions fail before
the change. Preserve positive dictionary and namespace operations, marker
envelopes, and the existing real-template qualification fixtures. Run Ruff,
the tokenizer suite and coverage; compare qualified render bytes and token
results against the unchanged renderer. This does not establish model runtime
qualification or general sandbox isolation against arbitrary Python objects.
