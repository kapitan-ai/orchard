defmodule OrchardConsole.ModelHubLiveTest do
  use Orchard.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :live

  setup do
    previous = Application.get_env(:orchard_controller, :console, [])

    Application.put_env(
      :orchard_controller,
      :console,
      Keyword.merge(previous, model_hub_impl: __MODULE__.ModelHubStub)
    )

    :persistent_term.put({__MODULE__, :test_pid}, self())
    :persistent_term.erase({__MODULE__, :start_search_result})
    :persistent_term.erase({__MODULE__, :start_detail_result})

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      :persistent_term.erase({__MODULE__, :test_pid})
      :persistent_term.erase({__MODULE__, :start_search_result})
      :persistent_term.erase({__MODULE__, :start_detail_result})
    end)

    :ok
  end

  describe "GET /console/model-hub" do
    test "renders shell, title, nav, read-only copy, and debounced search input", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/model-hub")

      assert html =~ "Model Hub \u2014 Orchard Console"
      assert html =~ "console-sidebar"
      assert html =~ "model-hub-search-form"
      assert html =~ "model-hub-search-input"
      assert html =~ ~s(phx-debounce="300")
      assert html =~ "Read-only in B1. Download and import are deferred to B2/B3."
      assert has_element?(view, ~s(a[aria-current="page"][href="/console/model-hub"]))
    end

    test "connected mount loads initial browse results, auto-selects the first result, and loads detail", %{conn: conn} do
      {:ok, view, html} = live(conn, "/console/model-hub")
      assert html =~ "model-hub-results-loading"

      search_ref = assert_search_started(nil)
      results = search_results_fixture()

      send_search_success(view, search_ref, nil, results)

      detail_ref = assert_detail_started(hd(results).repo_id)
      assert render(view) =~ "model-hub-detail-loading"

      send_detail_success(view, detail_ref, detail_fixture(hd(results).repo_id))
      html = render(view)

      assert html =~ "model-hub-results-table"
      assert html =~ hd(results).repo_id
      assert html =~ Enum.at(results, 1).repo_id
      assert html =~ "model-hub-detail-content"
      assert html =~ "model-hub-detail-repo-id"
      assert html =~ "LlamaForCausalLM"
      assert html =~ "model-hub-detail-siblings"
      assert html =~ "tokenizer.json"
    end

    test "search change starts a new debounced search and clears prior detail state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      load_initial_results_and_detail(view)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "qwen"})
      |> render_change()

      _search_ref = assert_search_started("qwen")
      html = render(view)

      assert html =~ ~s(phx-debounce="300")
      assert html =~ "model-hub-results-loading"
      assert html =~ "model-hub-detail-idle"
      refute html =~ "model-hub-detail-content"
      refute html =~ "LlamaForCausalLM"
    end

    test "submitting the search form uses the LiveView search flow", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _initial_search_ref = assert_search_started(nil)

      html =
        view
        |> form("#model-hub-search-form", model_hub_search: %{query: "qwen"})
        |> render_submit()

      _search_ref = assert_search_started("qwen")

      assert html =~ "model-hub-results-loading"
      assert html =~ "model-hub-detail-idle"
    end

    test "clicking a result loads that model detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      second = Enum.at(results, 1)

      view
      |> element("#model-hub-select-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      detail_ref = assert_detail_started(second.repo_id)
      send_detail_success(view, detail_ref, detail_fixture(second.repo_id))
      html = render(view)

      assert html =~ second.repo_id
      assert html =~ "QwenForCausalLM"
      refute html =~ "LlamaForCausalLM"
    end

    test "clicking the selected result while detail is loading does not start another detail fetch", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      first = hd(results)

      first_repo_id = first.repo_id

      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      _detail_ref = assert_detail_started(first_repo_id)

      view
      |> element("#model-hub-select-#{dom_id_fragment(first_repo_id)}")
      |> render_click()

      refute_receive {:stub_detail_ref, _, ^first_repo_id}, 50
      assert render(view) =~ "model-hub-detail-loading"
    end

    test "search refresh preserves the selected repo when it is still present", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      second = Enum.at(results, 1)

      view
      |> element("#model-hub-select-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      second_detail_ref = assert_detail_started(second.repo_id)
      send_detail_success(view, second_detail_ref, detail_fixture(second.repo_id))

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "mlx"})
      |> render_change()

      search_ref = assert_search_started("mlx")
      send_search_success(view, search_ref, "mlx", results)

      refreshed_detail_ref = assert_detail_started(second.repo_id)
      send_detail_success(view, refreshed_detail_ref, detail_fixture(second.repo_id))

      html = render(view)
      assert html =~ second.repo_id
      assert html =~ "QwenForCausalLM"
      refute html =~ "LlamaForCausalLM"
    end

    test "empty search results show the shared empty state and clear detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      search_ref = assert_search_started(nil)

      send_search_success(view, search_ref, nil, [])
      html = render(view)

      assert html =~ "model-hub-results-empty"
      assert html =~ "No matching models found."
      assert html =~ "model-hub-detail-idle"
      refute_receive {:stub_detail_ref, _, _}, 50
    end

    test "search error shows the shared error state and clears detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      search_ref = assert_search_started(nil)

      send_search_error(view, search_ref, %{message: "Hugging Face rate limit exceeded."})
      html = render(view)

      assert html =~ "model-hub-results-error"
      assert html =~ "Hugging Face rate limit exceeded."
      assert html =~ "model-hub-detail-idle"
      refute_receive {:stub_detail_ref, _, _}, 50
    end

    test "detail error keeps results visible for the selected repo", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      search_ref = assert_search_started(nil)

      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(hd(results).repo_id)

      send_detail_error(view, detail_ref, %{message: "Hugging Face access denied."})
      html = render(view)

      assert html =~ "model-hub-results-table"
      assert html =~ hd(results).repo_id
      assert html =~ Enum.at(results, 1).repo_id
      assert html =~ "model-hub-detail-error"
      assert html =~ "Hugging Face access denied."
    end

    test "sparse detail payloads render with fallbacks instead of crashing", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      repo_id = hd(results).repo_id
      search_ref = assert_search_started(nil)

      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(repo_id)

      send_detail_success(view, detail_ref, %{"repo_id" => repo_id, "siblings" => nil})
      html = render(view)

      assert html =~ "model-hub-detail-content"
      assert html =~ repo_id
      assert html =~ "model-hub-detail-siblings-empty"
      assert html =~ "Open"
    end

    test "string-keyed search results are normalized before render", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      search_ref = assert_search_started(nil)

      send_search_success(view, search_ref, nil, [
        %{"downloads" => 1},
        %{
          "repo_id" => "mlx-community/Llama-3.2-1B-Instruct-4bit",
          "author" => "mlx-community",
          "downloads" => 12_345,
          "likes" => 678,
          "gated" => false,
          "last_modified" => "2026-03-19T12:34:56Z"
        }
      ])

      detail_ref = assert_detail_started("mlx-community/Llama-3.2-1B-Instruct-4bit")
      send_detail_success(view, detail_ref, %{"repo_id" => "mlx-community/Llama-3.2-1B-Instruct-4bit"})
      html = render(view)

      assert html =~ "model-hub-results-table"
      assert html =~ "mlx-community/Llama-3.2-1B-Instruct-4bit"
      refute html =~ "stale/model"
    end

    test "search start failures render the shared error state", %{conn: conn} do
      :persistent_term.put({__MODULE__, :start_search_result}, :error)

      {:ok, view, html} = live(conn, "/console/model-hub")

      assert html =~ "model-hub-results-error"
      assert html =~ "Hugging Face request failed."
      assert render(view) =~ "model-hub-detail-idle"
    end

    test "detail start failures render the shared error state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      second = Enum.at(results, 1)
      :persistent_term.put({__MODULE__, :start_detail_result}, :error)

      view
      |> element("#model-hub-select-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      html = render(view)
      assert html =~ "model-hub-detail-error"
      assert html =~ "Hugging Face request failed."
      assert html =~ second.repo_id
    end

    test "stale search results are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      initial_ref = assert_search_started(nil)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "qwen"})
      |> render_change()

      current_ref = assert_search_started("qwen")

      send_search_success(view, initial_ref, nil, [search_result_fixture("stale/model")])
      html = render(view)

      assert html =~ "model-hub-results-loading"
      refute html =~ "stale/model"
      refute_receive {:stub_detail_ref, _, "stale/model"}, 50

      current_results = [search_result_fixture("mlx-community/Qwen2.5-7B-Instruct-4bit")]
      send_search_success(view, current_ref, "qwen", current_results)

      detail_ref = assert_detail_started("mlx-community/Qwen2.5-7B-Instruct-4bit")
      send_detail_success(view, detail_ref, detail_fixture("mlx-community/Qwen2.5-7B-Instruct-4bit"))
      html = render(view)

      assert html =~ "mlx-community/Qwen2.5-7B-Instruct-4bit"
      refute html =~ "stale/model"
    end

    test "starting a new search terminates the superseded in-flight search task", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      initial_search_ref = assert_search_started(nil)
      initial_search_pid = assert_search_task_pid(initial_search_ref)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "qwen"})
      |> render_change()

      current_search_ref = assert_search_started("qwen")
      _current_search_pid = assert_search_task_pid(current_search_ref)

      assert_process_terminated(initial_search_pid)
    end

    test "starting a new search terminates the in-flight detail task", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      initial_search_ref = assert_search_started(nil)

      results = search_results_fixture()
      send_search_success(view, initial_search_ref, nil, results)
      initial_detail_ref = assert_detail_started(hd(results).repo_id)
      initial_detail_pid = assert_detail_task_pid(initial_detail_ref)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "qwen"})
      |> render_change()

      current_search_ref = assert_search_started("qwen")
      _current_search_pid = assert_search_task_pid(current_search_ref)

      assert_process_terminated(initial_detail_pid)
    end

    test "stale detail results are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      first = hd(results)
      second = Enum.at(results, 1)

      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      first_detail_ref = assert_detail_started(first.repo_id)

      view
      |> element("#model-hub-select-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      second_detail_ref = assert_detail_started(second.repo_id)

      send_detail_success(view, first_detail_ref, detail_fixture(first.repo_id))
      html = render(view)

      assert html =~ "model-hub-detail-loading"
      refute html =~ "LlamaForCausalLM"

      send_detail_success(view, second_detail_ref, detail_fixture(second.repo_id))
      html = render(view)

      assert html =~ second.repo_id
      assert html =~ "QwenForCausalLM"
      refute html =~ "LlamaForCausalLM"
    end

    test "selecting another result terminates the superseded detail task", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      first = hd(results)
      second = Enum.at(results, 1)

      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      first_detail_ref = assert_detail_started(first.repo_id)
      first_detail_pid = assert_detail_task_pid(first_detail_ref)

      view
      |> element("#model-hub-select-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      second_detail_ref = assert_detail_started(second.repo_id)
      _second_detail_pid = assert_detail_task_pid(second_detail_ref)

      assert_process_terminated(first_detail_pid)
    end
  end

  defmodule ModelHubStub do
    def start_search(_owner, ref, query) do
      case :persistent_term.get({OrchardConsole.ModelHubLiveTest, :start_search_result}, :ok) do
        :ok ->
          pid = spawn(fn -> Process.sleep(:infinity) end)

          if test_pid = :persistent_term.get({OrchardConsole.ModelHubLiveTest, :test_pid}, nil) do
            send(test_pid, {:stub_search_ref, ref, query})
            send(test_pid, {:stub_search_pid, ref, pid})
          end

          {:ok, pid}

        other ->
          other
      end
    end

    def start_detail(_owner, ref, repo_id) do
      case :persistent_term.get({OrchardConsole.ModelHubLiveTest, :start_detail_result}, :ok) do
        :ok ->
          pid = spawn(fn -> Process.sleep(:infinity) end)

          if test_pid = :persistent_term.get({OrchardConsole.ModelHubLiveTest, :test_pid}, nil) do
            send(test_pid, {:stub_detail_ref, ref, repo_id})
            send(test_pid, {:stub_detail_pid, ref, pid})
          end

          {:ok, pid}

        other ->
          other
      end
    end
  end

  defp load_initial_results_and_detail(view) do
    results = search_results_fixture()
    search_ref = assert_search_started(nil)

    send_search_success(view, search_ref, nil, results)

    detail_ref = assert_detail_started(hd(results).repo_id)
    send_detail_success(view, detail_ref, detail_fixture(hd(results).repo_id))
    _html = render(view)

    results
  end

  defp assert_search_started(query) do
    assert_receive {:stub_search_ref, ref, ^query}, 200
    ref
  end

  defp assert_search_task_pid(ref) do
    assert_receive {:stub_search_pid, ^ref, pid}, 200
    pid
  end

  defp assert_detail_started(repo_id) do
    assert_receive {:stub_detail_ref, ref, ^repo_id}, 200
    ref
  end

  defp assert_detail_task_pid(ref) do
    assert_receive {:stub_detail_pid, ^ref, pid}, 200
    pid
  end

  defp assert_process_terminated(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 200
  end

  defp send_search_success(view, ref, query, results) do
    send(view.pid, {:model_hub, ref, :search_finished, {:ok, %{query: query, results: results}}})
  end

  defp send_search_error(view, ref, overrides) do
    error = Map.merge(%{status: :error, code: "hf_error", message: "Hugging Face request failed."}, overrides)
    send(view.pid, {:model_hub, ref, :search_finished, {:error, error}})
  end

  defp send_detail_success(view, ref, detail) do
    send(view.pid, {:model_hub, ref, :detail_finished, {:ok, detail}})
  end

  defp send_detail_error(view, ref, overrides) do
    error = Map.merge(%{status: :error, code: "hf_error", message: "Hugging Face request failed."}, overrides)
    send(view.pid, {:model_hub, ref, :detail_finished, {:error, error}})
  end

  defp search_results_fixture do
    [
      search_result_fixture("mlx-community/Llama-3.2-1B-Instruct-4bit", %{
        downloads: 12_345,
        likes: 678,
        author: "mlx-community",
        gated: false,
        last_modified: "2026-03-19T12:34:56Z"
      }),
      search_result_fixture("mlx-community/Qwen2.5-7B-Instruct-4bit", %{
        downloads: 98_765,
        likes: 432,
        author: "mlx-community",
        gated: true,
        last_modified: "2026-03-18T11:22:33Z"
      })
    ]
  end

  defp search_result_fixture(repo_id, overrides \\ %{}) do
    Map.merge(
      %{
        repo_id: repo_id,
        author: nil,
        downloads: 0,
        likes: 0,
        tags: ["mlx", "text-generation"],
        pipeline_tag: "text-generation",
        library_name: "transformers",
        used_storage_bytes: 1_024,
        last_modified: nil,
        gated: false
      },
      overrides
    )
  end

  defp detail_fixture("mlx-community/Llama-3.2-1B-Instruct-4bit") do
    %{
      repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
      revision_sha: "rev-llama",
      author: "mlx-community",
      downloads: 12_345,
      likes: 678,
      tags: ["mlx", "llama", "text-generation"],
      pipeline_tag: "text-generation",
      library_name: "transformers",
      used_storage_bytes: 1_234_567,
      last_modified: "2026-03-19T12:34:56Z",
      gated: false,
      metadata_summary: %{
        license: "Apache-2.0",
        languages: ["en"],
        base_models: ["meta-llama/Llama-3.2-1B-Instruct"]
      },
      config_summary: %{
        model_type: "llama",
        architectures: ["LlamaForCausalLM"],
        context_window_tokens: 8192,
        quantization_bits: 4
      },
      siblings: [
        %{path: "config.json", size_bytes: 2_048},
        %{path: "tokenizer.json", size_bytes: 65_536}
      ]
    }
  end

  defp detail_fixture("mlx-community/Qwen2.5-7B-Instruct-4bit") do
    %{
      repo_id: "mlx-community/Qwen2.5-7B-Instruct-4bit",
      revision_sha: "rev-qwen",
      author: "mlx-community",
      downloads: 98_765,
      likes: 432,
      tags: ["mlx", "qwen", "text-generation"],
      pipeline_tag: "text-generation",
      library_name: "transformers",
      used_storage_bytes: 9_876_543,
      last_modified: "2026-03-18T11:22:33Z",
      gated: true,
      metadata_summary: %{
        license: "MIT",
        languages: ["en", "zh"],
        base_models: ["Qwen/Qwen2.5-7B-Instruct"]
      },
      config_summary: %{
        model_type: "qwen2",
        architectures: ["QwenForCausalLM"],
        context_window_tokens: 32_768,
        quantization_bits: 4
      },
      siblings: [
        %{path: "README.md", size_bytes: 4_096},
        %{path: "tokenizer.json", size_bytes: 65_536}
      ]
    }
  end

  defp detail_fixture(repo_id) do
    %{
      repo_id: repo_id,
      revision_sha: "rev-generic",
      author: "mlx-community",
      downloads: 1,
      likes: 1,
      tags: ["mlx"],
      pipeline_tag: "text-generation",
      library_name: "transformers",
      used_storage_bytes: 1_000,
      last_modified: "2026-03-19T00:00:00Z",
      gated: false,
      metadata_summary: %{license: "Apache-2.0", languages: ["en"], base_models: []},
      config_summary: %{
        model_type: "generic",
        architectures: ["GenericForCausalLM"],
        context_window_tokens: 4096,
        quantization_bits: 4
      },
      siblings: [%{path: "config.json", size_bytes: 2_048}]
    }
  end

  defp dom_id_fragment(value) do
    fragment =
      value
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> case do
        "" -> "item"
        normalized -> normalized
      end

    suffix =
      :sha256
      |> :crypto.hash(value)
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)

    "#{fragment}-#{suffix}"
  end
end
