defmodule Orchard.Models.SafeTokenizationPreflightTest do
  use ExUnit.Case, async: false

  alias Orchard.Models.SafeTokenizationPreflight

  setup do
    tmp_dir =
      System.tmp_dir!()
      |> Path.join("safe_tokenization_preflight_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "compatible verdict returns compatible tuple", %{tmp_dir: tmp_dir} do
    helper = write_response_helper!(tmp_dir, compatible_response())

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:compatible, %{template_compatible: true}} =
               SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "product module load creates atoms for all helper reason keys in a fresh child BEAM" do
    code_paths =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.flat_map(&["-pa", &1])

    script = """
    Code.ensure_loaded!(Orchard.Models.SafeTokenizationPreflight)

    for binary_key <- ~w(category literal leaf_class sentinel_index first_diff_offset) do
      _ = :erlang.binary_to_existing_atom(binary_key, :utf8)
    end

    IO.write("OK")
    """

    {output, status} =
      System.cmd("elixir", code_paths ++ ["-e", script], stderr_to_stdout: true)

    assert status == 0 and String.contains?(output, "OK"),
           """
           child BEAM failed to resolve a whitelisted reason atom. This means
           Orchard.Models.SafeTokenizationPreflight is no longer creating one
           of the expected helper reason atoms at compile time. Child output:

           #{output}
           """
  end

  test "helper request transport uses a private temp directory and cleans it up", %{
    tmp_dir: tmp_dir
  } do
    helper = write_private_transport_asserting_helper!(tmp_dir, compatible_response())

    with_tmp_root(tmp_dir, fn ->
      before_dirs = preflight_transport_dirs()

      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:compatible, %{template_compatible: true}} =
                 SafeTokenizationPreflight.run(preflight_input(tmp_dir))
      end)

      assert preflight_transport_dirs() == before_dirs
    end)
  end

  test "timeout path cleans private request transport directory", %{tmp_dir: tmp_dir} do
    helper = write_private_transport_sleeping_helper!(tmp_dir)

    with_tmp_root(tmp_dir, fn ->
      before_dirs = preflight_transport_dirs()

      with_app_env(:bundle_build_preflight_timeout_ms, 100, fn ->
        with_inference_overrides([tokenizer_executable: helper], fn ->
          assert {:error, {:safe_tokenization_preflight_failed, :timeout}} =
                   SafeTokenizationPreflight.run(preflight_input(tmp_dir))
        end)
      end)

      assert preflight_transport_dirs() == before_dirs
    end)
  end

  test "timeout budget is absolute across helper output chunks", %{tmp_dir: tmp_dir} do
    helper = write_dribbling_helper!(tmp_dir)

    with_app_env(:bundle_build_preflight_timeout_ms, 100, fn ->
      with_inference_overrides([tokenizer_executable: helper], fn ->
        started_at = System.monotonic_time(:millisecond)

        assert {:error, {:safe_tokenization_preflight_failed, :timeout}} =
                 SafeTokenizationPreflight.run(preflight_input(tmp_dir))

        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        assert elapsed_ms < 500
      end)
    end)
  end

  test "tokenizer incompatibility verdict returns structured reason", %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "compatible" => false,
          "template_compatible" => true,
          "incompatibility_reason" => %{
            "category" => "reserved_id_persists",
            "literal" => "<reserved>"
          }
        }
      })

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:incompatible,
              %{
                compatible: false,
                template_compatible: true,
                incompatibility_reason: %{category: "reserved_id_persists", literal: "<reserved>"}
              }} = SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "empty_literal verdict accepts empty literal", %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "compatible" => false,
          "template_compatible" => true,
          "incompatibility_reason" => %{"category" => "empty_literal", "literal" => ""}
        }
      })

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:incompatible,
              %{
                compatible: false,
                template_compatible: true,
                incompatibility_reason: %{category: "empty_literal", literal: ""}
              }} = SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "template incompatibility verdict returns template_compatible false", %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "compatible" => false,
          "template_compatible" => false,
          "incompatibility_reason" => %{
            "category" => "dual_render_mismatch",
            "leaf_class" => "message_content",
            "sentinel_index" => 2,
            "first_diff_offset" => 7
          }
        }
      })

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:incompatible,
              %{
                template_compatible: false,
                incompatibility_reason: %{
                  category: "dual_render_mismatch",
                  leaf_class: "message_content",
                  sentinel_index: 2,
                  first_diff_offset: 7
                }
              }} = SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "dual_render_mismatch helper output with first_diff_offset is normalized without raising",
       %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "compatible" => false,
          "template_compatible" => false,
          "incompatibility_reason" => %{
            "category" => "dual_render_mismatch",
            "leaf_class" => "message_content",
            "sentinel_index" => 4,
            "first_diff_offset" => 11
          }
        }
      })

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:incompatible,
              %{
                compatible: false,
                template_compatible: false,
                incompatibility_reason: reason
              }} = SafeTokenizationPreflight.run(preflight_input(tmp_dir))

      assert reason
             |> Map.keys()
             |> Enum.map(&Atom.to_string/1)
             |> Enum.sort() ==
               ~w(category first_diff_offset leaf_class sentinel_index)

      assert Map.fetch!(reason, :erlang.binary_to_existing_atom("category", :utf8)) ==
               "dual_render_mismatch"

      assert Map.fetch!(reason, :erlang.binary_to_existing_atom("leaf_class", :utf8)) ==
               "message_content"

      assert Map.fetch!(reason, :erlang.binary_to_existing_atom("sentinel_index", :utf8)) == 4

      assert Map.fetch!(reason, :erlang.binary_to_existing_atom("first_diff_offset", :utf8)) ==
               11
    end)
  end

  test "empty control token catalog still invokes template-only preflight", %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "compatible" => false,
          "template_compatible" => false,
          "incompatibility_reason" => %{
            "category" => "dual_render_mismatch",
            "leaf_class" => "message_content",
            "sentinel_index" => 0,
            "first_diff_offset" => 1
          }
        }
      })

    input =
      preflight_input(tmp_dir, %{
        control_tokens: [],
        catalog_sha256: hash_catalog([])
      })

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:incompatible,
              %{
                template_compatible: false,
                incompatibility_reason: %{category: "dual_render_mismatch"}
              }} = SafeTokenizationPreflight.run(input)
    end)
  end

  test "helper unavailable returns preflight failure", %{tmp_dir: tmp_dir} do
    missing_executable = Path.join(tmp_dir, "missing-helper")

    with_inference_overrides([tokenizer_executable: missing_executable], fn ->
      assert {:error, {:safe_tokenization_preflight_failed, :unavailable}} =
               SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "helper timeout returns preflight failure", %{tmp_dir: tmp_dir} do
    helper = write_sleeping_helper!(tmp_dir)

    with_app_env(:bundle_build_preflight_timeout_ms, 100, fn ->
      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error, {:safe_tokenization_preflight_failed, :timeout}} =
                 SafeTokenizationPreflight.run(preflight_input(tmp_dir))
      end)
    end)
  end

  test "helper stdout above cap returns preflight failure", %{tmp_dir: tmp_dir} do
    helper = write_oversized_stdout_helper!(tmp_dir, 65)

    with_app_env(:bundle_build_preflight_max_stdout_bytes, 64, fn ->
      with_inference_overrides([tokenizer_executable: helper], fn ->
        assert {:error, {:safe_tokenization_preflight_failed, {:stdout_too_large, 64}}} =
                 SafeTokenizationPreflight.run(preflight_input(tmp_dir))
      end)
    end)
  end

  test "cumulative helper stdout above cap returns preflight failure and cleans transport", %{
    tmp_dir: tmp_dir
  } do
    helper = write_chunked_stdout_helper!(tmp_dir, 20, 4)

    with_tmp_root(tmp_dir, fn ->
      before_dirs = preflight_transport_dirs()

      with_app_env(:bundle_build_preflight_max_stdout_bytes, 64, fn ->
        with_app_env(:bundle_build_preflight_timeout_ms, 2_000, fn ->
          with_inference_overrides([tokenizer_executable: helper], fn ->
            started_at = System.monotonic_time(:millisecond)

            assert {:error, {:safe_tokenization_preflight_failed, {:stdout_too_large, 64}}} =
                     SafeTokenizationPreflight.run(preflight_input(tmp_dir))

            elapsed_ms = System.monotonic_time(:millisecond) - started_at
            assert elapsed_ms < 1_500
          end)
        end)
      end)

      assert preflight_transport_dirs() == before_dirs
    end)
  end

  test "malformed helper response returns invalid_response", %{tmp_dir: tmp_dir} do
    helper = write_malformed_helper!(tmp_dir)

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:error, {:safe_tokenization_preflight_failed, :invalid_response}} =
               SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "invalid helper success responses return invalid_response and fail open", %{
    tmp_dir: tmp_dir
  } do
    base = %{"control_tokens" => ["<reserved>"], "catalog_sha256" => hash_catalog(["<reserved>"])}

    invalid_results = [
      {"compatible true but template incompatible",
       %{
         "compatible" => true,
         "template_compatible" => false,
         "incompatibility_reason" => nil
       }},
      {"compatible true with incompatibility reason",
       %{
         "compatible" => true,
         "template_compatible" => true,
         "incompatibility_reason" => %{"category" => "reserved_id_persists", "literal" => "<x>"}
       }},
      {"incompatible without reason",
       %{"compatible" => false, "template_compatible" => true, "incompatibility_reason" => nil}},
      {"incompatible with unknown category",
       %{
         "compatible" => false,
         "template_compatible" => true,
         "incompatibility_reason" => %{"category" => "not_an_allowed_category"}
       }},
      {"tokenizer incompatibility missing literal",
       %{
         "compatible" => false,
         "template_compatible" => true,
         "incompatibility_reason" => %{"category" => "reserved_id_persists"}
       }},
      {"empty literal with non-empty literal",
       %{
         "compatible" => false,
         "template_compatible" => true,
         "incompatibility_reason" => %{"category" => "empty_literal", "literal" => "<not-empty>"}
       }},
      {"dual render mismatch marked template compatible",
       %{
         "compatible" => false,
         "template_compatible" => true,
         "incompatibility_reason" => %{
           "category" => "dual_render_mismatch",
           "leaf_class" => "message_content",
           "sentinel_index" => 0,
           "first_diff_offset" => 1
         }
       }},
      {"dual render mismatch missing sentinel index",
       %{
         "compatible" => false,
         "template_compatible" => false,
         "incompatibility_reason" => %{
           "category" => "dual_render_mismatch",
           "leaf_class" => "message_content",
           "first_diff_offset" => 1
         }
       }}
    ]

    Enum.each(invalid_results, fn {label, result} ->
      helper =
        write_response_helper!(tmp_dir, %{
          "contract_version" => 3,
          "ok" => true,
          "result" => result
        })

      with_inference_overrides([tokenizer_executable: helper], fn ->
        preflight_result = SafeTokenizationPreflight.run(preflight_input(tmp_dir))

        assert preflight_result ==
                 {:error, {:safe_tokenization_preflight_failed, :invalid_response}},
               label

        assert SafeTokenizationPreflight.merge_into_safe_tokenization_map(base, preflight_result) ==
                 base,
               label
      end)
    end)
  end

  test "helper error envelope returns helper_error reason", %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => false,
        "error" => %{
          "category" => "safe_tokenization_catalog_hash_mismatch",
          "message" => "catalog hash mismatch",
          "details" => %{"expected" => "a", "actual" => "b"}
        }
      })

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:error,
              {:safe_tokenization_preflight_failed,
               {:helper_error,
                %{
                  category: "safe_tokenization_catalog_hash_mismatch",
                  message: "catalog hash mismatch",
                  details: %{"expected" => "a", "actual" => "b"}
                }}}} = SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)
  end

  test "unsupported tokenizer kind short-circuits without helper", %{tmp_dir: tmp_dir} do
    with_inference_overrides([tokenizer_executable: Path.join(tmp_dir, "missing-helper")], fn ->
      assert :disabled =
               SafeTokenizationPreflight.run(
                 preflight_input(tmp_dir, %{tokenizer_kind: "sentencepiece_tokenizer_model"})
               )
    end)
  end

  test "nil or blank tokenizer_config_path short-circuits without helper or error telemetry", %{
    tmp_dir: tmp_dir
  } do
    error_ref = attach_telemetry([:orchard, :tokenizer, :bundle_preflight, :error])

    with_inference_overrides([tokenizer_executable: Path.join(tmp_dir, "missing-helper")], fn ->
      for tokenizer_config_path <- [nil, ""] do
        assert :disabled =
                 SafeTokenizationPreflight.run(
                   preflight_input(tmp_dir, %{tokenizer_config_path: tokenizer_config_path})
                 )
      end
    end)

    refute_receive {^error_ref, [:orchard, :tokenizer, :bundle_preflight, :error], _, _}
  end

  test "disabled config short-circuits without helper", %{tmp_dir: tmp_dir} do
    with_app_env(:bundle_build_eager_preflight_enabled, false, fn ->
      with_inference_overrides([tokenizer_executable: Path.join(tmp_dir, "missing-helper")], fn ->
        assert :disabled = SafeTokenizationPreflight.run(preflight_input(tmp_dir))
      end)
    end)
  end

  test "merge_into_safe_tokenization_map writes only deterministic verdict fields" do
    base = %{"control_tokens" => ["<a>"], "catalog_sha256" => String.duplicate("a", 64)}

    stale =
      Map.put(base, "incompatibility_reason", %{"category" => "empty_literal", "literal" => ""})

    assert SafeTokenizationPreflight.merge_into_safe_tokenization_map(
             stale,
             {:compatible, %{template_compatible: true}}
           ) ==
             Map.merge(base, %{"compatible" => true, "template_compatible" => true})

    assert SafeTokenizationPreflight.merge_into_safe_tokenization_map(
             stale,
             {:incompatible,
              %{
                compatible: false,
                template_compatible: false,
                incompatibility_reason: %{
                  category: "dual_render_mismatch",
                  leaf_class: "message_content",
                  sentinel_index: 0,
                  first_diff_offset: 1
                }
              }}
           ) ==
             Map.merge(base, %{
               "compatible" => false,
               "template_compatible" => false,
               "incompatibility_reason" => %{
                 "category" => "dual_render_mismatch",
                 "leaf_class" => "message_content",
                 "sentinel_index" => 0,
                 "first_diff_offset" => 1
               }
             })

    assert SafeTokenizationPreflight.merge_into_safe_tokenization_map(base, :disabled) == base

    assert SafeTokenizationPreflight.merge_into_safe_tokenization_map(
             base,
             {:error, {:safe_tokenization_preflight_failed, :timeout}}
           ) == base
  end

  test "emits start and stop telemetry with stable shape", %{tmp_dir: tmp_dir} do
    helper =
      write_response_helper!(tmp_dir, %{
        "contract_version" => 3,
        "ok" => true,
        "result" => %{
          "compatible" => true,
          "template_compatible" => true,
          "incompatibility_reason" => nil
        }
      })

    start_ref = attach_telemetry([:orchard, :tokenizer, :bundle_preflight, :start])
    stop_ref = attach_telemetry([:orchard, :tokenizer, :bundle_preflight, :stop])

    with_inference_overrides([tokenizer_executable: helper], fn ->
      assert {:compatible, %{template_compatible: true}} =
               SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)

    assert_receive {^start_ref, [:orchard, :tokenizer, :bundle_preflight, :start], measurements,
                    metadata}

    assert is_integer(measurements.system_time)
    assert metadata.bundle_dir == tmp_dir
    assert metadata.tokenizer_kind == "huggingface_tokenizer_json"

    assert_receive {^stop_ref, [:orchard, :tokenizer, :bundle_preflight, :stop], measurements,
                    metadata}

    assert is_integer(measurements.duration_ms)
    assert metadata.bundle_dir == tmp_dir
    assert metadata.tokenizer_kind == "huggingface_tokenizer_json"
    assert metadata.result == :compatible
  end

  test "emits error telemetry with structured reason", %{tmp_dir: tmp_dir} do
    event_ref = attach_telemetry([:orchard, :tokenizer, :bundle_preflight, :error])

    with_inference_overrides([tokenizer_executable: Path.join(tmp_dir, "missing-helper")], fn ->
      assert {:error, {:safe_tokenization_preflight_failed, :unavailable}} =
               SafeTokenizationPreflight.run(preflight_input(tmp_dir))
    end)

    assert_receive {^event_ref, [:orchard, :tokenizer, :bundle_preflight, :error], measurements,
                    metadata}

    assert is_integer(measurements.duration_ms)
    assert metadata.bundle_dir == tmp_dir
    assert metadata.tokenizer_kind == "huggingface_tokenizer_json"
    assert metadata.reason == :unavailable
  end

  defp preflight_input(tmp_dir, overrides \\ %{}) do
    %{
      bundle_dir: tmp_dir,
      tokenizer_kind: "huggingface_tokenizer_json",
      tokenizer_path: Path.join(tmp_dir, "tokenizer.json"),
      tokenizer_config_path: Path.join(tmp_dir, "tokenizer_config.json"),
      chat_template_path: Path.join(tmp_dir, "chat_template.jinja"),
      control_tokens: ["<reserved>"],
      catalog_sha256: hash_catalog(["<reserved>"])
    }
    |> Map.merge(overrides)
  end

  defp compatible_response do
    %{
      "contract_version" => 3,
      "ok" => true,
      "result" => %{
        "compatible" => true,
        "template_compatible" => true,
        "incompatibility_reason" => nil
      }
    }
  end

  defp write_response_helper!(dir, response) do
    write_executable!(dir, "preflight-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    cat <<'JSON'
    #{Jason.encode!(response)}
    JSON
    """)
  end

  defp write_private_transport_asserting_helper!(dir, response) do
    write_executable!(dir, "private-transport-preflight-helper.sh", """
    #!/bin/sh
    set -eu
    transport_dir=""

    for candidate in "${TMPDIR:-/tmp}"/orchard-tokenizer-preflight-*; do
      if [ -d "$candidate" ]; then
        transport_dir="$candidate"
        break
      fi
    done

    if [ -z "$transport_dir" ]; then
      exit 42
    fi

    if [ ! -f "$transport_dir/request.json" ] || [ -L "$transport_dir/request.json" ]; then
      exit 43
    fi

    mode=$(stat -f %Lp "$transport_dir" 2>/dev/null || stat -c %a "$transport_dir" 2>/dev/null || printf unknown)

    if [ "$mode" != "700" ]; then
      exit 44
    fi

    payload=$(cat)

    case "$payload" in
      *'"command":"preflight_safe_tokenization"'*) ;;
      *) exit 45 ;;
    esac

    cat <<'JSON'
    #{Jason.encode!(response)}
    JSON
    """)
  end

  defp write_private_transport_sleeping_helper!(dir) do
    write_executable!(dir, "private-transport-sleeping-preflight-helper.sh", """
    #!/bin/sh
    set -eu
    transport_dir=""

    for candidate in "${TMPDIR:-/tmp}"/orchard-tokenizer-preflight-*; do
      if [ -d "$candidate" ]; then
        transport_dir="$candidate"
        break
      fi
    done

    if [ -z "$transport_dir" ] || [ ! -f "$transport_dir/request.json" ]; then
      exit 42
    fi

    cat >/dev/null
    sleep 1
    """)
  end

  defp write_dribbling_helper!(dir) do
    write_executable!(dir, "dribbling-preflight-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    for _ in 1 2 3 4 5; do
      printf x
      sleep 0.05
    done
    """)
  end

  defp write_sleeping_helper!(dir) do
    write_executable!(dir, "sleeping-preflight-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    sleep 1
    """)
  end

  defp write_malformed_helper!(dir) do
    write_executable!(dir, "malformed-preflight-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    printf 'not-json\n'
    """)
  end

  defp write_oversized_stdout_helper!(dir, byte_count) do
    payload = String.duplicate("x", byte_count)

    write_executable!(dir, "oversized-stdout-preflight-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    printf '#{payload}'
    """)
  end

  defp write_chunked_stdout_helper!(dir, chunk_bytes, chunks) do
    payload = String.duplicate("x", chunk_bytes)

    chunk_commands =
      Enum.map_join(1..chunks, "\n", fn _index -> "printf '#{payload}'\nsleep 0.02" end)

    write_executable!(dir, "chunked-stdout-preflight-helper.sh", """
    #!/bin/sh
    cat >/dev/null
    #{chunk_commands}
    """)
  end

  defp write_executable!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, content)
    File.chmod!(path, 0o755)
    path
  end

  defp attach_telemetry(event) do
    parent = self()
    ref = make_ref()

    :telemetry.attach(
      inspect(ref),
      event,
      fn event, measurements, metadata, _config ->
        send(parent, {ref, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(inspect(ref)) end)
    ref
  end

  defp with_inference_overrides(overrides, fun) when is_function(fun, 0) do
    previous_inference = Application.fetch_env!(:orchard_controller, :inference)

    Application.put_env(
      :orchard_controller,
      :inference,
      Keyword.merge(previous_inference, overrides)
    )

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :inference, previous_inference)
    end
  end

  defp with_tmp_root(tmp_dir, fun) when is_function(fun, 0) do
    previous_tmpdir = System.get_env("TMPDIR")
    System.put_env("TMPDIR", tmp_dir)

    try do
      fun.()
    after
      if is_binary(previous_tmpdir) do
        System.put_env("TMPDIR", previous_tmpdir)
      else
        System.delete_env("TMPDIR")
      end
    end
  end

  defp preflight_transport_dirs do
    System.tmp_dir!()
    |> File.ls!()
    |> Enum.filter(fn entry ->
      path = Path.join(System.tmp_dir!(), entry)
      String.starts_with?(entry, "orchard-tokenizer-preflight-") and File.dir?(path)
    end)
    |> Enum.sort()
  end

  defp with_app_env(key, value, fun) when is_function(fun, 0) do
    previous = Application.get_env(:orchard_controller, key, :orchard_missing_env)
    Application.put_env(:orchard_controller, key, value)

    try do
      fun.()
    after
      case previous do
        :orchard_missing_env -> Application.delete_env(:orchard_controller, key)
        previous_value -> Application.put_env(:orchard_controller, key, previous_value)
      end
    end
  end

  defp hash_catalog(control_tokens) do
    control_tokens
    |> Enum.intersperse(<<0>>)
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
