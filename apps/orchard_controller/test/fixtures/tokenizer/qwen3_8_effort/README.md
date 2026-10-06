# Exact Qwen3.8 effort template fixture

`chat_template.jinja` is the pinned template from
`mlx-community/Qwen3.8-27B-8bit` revision
`815b83c0df8ffd1d1b5244cf75fd6ef14fca9ef9`:
[publisher source](https://huggingface.co/mlx-community/Qwen3.8-27B-8bit/blob/815b83c0df8ffd1d1b5244cf75fd6ef14fca9ef9/chat_template.jinja).

Its SHA-256 is
`c3cf9e34abf4f9e36c2d72165aa9c132d3e2a725b6c2586aaa3a8af9d7a81041`.
CPU tests use these exact bytes with a minimal fixture tokenizer to verify
effort/default rendering. No model weights are included; this proves neither
native model token counts nor live workload qualification.
