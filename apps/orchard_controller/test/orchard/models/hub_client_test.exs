defmodule Orchard.Models.HubClientTest do
  use ExUnit.Case, async: false

  alias Orchard.Models.HubClient

  setup do
    previous_hf = Application.fetch_env!(:orchard_controller, :hf)
    stub_name = dynamic_stub_name()

    Application.put_env(:orchard_controller, :hf, base_hf_config(stub_name))

    on_exit(fn ->
      Application.put_env(:orchard_controller, :hf, previous_hf)
    end)

    %{stub_name: stub_name}
  end

  test "search_models/2 sends the required HF query params", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/api/models"
      assert conn.query_params["filter"] == "mlx"
      assert conn.query_params["pipeline_tag"] == "text-generation"
      assert conn.query_params["sort"] == "downloads"
      assert conn.query_params["direction"] == "-1"
      assert conn.query_params["limit"] == "20"
      assert conn.query_params["search"] == "Qwen"
      assert Plug.Conn.get_req_header(conn, "authorization") == []

      json_response(conn, 200, [%{"id" => "mlx-community/Qwen2.5-7B-Instruct-4bit"}])
    end)

    assert {:ok, [%{repo_id: "mlx-community/Qwen2.5-7B-Instruct-4bit"}]} =
             HubClient.search_models("Qwen", [])
  end

  test "search_models/2 omits the search param when the query is blank", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      refute Map.has_key?(conn.query_params, "search")
      json_response(conn, 200, [%{"id" => "mlx-community/blank-search"}])
    end)

    assert {:ok, [%{repo_id: "mlx-community/blank-search"}]} =
             HubClient.search_models("   ", [])
  end

  test "search_models/2 sends a bearer token only when configured", %{stub_name: stub_name} do
    with_hf_overrides([token: "secret-token"], fn ->
      Req.Test.stub(stub_name, fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret-token"]
        json_response(conn, 200, [%{"id" => "mlx-community/authed"}])
      end)

      assert {:ok, [%{repo_id: "mlx-community/authed"}]} = HubClient.search_models(nil, [])
    end)
  end

  test "search_models/2 returns invalid_options for non-keyword opts" do
    assert {:error,
            %{status: :error, code: "invalid_options", message: "Hub client options are invalid."}} =
             HubClient.search_models(nil, %{})
  end

  test "search_models/2 returns invalid_options for unsupported keyword opts", %{
    stub_name: stub_name
  } do
    Req.Test.stub(stub_name, fn _conn ->
      flunk("search_models/2 should reject unsupported opts before making a request")
    end)

    assert {:error,
            %{status: :error, code: "invalid_options", message: "Hub client options are invalid."}} =
             HubClient.search_models(nil, unsupported: true)
  end

  test "search_models/2 derives the API base URL from base_url when needed", %{
    stub_name: stub_name
  } do
    with_hf_overrides([api_base_url: nil], fn ->
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/api/models"
        json_response(conn, 200, [%{"id" => "mlx-community/base-url-fallback"}])
      end)

      assert {:ok, [%{repo_id: "mlx-community/base-url-fallback"}]} =
               HubClient.search_models(nil, [])
    end)
  end

  test "search_models/2 normalizes string-valued gated flags as gated", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 200, [%{"id" => "mlx-community/gated-model", "gated" => "manual"}])
    end)

    assert {:ok, [%{repo_id: "mlx-community/gated-model", gated: true}]} =
             HubClient.search_models(nil, [])
  end

  test "search_models/2 normalizes missing optional fields safely", %{stub_name: stub_name} do
    payload = [
      %{
        "id" => "lmstudio-community/phi-4bit",
        "downloads" => "42"
      }
    ]

    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 200, payload)
    end)

    assert {:ok,
            [
              %{
                repo_id: "lmstudio-community/phi-4bit",
                author: "lmstudio-community",
                downloads: 42,
                likes: 0,
                tags: [],
                pipeline_tag: nil,
                library_name: nil,
                used_storage_bytes: nil,
                last_modified: nil,
                gated: false
              }
            ]} = HubClient.search_models(nil, [])
  end

  test "search_models/2 drops malformed result entries without repo ids", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 200, [%{"downloads" => 1}, %{"modelId" => "mlx-community/ok-model"}])
    end)

    assert {:ok, [%{repo_id: "mlx-community/ok-model"}]} = HubClient.search_models(nil, [])
  end

  test "get_model_detail/1 normalizes detail payloads and sorts siblings", %{stub_name: stub_name} do
    payload = %{
      "id" => "mlx-community/Qwen2.5-7B-Instruct-4bit",
      "sha" => "abc123",
      "author" => "mlx-community",
      "downloads" => 16419,
      "likes" => "11",
      "tags" => ["mlx", "chat", "4bit"],
      "pipeline_tag" => "text-generation",
      "library_name" => "mlx",
      "usedStorage" => "4284346255",
      "lastModified" => "2024-11-06T13:47:36.000Z",
      "gated" => "manual",
      "cardData" => %{
        "license" => "apache-2.0",
        "language" => ["en"],
        "base_model" => "Qwen/Qwen2.5-7B"
      },
      "config" => %{
        "model_type" => "qwen2",
        "architectures" => ["Qwen2ForCausalLM"],
        "max_position_embeddings" => 32768,
        "quantization" => %{"bits" => 8}
      },
      "siblings" => [
        %{"rfilename" => "tokenizer.json", "size" => 200},
        %{"rfilename" => "config.json", "size" => "100"}
      ]
    }

    Req.Test.stub(stub_name, fn conn ->
      assert conn.request_path == "/api/models/mlx-community/Qwen2.5-7B-Instruct-4bit"
      json_response(conn, 200, payload)
    end)

    assert {:ok, detail} = HubClient.get_model_detail("mlx-community/Qwen2.5-7B-Instruct-4bit")

    assert detail.repo_id == "mlx-community/Qwen2.5-7B-Instruct-4bit"
    assert detail.revision_sha == "abc123"
    assert detail.gated == true
    assert detail.downloads == 16_419
    assert detail.likes == 11
    assert detail.used_storage_bytes == 4_284_346_255

    assert detail.metadata_summary == %{
             license: "apache-2.0",
             languages: ["en"],
             base_models: ["Qwen/Qwen2.5-7B"]
           }

    assert detail.config_summary == %{
             model_type: "qwen2",
             architectures: ["Qwen2ForCausalLM"],
             context_window_tokens: 32_768,
             quantization_bits: 8
           }

    assert detail.siblings == [
             %{path: "config.json", size_bytes: 100},
             %{path: "tokenizer.json", size_bytes: 200}
           ]
  end

  test "get_model_detail/1 uses the context window fallback chain", %{stub_name: stub_name} do
    payloads = [
      {"mlx-community/n-positions",
       %{"id" => "mlx-community/n-positions", "config" => %{"n_positions" => 8192}}},
      {"mlx-community/max-sequence-length",
       %{
         "id" => "mlx-community/max-sequence-length",
         "config" => %{"max_sequence_length" => "4096"}
       }}
    ]

    Enum.each(payloads, fn {repo_id, payload} ->
      Req.Test.stub(stub_name, fn conn ->
        assert conn.request_path == "/api/models/#{repo_id}"
        json_response(conn, 200, payload)
      end)

      assert {:ok, detail} = HubClient.get_model_detail(repo_id)

      expected =
        case repo_id do
          "mlx-community/n-positions" -> 8192
          _other -> 4096
        end

      assert detail.config_summary.context_window_tokens == expected
    end)
  end

  test "get_model_detail/1 falls back to tags or repo name for quantization bits", %{
    stub_name: stub_name
  } do
    payload = %{
      "id" => "mlx-community/Phi-3-4bit",
      "tags" => ["mlx", "4bit"],
      "config" => %{"model_type" => "phi3"}
    }

    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 200, payload)
    end)

    assert {:ok, detail} = HubClient.get_model_detail("mlx-community/Phi-3-4bit")
    assert detail.config_summary.quantization_bits == 4
  end

  test "get_model_detail/1 returns nil quantization bits when no signal is present", %{
    stub_name: stub_name
  } do
    payload = %{
      "id" => "mlx-community/Phi-3",
      "config" => %{"model_type" => "phi3"}
    }

    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 200, payload)
    end)

    assert {:ok, detail} = HubClient.get_model_detail("mlx-community/Phi-3")
    assert detail.config_summary.quantization_bits == nil
  end

  test "get_model_detail/1 normalizes missing optional detail fields safely", %{
    stub_name: stub_name
  } do
    payload = %{"id" => "mlx-community/minimal"}

    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 200, payload)
    end)

    assert {:ok, detail} = HubClient.get_model_detail("mlx-community/minimal")

    assert detail.metadata_summary == %{license: nil, languages: [], base_models: []}

    assert detail.config_summary == %{
             model_type: nil,
             architectures: [],
             context_window_tokens: nil,
             quantization_bits: nil
           }

    assert detail.siblings == []
    assert detail.used_storage_bytes == nil
  end

  test "search_models/2 maps 401 and 403 to hf_unauthorized", %{stub_name: stub_name} do
    Enum.each([401, 403], fn status ->
      Req.Test.stub(stub_name, fn conn ->
        json_response(conn, status, %{"error" => "nope"})
      end)

      assert {:error,
              %{
                status: :unauthorized,
                code: "hf_unauthorized",
                message: "Hugging Face access denied."
              }} =
               HubClient.search_models(nil, [])
    end)
  end

  test "get_model_detail/1 maps 404 to hf_not_found", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 404, %{"error" => "missing"})
    end)

    assert {:error,
            %{
              status: :not_found,
              code: "hf_not_found",
              message: "Hugging Face resource not found."
            }} =
             HubClient.get_model_detail("mlx-community/missing")
  end

  test "search_models/2 maps 429 to hf_rate_limited", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 429, %{"error" => "slow down"})
    end)

    assert {:error,
            %{
              status: :rate_limited,
              code: "hf_rate_limited",
              message: "Hugging Face rate limit exceeded."
            }} =
             HubClient.search_models(nil, [])
  end

  test "search_models/2 maps 5xx responses to hf_unavailable without leaking response bodies", %{
    stub_name: stub_name
  } do
    Req.Test.stub(stub_name, fn conn ->
      json_response(conn, 503, %{"error" => "backend exploded"})
    end)

    assert {:error,
            %{
              status: :unavailable,
              code: "hf_unavailable",
              message: "Hugging Face is unavailable."
            }} =
             HubClient.search_models(nil, [])
  end

  test "search_models/2 maps transport failures to hf_unavailable", %{stub_name: stub_name} do
    Req.Test.stub(stub_name, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error,
            %{
              status: :unavailable,
              code: "hf_unavailable",
              message: "Hugging Face is unavailable."
            }} =
             HubClient.search_models(nil, [])
  end

  defp with_hf_overrides(overrides, fun) when is_function(fun, 0) do
    previous_hf = Application.fetch_env!(:orchard_controller, :hf)
    Application.put_env(:orchard_controller, :hf, Keyword.merge(previous_hf, overrides))

    try do
      fun.()
    after
      Application.put_env(:orchard_controller, :hf, previous_hf)
    end
  end

  defp base_hf_config(stub_name) do
    [
      base_url: "https://huggingface.co",
      api_base_url: "https://huggingface.co/api",
      token: nil,
      retry_attempts: 1,
      connect_timeout_ms: 100,
      receive_timeout_ms: 100,
      req_options: [plug: {Req.Test, stub_name}]
    ]
  end

  defp dynamic_stub_name do
    String.to_atom("hub_client_test_#{System.unique_integer([:positive, :monotonic])}")
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
