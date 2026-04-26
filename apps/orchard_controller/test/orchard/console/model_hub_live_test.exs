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
    :persistent_term.erase({__MODULE__, :start_download_result})
    OrchardConsole.ModelHubDownloadCoordinator.reset()

    on_exit(fn ->
      Application.put_env(:orchard_controller, :console, previous)
      OrchardConsole.ModelHubDownloadCoordinator.reset()
      :persistent_term.erase({__MODULE__, :test_pid})
      :persistent_term.erase({__MODULE__, :start_search_result})
      :persistent_term.erase({__MODULE__, :start_detail_result})
      :persistent_term.erase({__MODULE__, :start_download_result})
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
      assert has_element?(view, ~s(a[aria-current="page"][href="/console/model-hub"]))
    end

    test "cards use max_height for desktop scroll containment", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/model-hub")

      assert html =~ ~s(id="model-hub-search-card")
      assert html =~ ~s(id="model-hub-detail-card")
      # Card-level max-height and flex/scroll classes
      assert html =~ "xl:max-h-[calc(100vh-12rem)]"
      assert html =~ "flex flex-col overflow-hidden"
      assert html =~ "overflow-y-auto"
    end

    test "file listing renders inside a collapsed disclosure with summary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(hd(results).repo_id)
      send_detail_success(view, detail_ref, detail_fixture(hd(results).repo_id))
      html = render(view)

      # Disclosure wrapper exists
      assert html =~ ~s(id="model-hub-files-disclosure")
      assert html =~ ~s(id="model-hub-files-summary")
      # Summary shows file count and total
      assert html =~ "2 files"
      # Table is still rendered inside
      assert html =~ "model-hub-detail-siblings"
      assert html =~ "tokenizer.json"
    end

    test "empty siblings render without disclosure wrapper", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      repo_id = hd(results).repo_id
      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(repo_id)
      send_detail_success(view, detail_ref, %{"repo_id" => repo_id, "siblings" => nil})
      html = render(view)

      assert html =~ "model-hub-detail-siblings-empty"
      refute html =~ "model-hub-files-disclosure"
    end

    test "small repo with 2+ shards still shows shard groups", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(hd(results).repo_id)

      # Only 4 files total, but 2 qualifying safetensors shards
      siblings = [
        %{path: "model-00001-of-00002.safetensors", size_bytes: 4_294_967_296},
        %{path: "model-00002-of-00002.safetensors", size_bytes: 4_294_967_296},
        %{path: "config.json", size_bytes: 2_048},
        %{path: "tokenizer.json", size_bytes: 65_536}
      ]

      detail =
        detail_fixture(hd(results).repo_id)
        |> Map.put(:siblings, siblings)

      send_detail_success(view, detail_ref, detail)
      html = render(view)

      # Summary shows total file count
      assert html =~ "4 files"
      # Shard group line appears even with <50 files
      assert html =~ "model-*.safetensors"
      assert html =~ "2 shards"
    end

    test "large repo disclosure summary includes safetensors shard groups", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(hd(results).repo_id)

      # Build a detail with 50+ siblings including safetensors shards
      shard_siblings =
        for i <- 1..48 do
          padded = String.pad_leading("#{i}", 5, "0")
          %{path: "model-#{padded}-of-00048.safetensors", size_bytes: 4_294_967_296}
        end

      other_siblings = [
        %{path: "config.json", size_bytes: 2_048},
        %{path: "tokenizer.json", size_bytes: 65_536},
        %{path: "model.safetensors.index.json", size_bytes: 4_096}
      ]

      detail =
        detail_fixture(hd(results).repo_id)
        |> Map.put(:siblings, other_siblings ++ shard_siblings)

      send_detail_success(view, detail_ref, detail)
      html = render(view)

      # Summary shows total file count
      assert html =~ "51 files"
      # Shard group line appears
      assert html =~ "model-*.safetensors"
      assert html =~ "48 shards"
    end

    test "detail :ok renders sticky inner header with repo and download action", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      detail_ref = assert_detail_started(hd(results).repo_id)
      send_detail_success(view, detail_ref, detail_fixture(hd(results).repo_id))
      html = render(view)

      # Sticky header wrapper exists with sticky classes
      assert html =~ ~s(id="model-hub-detail-sticky-header")
      assert html =~ "xl:sticky"
      assert html =~ "xl:top-"
      assert html =~ "xl:z-"
      # Contains repo id and download action
      assert html =~ "model-hub-detail-repo-id"
      assert html =~ "model-hub-download-action"
      # Scrolling body wrapper exists
      assert html =~ ~s(id="model-hub-detail-body")
    end

    test "detail :idle does not render sticky inner header", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/console/model-hub")

      refute html =~ "model-hub-detail-sticky-header"
    end

    test "result rows are keyboard-accessible with tabindex and Enter activation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")

      search_ref = assert_search_started(nil)
      results = search_results_fixture()
      send_search_success(view, search_ref, nil, results)

      # Wait for auto-select detail to complete
      detail_ref = assert_detail_started(hd(results).repo_id)
      send_detail_success(view, detail_ref, detail_fixture(hd(results).repo_id))

      html = render(view)

      # Result rows should be keyboard-focusable
      assert html =~ ~s(tabindex="0")
      assert html =~ ~s(phx-key="Enter")
      # Row click should still work
      assert html =~ "phx-click"
      assert html =~ "phx-keydown"
    end

    test "connected mount loads initial browse results, auto-selects the first result, and loads detail",
         %{conn: conn} do
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

    test "search change starts a new debounced search and clears prior detail state", %{
      conn: conn
    } do
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
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      detail_ref = assert_detail_started(second.repo_id)
      send_detail_success(view, detail_ref, detail_fixture(second.repo_id))
      html = render(view)

      assert html =~ second.repo_id
      assert html =~ "QwenForCausalLM"
      refute html =~ "LlamaForCausalLM"
    end

    test "clicking the selected result while detail is loading does not start another detail fetch",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      first = hd(results)

      first_repo_id = first.repo_id

      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      _detail_ref = assert_detail_started(first_repo_id)

      view
      |> element("#model-hub-result-#{dom_id_fragment(first_repo_id)}")
      |> render_click()

      refute_receive {:stub_detail_ref, _, ^first_repo_id}, 50
      assert render(view) =~ "model-hub-detail-loading"
    end

    test "search refresh preserves the selected repo when it is still present", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      second = Enum.at(results, 1)

      view
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
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

    test "search results that normalize to empty show the shared empty state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      search_ref = assert_search_started(nil)

      send_search_success(view, search_ref, nil, [%{"downloads" => 1}, %{"repo_id" => ""}])
      html = render(view)

      assert html =~ "model-hub-results-empty"
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

      send_detail_success(view, detail_ref, %{
        "repo_id" => "mlx-community/Llama-3.2-1B-Instruct-4bit"
      })

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
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
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

      send_detail_success(
        view,
        detail_ref,
        detail_fixture("mlx-community/Qwen2.5-7B-Instruct-4bit")
      )

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
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
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
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      second_detail_ref = assert_detail_started(second.repo_id)
      _second_detail_pid = assert_detail_task_pid(second_detail_ref)

      assert_process_terminated(first_detail_pid)
    end

    test "search results Updated column renders LocalTime hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = search_results_fixture()
      search_ref = assert_search_started(nil)
      send_search_success(view, search_ref, nil, results)
      html = render(view)

      # The Updated column should use <.local_time> with hook attrs
      assert html =~ ~s(data-local-time-format="datetime_minute")
      assert html =~ ~s(datetime="2026-03-19T12:34:56Z")
    end

    test "detail Last updated field renders LocalTime hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)
      html = render(view)

      # The detail metadata "Last updated" field should use <.local_time>
      assert html =~ "model-hub-detail-updated"
      assert html =~ ~s(phx-hook="LocalTime")
      assert html =~ ~s(data-local-time-format="datetime_minute")
    end

    test "repo-ID query: seam-injected direct result renders and auto-loads detail", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _initial_ref = assert_search_started(nil)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "meta-llama/Llama-3.1-8B"})
      |> render_change()

      search_ref = assert_search_started("meta-llama/Llama-3.1-8B")

      # Simulate the seam returning a merged result (just the direct-lookup row).
      injected_result =
        search_result_fixture("meta-llama/Llama-3.1-8B", %{
          library_name: "transformers",
          downloads: 77_777
        })

      send_search_success(view, search_ref, "meta-llama/Llama-3.1-8B", [injected_result])

      detail_ref = assert_detail_started("meta-llama/Llama-3.1-8B")
      send_detail_success(view, detail_ref, detail_fixture("meta-llama/Llama-3.1-8B"))

      html = render(view)
      assert html =~ "meta-llama/Llama-3.1-8B"
      assert html =~ "model-hub-detail-content"
      assert html =~ "model-hub-results-table"
    end

    test "seam-deduped result list renders exactly one row for the repo", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _initial_ref = assert_search_started(nil)

      view
      |> form("#model-hub-search-form",
        model_hub_search: %{query: "mlx-community/Llama-3.2-1B-Instruct-4bit"}
      )
      |> render_change()

      search_ref = assert_search_started("mlx-community/Llama-3.2-1B-Instruct-4bit")

      # Seam returns a single already-deduped result (as the production seam would).
      deduped = search_result_fixture("mlx-community/Llama-3.2-1B-Instruct-4bit")
      send_search_success(view, search_ref, "mlx-community/Llama-3.2-1B-Instruct-4bit", [deduped])

      _detail_ref = assert_detail_started("mlx-community/Llama-3.2-1B-Instruct-4bit")

      html = render(view)
      frag = dom_id_fragment("mlx-community/Llama-3.2-1B-Instruct-4bit")
      # The row element ID should appear exactly once in the rendered output.
      assert html =~ "model-hub-result-#{frag}"
      assert Enum.count(String.split(html, "model-hub-result-#{frag}")) == 2
    end

    test "starting a new search cancels superseded search task for repo-ID-shaped queries", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _initial_ref = assert_search_started(nil)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "owner/model-name"})
      |> render_change()

      repo_search_ref = assert_search_started("owner/model-name")
      repo_search_pid = assert_search_task_pid(repo_search_ref)

      view
      |> form("#model-hub-search-form", model_hub_search: %{query: "something else"})
      |> render_change()

      _new_ref = assert_search_started("something else")

      assert_process_terminated(repo_search_pid)
    end
  end

  describe "download flow" do
    test "download button renders for open models and is absent for idle detail", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      html = render(view)

      # Detail loaded for first (open) model — button present
      assert has_element?(view, "#model-hub-download-button")
      refute html =~ "model-hub-download-gated-note"
      refute html =~ "model-hub-download-progress"
      refute html =~ "model-hub-download-complete"
      refute html =~ "model-hub-download-error"

      # Second model is gated
      second = Enum.at(results, 1)

      view
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      detail_ref = assert_detail_started(second.repo_id)
      send_detail_success(view, detail_ref, detail_fixture(second.repo_id))
      html = render(view)

      # Gated model — button disabled, warning visible
      assert has_element?(view, "#model-hub-download-button[disabled]")
      assert html =~ "model-hub-download-gated-note"
      assert html =~ "gated on Hugging Face"
    end

    test "clicking download starts the seam and shows starting state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      first = hd(results)

      view
      |> element("#model-hub-download-button")
      |> render_click()

      # Verify stub received the right call
      assert_receive {:stub_download_ref, _ref, repo_id, opts}, 200
      assert repo_id == first.repo_id
      assert opts[:activate] == true

      html = render(view)
      assert html =~ "model-hub-download-progress"
      assert html =~ "Starting"
      # Button should be disabled while busy
      assert has_element?(view, "#model-hub-download-button[disabled]")
      # Progress bar starts in indeterminate mode with accessible label
      assert has_element?(view, "#model-hub-download-progress-bar[data-mode=indeterminate]")

      assert has_element?(
               view,
               ~s(#model-hub-download-progress-bar[aria-label="Model download progress"])
             )

      assert has_element?(view, "#model-hub-download-progress-percent")
      assert view |> element("#model-hub-download-progress-percent") |> render() =~ "Estimating"
    end

    test ":download_started moves to downloading and renders totals", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123def",
        total_files: 15,
        total_bytes: 4_294_967_296
      })

      html = render(view)
      assert html =~ "Downloading"
      assert html =~ "0 of 15 files"
      assert html =~ "4.0\u00a0GB"
      assert html =~ "mlx-community/Llama-3.2-1B-Instruct-4bit"
      # Bar switches to determinate at 0% with accessible label
      assert has_element?(view, "#model-hub-download-progress-bar[data-mode=determinate]")
      assert has_element?(view, "#model-hub-download-progress-bar[aria-valuenow='0']")

      assert has_element?(
               view,
               ~s(#model-hub-download-progress-bar[aria-label="Model download progress"])
             )

      assert view |> element("#model-hub-download-progress-percent") |> render() =~ "0%"
    end

    test ":download_progress maps seam phases correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 10,
        total_bytes: 1_073_741_824
      })

      # Downloading phase with file progress
      send_download_progress(download_ref, %{
        phase: :downloading,
        current_file: "model-00001-of-00002.safetensors",
        files_completed: 3,
        total_files: 10,
        bytes_downloaded: 536_870_912,
        total_bytes: 1_073_741_824
      })

      html = render(view)
      assert html =~ "Downloading"
      assert html =~ "3 of 10 files"
      assert html =~ "512.0\u00a0MB"
      assert html =~ "model-00001-of-00002.safetensors"
      # Bar at 50%
      assert has_element?(view, "#model-hub-download-progress-bar[aria-valuenow='50']")
      assert view |> element("#model-hub-download-progress-percent") |> render() =~ "50%"

      # Preparing bundle phase
      send_download_progress(download_ref, %{
        phase: :preparing_bundle,
        files_completed: 10,
        total_files: 10,
        bytes_downloaded: 1_073_741_824,
        total_bytes: 1_073_741_824
      })

      html = render(view)
      assert html =~ "Preparing bundle"
      assert html =~ "10 of 10 files"

      # Importing phase
      send_download_progress(download_ref, %{
        phase: :importing,
        files_completed: 10,
        total_files: 10,
        bytes_downloaded: 1_073_741_824,
        total_bytes: 1_073_741_824
      })

      html = render(view)
      assert html =~ "Importing"
    end

    test "download progress shows mid-file byte progress before any file completes", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 4,
        total_bytes: 8_589_934_592
      })

      # Streaming mid-file update: 2 GB in, zero files completed yet
      send_download_progress(download_ref, %{
        phase: :downloading,
        current_file: "model-00001-of-00004.safetensors",
        files_completed: 0,
        total_files: 4,
        bytes_downloaded: 2_147_483_648,
        total_bytes: 8_589_934_592
      })

      html = render(view)
      # Phase label
      assert html =~ "Downloading"
      # File count not yet incremented
      assert html =~ "0 of 4 files"
      # Bytes downloaded shown (2 GB)
      assert html =~ "2.0\u00a0GB"
      # Currently-downloading file shown
      assert html =~ "model-00001-of-00004.safetensors"
      # Progress bar at 25% (2 of 8 GB)
      assert has_element?(view, "#model-hub-download-progress-bar[aria-valuenow='25']")
      assert view |> element("#model-hub-download-progress-percent") |> render() =~ "25%"
    end

    test ":download_finished {:ok, ...} shows completion with CTA", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_success(download_ref, %{
        model_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        version: "abc123def456",
        state: :active
      })

      html = render(view)
      assert html =~ "model-hub-download-complete"
      assert html =~ "Model is now active."
      assert html =~ "mlx-community/Llama-3.2-1B-Instruct-4bit"
      assert html =~ "abc123def456"
      assert has_element?(view, "#model-hub-download-models-link")

      assert has_element?(
               view,
               ~s|#model-hub-download-playground-link[href="/console/playground"]|
             )

      # Button should be re-enabled
      refute has_element?(view, "#model-hub-download-button[disabled]")
      # Progress should be gone
      refute html =~ "model-hub-download-progress"
    end

    test ":download_finished {:ok, ...} omits Playground CTA when model is not active", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_success(download_ref, %{
        model_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        version: "abc123def456",
        state: :registered
      })

      html = render(view)
      assert html =~ "model-hub-download-complete"
      assert html =~ "Model imported successfully."
      assert has_element?(view, "#model-hub-download-models-link")
      refute has_element?(view, "#model-hub-download-playground-link")
    end

    test ":download_finished {:error, ...} shows error with retry", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_error(download_ref, %{message: "Download timed out."})

      html = render(view)
      assert html =~ "model-hub-download-error"
      assert html =~ "Download timed out."
      assert has_element?(view, "#model-hub-download-retry")
      # Button should be re-enabled
      refute has_element?(view, "#model-hub-download-button[disabled]")
    end

    test "duplicate model error shows friendly message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_error(download_ref, %{
        code: "model_already_imported",
        message: "Model mlx-community/Llama-3.2-1B-Instruct-4bit@abc123 is already imported."
      })

      html = render(view)
      assert html =~ "model-hub-download-error"
      assert html =~ "already imported"
    end

    test "start failure renders fallback error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)
      :persistent_term.put({__MODULE__, :start_download_result}, :error)

      view |> element("#model-hub-download-button") |> render_click()

      html = render(view)
      assert html =~ "model-hub-download-error"
      assert html =~ "Model download and import failed."
      refute html =~ "model-hub-download-progress"
    end

    test "retry restarts failed repo download", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      first = hd(results)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: first.repo_id,
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_error(download_ref, %{message: "Connection reset."})

      # Click retry
      view |> element("#model-hub-download-retry") |> render_click()

      # Verify new download started for the same repo
      assert_receive {:stub_download_ref, _new_ref, repo_id, opts}, 200
      assert repo_id == first.repo_id
      assert opts[:activate] == true

      html = render(view)
      assert html =~ "model-hub-download-progress"
      assert html =~ "Starting"
    end

    test "stale download refs are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      first_download_ref = assert_download_started()

      send_download_started(first_download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 10,
        total_bytes: 1024
      })

      # Simulate error → retry (creates new ref)
      send_download_error(first_download_ref, %{message: "Failed."})
      view |> element("#model-hub-download-retry") |> render_click()
      _new_download_ref = assert_download_started()

      # Send stale messages with the OLD ref — should be ignored
      send_download_started(first_download_ref, %{
        repo_id: "stale/model",
        revision: "stale",
        total_files: 999,
        total_bytes: 999
      })

      html = render(view)
      refute html =~ "stale/model"
      refute html =~ "999"
      assert html =~ "Starting"

      send_download_progress(first_download_ref, %{
        phase: :downloading,
        files_completed: 888,
        total_files: 999,
        bytes_downloaded: 888,
        total_bytes: 999
      })

      html = render(view)
      refute html =~ "888"

      send_download_success(first_download_ref, %{
        model_id: "stale/model",
        version: "stale",
        state: :active
      })

      html = render(view)
      refute html =~ "model-hub-download-complete"
      assert html =~ "model-hub-download-progress"
    end

    test "download button disabled for gated model click attempt", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      second = Enum.at(results, 1)

      # Select gated model
      view
      |> element("#model-hub-result-#{dom_id_fragment(second.repo_id)}")
      |> render_click()

      detail_ref = assert_detail_started(second.repo_id)
      send_detail_success(view, detail_ref, detail_fixture(second.repo_id))

      # Try to click download — should be disabled, no stub call
      assert has_element?(view, "#model-hub-download-button[disabled]")
      refute_receive {:stub_download_ref, _, _, _}, 50
    end

    # ------------------------------------------------------------------
    # Navigation / remount tests
    # ------------------------------------------------------------------

    test "active download progress survives remount", %{conn: conn} do
      # Start download and advance to downloading state
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 10,
        total_bytes: 4_294_967_296
      })

      send_download_progress(download_ref, %{
        phase: :downloading,
        current_file: "model-00001-of-00002.safetensors",
        files_completed: 3,
        total_files: 10,
        bytes_downloaded: 1_073_741_824,
        total_bytes: 4_294_967_296
      })

      # Unmount the view (simulates navigation away)
      stop_view(view)

      # Remount — fresh LiveView should rehydrate from coordinator
      {:ok, _remounted_view, html} = live(conn, "/console/model-hub")

      # Progress panel visible immediately from rehydration
      assert html =~ "model-hub-download-progress"
      assert html =~ "Downloading"
      assert html =~ "mlx-community/Llama-3.2-1B-Instruct-4bit"
      assert html =~ "3 of 10 files"
    end

    test "duplicate download prevented after remount", %{conn: conn} do
      # Start download and keep it active
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 10,
        total_bytes: 1024
      })

      # Unmount and remount
      stop_view(view)
      {:ok, remounted_view, _html} = live(conn, "/console/model-hub")

      # Reload results/detail so download button is in the DOM
      _results = load_initial_results_and_detail(remounted_view)
      html = render(remounted_view)

      # Download button is disabled because coordinator has an active job
      assert has_element?(remounted_view, "#model-hub-download-button[disabled]")

      # No second seam call occurred during remount or detail load
      refute_receive {:stub_download_ref, _, _, _}, 100

      # View still shows the active download state from coordinator rehydration
      assert html =~ "model-hub-download-progress"
    end

    test "terminal success survives remount", %{conn: conn} do
      # Complete a download successfully
      {:ok, view, _html} = live(conn, "/console/model-hub")
      _results = load_initial_results_and_detail(view)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_success(download_ref, %{
        model_id: "mlx-community/Llama-3.2-1B-Instruct-4bit",
        version: "abc123def456",
        state: :active
      })

      # Unmount and remount
      stop_view(view)
      {:ok, remounted_view, html} = live(conn, "/console/model-hub")

      # Success panel visible immediately from rehydration
      assert html =~ "model-hub-download-complete"
      assert html =~ "Model is now active."
      assert html =~ "mlx-community/Llama-3.2-1B-Instruct-4bit"
      assert html =~ "abc123def456"
      assert has_element?(remounted_view, "#model-hub-download-playground-link")
      refute html =~ "model-hub-download-progress"
    end

    test "terminal error survives remount and retry starts fresh download", %{conn: conn} do
      # Complete a download with error
      {:ok, view, _html} = live(conn, "/console/model-hub")
      results = load_initial_results_and_detail(view)
      first = hd(results)

      view |> element("#model-hub-download-button") |> render_click()
      download_ref = assert_download_started()

      send_download_started(download_ref, %{
        repo_id: first.repo_id,
        revision: "abc123",
        total_files: 2,
        total_bytes: 1024
      })

      send_download_error(download_ref, %{message: "Connection reset."})

      # Unmount and remount
      stop_view(view)
      {:ok, remounted_view, html} = live(conn, "/console/model-hub")

      # Error panel visible immediately from rehydration
      assert html =~ "model-hub-download-error"
      assert html =~ "Connection reset."
      assert html =~ "model-hub-download-retry"

      # Click retry on remounted view — should start a new download
      remounted_view |> element("#model-hub-download-retry") |> render_click()

      assert_receive {:stub_download_ref, _new_ref, repo_id, opts}, 200
      assert repo_id == first.repo_id
      assert opts[:activate] == true

      html = render(remounted_view)
      assert html =~ "model-hub-download-progress"
      assert html =~ "Starting"
      refute html =~ "model-hub-download-error"
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

    def start_download_import(_owner, ref, repo_id, opts) do
      case :persistent_term.get(
             {OrchardConsole.ModelHubLiveTest, :start_download_result},
             :ok
           ) do
        :ok ->
          pid = spawn(fn -> Process.sleep(:infinity) end)

          if test_pid =
               :persistent_term.get({OrchardConsole.ModelHubLiveTest, :test_pid}, nil) do
            send(test_pid, {:stub_download_ref, ref, repo_id, opts})
            send(test_pid, {:stub_download_pid, ref, pid})
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
    error =
      Map.merge(
        %{status: :error, code: "hf_error", message: "Hugging Face request failed."},
        overrides
      )

    send(view.pid, {:model_hub, ref, :search_finished, {:error, error}})
  end

  defp send_detail_success(view, ref, detail) do
    send(view.pid, {:model_hub, ref, :detail_finished, {:ok, detail}})
  end

  defp send_detail_error(view, ref, overrides) do
    error =
      Map.merge(
        %{status: :error, code: "hf_error", message: "Hugging Face request failed."},
        overrides
      )

    send(view.pid, {:model_hub, ref, :detail_finished, {:error, error}})
  end

  # Download test helpers

  defp assert_download_started do
    assert_receive {:stub_download_ref, ref, _repo_id, _opts}, 200
    ref
  end

  # Download helpers send to coordinator (the download owner), not view.pid.
  # flush_coordinator/0 ensures the coordinator has processed the message
  # and broadcast the snapshot before the test calls render(view).

  defp send_download_started(ref, attrs) do
    payload =
      Map.merge(
        %{repo_id: "test/model", revision: "abc123", total_files: 2, total_bytes: 1024},
        attrs
      )

    send(coordinator_pid!(), {:model_hub, ref, :download_started, payload})
    flush_coordinator()
  end

  defp send_download_progress(ref, attrs) do
    payload =
      Map.merge(
        %{
          phase: :downloading,
          current_file: nil,
          files_completed: 0,
          total_files: 2,
          bytes_downloaded: 0,
          total_bytes: 1024
        },
        attrs
      )

    send(coordinator_pid!(), {:model_hub, ref, :download_progress, payload})
    flush_coordinator()
  end

  defp send_download_success(ref, result) do
    send(coordinator_pid!(), {:model_hub, ref, :download_finished, {:ok, result}})
    flush_coordinator()
  end

  defp send_download_error(ref, overrides) do
    error =
      Map.merge(
        %{status: :error, code: "download_import_failed", message: "Download failed."},
        overrides
      )

    send(coordinator_pid!(), {:model_hub, ref, :download_finished, {:error, error}})
    flush_coordinator()
  end

  defp stop_view(view) do
    Process.unlink(view.pid)
    GenServer.stop(view.pid)
  end

  defp coordinator_pid! do
    Process.whereis(OrchardConsole.ModelHubDownloadCoordinator) ||
      raise "ModelHubDownloadCoordinator not running"
  end

  defp flush_coordinator do
    # Synchronous GenServer.call ensures the coordinator has processed all
    # prior messages (including our send) and broadcast any PubSub updates
    # before the test proceeds to render(view).
    OrchardConsole.ModelHubDownloadCoordinator.latest_snapshot()
    :ok
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
