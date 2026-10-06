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

## Attribution and licence

The template is reproduced unchanged from the mlx-community conversion of
Qwen3.8-27B, developed by the Qwen team / Alibaba Cloud. The pinned
[conversion model card](https://huggingface.co/mlx-community/Qwen3.8-27B-8bit/blob/815b83c0df8ffd1d1b5244cf75fd6ef14fca9ef9/README.md)
declares Apache-2.0. The original model's
[Apache-2.0 licence](https://huggingface.co/Qwen/Qwen3.8-27B/blob/1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0/LICENSE)
identifies Copyright 2026 Alibaba Cloud; a copy is retained as
[LICENSE](LICENSE) alongside this fixture. No upstream NOTICE file was present
in either inspected repository. The template bytes and their identity are
unchanged; this README supplies attribution without modifying the fixture.
