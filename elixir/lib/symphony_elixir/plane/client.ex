defmodule SymphonyElixir.Plane.Client do
  @moduledoc """
  Thin Plane REST client for polling candidate work items.
  """

  require Logger

  alias SymphonyElixir.{Config, Linear.Issue}

  @page_size 50
  @max_error_body_log_bytes 1_000
  @priority_order %{"urgent" => 1, "high" => 2, "medium" => 3, "low" => 4, "none" => nil}

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    tracker = Config.settings!().tracker

    with :ok <- validate_tracker(tracker),
         {:ok, state_ids} <- resolve_state_ids(tracker.active_states) do
      fetch_work_items_by_state_ids(state_ids, tracker.assignee)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    tracker = Config.settings!().tracker
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      with :ok <- validate_tracker(tracker),
           {:ok, state_ids} <- resolve_state_ids(normalized_states) do
        fetch_work_items_by_state_ids(state_ids, nil)
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    issue_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn issue_id, {:ok, acc} ->
      case get_work_item(issue_id) do
        {:ok, %Issue{} = issue} -> {:cont, {:ok, [issue | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, Enum.reverse(issues)}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    path = project_path("/work-items/#{URI.encode_www_form(issue_id)}/comments/")

    payload = %{
      "comment_html" => markdownish_to_html(body),
      "comment_json" => %{},
      "access" => "INTERNAL",
      "external_source" => "symphony"
    }

    case request(:post, path, json: payload) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status} = response} -> plane_status_error(:comment_create_failed, status, response)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name) when is_binary(issue_id) and is_binary(state_name) do
    with {:ok, state_id} <- resolve_state_id(state_name),
         {:ok, %{status: status} = response} <- request(:patch, work_item_path(issue_id), json: %{"state" => state_id}) do
      if status in 200..299 do
        :ok
      else
        plane_status_error(:issue_update_failed, status, response)
      end
    end
  end

  @spec request(atom(), String.t(), keyword()) :: {:ok, Req.Response.t()} | {:error, term()}
  def request(method, path, opts \\ []) when is_atom(method) and is_binary(path) and is_list(opts) do
    with {:ok, headers} <- api_headers() do
      url = build_url(Config.settings!().tracker.endpoint, path)
      request_opts = Keyword.merge([headers: headers, connect_options: [timeout: 30_000]], opts)

      case Req.request(Keyword.merge(request_opts, method: method, url: url)) do
        {:ok, %{status: status} = response} when status in 200..299 ->
          {:ok, response}

        {:ok, response} ->
          Logger.error("Plane REST request failed status=#{response.status} path=#{path} body=#{summarize_error_body(response.body)}")
          {:ok, response}

        {:error, reason} ->
          Logger.error("Plane REST request failed path=#{path}: #{inspect(reason)}")
          {:error, {:plane_api_request, reason}}
      end
    end
  end

  @doc false
  @spec normalize_work_item_for_test(map()) :: Issue.t() | nil
  def normalize_work_item_for_test(work_item) when is_map(work_item), do: normalize_work_item(work_item, nil)

  @doc false
  @spec page_items_for_test(term()) :: [map()]
  def page_items_for_test(payload), do: page_items(payload)

  defp fetch_work_items_by_state_ids(state_ids, assignee) when is_list(state_ids) do
    state_ids
    |> Enum.reduce_while({:ok, []}, fn state_id, {:ok, acc} ->
      case fetch_work_items_page(state_id, assignee, 0, []) do
        {:ok, issues} -> {:cont, {:ok, issues ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, issues} -> {:ok, issues |> Enum.reverse() |> Enum.uniq_by(& &1.id)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp fetch_work_items_page(state_id, assignee, offset, acc) do
    query = [state: state_id, limit: @page_size, offset: offset, expand: "labels,assignees,state,project"]
    query = if is_binary(assignee), do: Keyword.put(query, :assignee, assignee), else: query

    case request(:get, project_path("/work-items/"), params: query) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        items = page_items(body)
        issues = items |> Enum.map(&normalize_work_item(&1, assignee)) |> Enum.reject(&is_nil/1)

        if length(items) == @page_size do
          fetch_work_items_page(state_id, assignee, offset + @page_size, issues ++ acc)
        else
          {:ok, issues ++ acc}
        end

      {:ok, %{status: status} = response} ->
        plane_status_error(:work_items_fetch_failed, status, response)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_work_item(issue_id) do
    case request(:get, work_item_path(issue_id), params: [expand: "labels,assignees,state,project"]) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, normalize_work_item(body, nil)}
      {:ok, %{status: status} = response} -> plane_status_error(:work_item_fetch_failed, status, response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_state_ids(state_names) do
    with {:ok, states} <- list_states() do
      state_ids =
        state_names
        |> Enum.map(&resolve_state_id_from_states(states, &1))
        |> Enum.reject(&is_nil/1)

      if length(state_ids) == length(Enum.uniq(state_names)) do
        {:ok, Enum.uniq(state_ids)}
      else
        {:error, {:plane_state_not_found, state_names}}
      end
    end
  end

  defp resolve_state_id(state_name) do
    with {:ok, states} <- list_states(),
         state_id when is_binary(state_id) <- resolve_state_id_from_states(states, state_name) do
      {:ok, state_id}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :state_not_found}
    end
  end

  defp list_states do
    case request(:get, project_path("/states/"), params: [limit: 200]) do
      {:ok, %{status: status, body: body}} when status in 200..299 -> {:ok, page_items(body)}
      {:ok, %{status: status} = response} -> plane_status_error(:states_fetch_failed, status, response)
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_state_id_from_states(states, state_name) when is_list(states) do
    normalized = normalize_name(state_name)

    states
    |> Enum.find(fn state -> normalize_name(state["name"]) == normalized or state["id"] == state_name end)
    |> case do
      %{"id" => id} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp normalize_work_item(work_item, assignee_filter) when is_map(work_item) do
    project = expanded_map(work_item["project"])
    state = expanded_map(work_item["state"])

    %Issue{
      id: work_item["id"],
      identifier: identifier(work_item, project),
      title: work_item["name"],
      description: work_item["description_stripped"] || work_item["description_html"],
      priority: priority(work_item["priority"]),
      state: state["name"] || work_item["state"],
      branch_name: nil,
      url: work_item["url"] || web_url(work_item, project),
      assignee_id: first_assignee_id(work_item["assignees"]),
      blocked_by: [],
      labels: labels(work_item["labels"]),
      assigned_to_worker: assigned_to_worker?(work_item["assignees"], assignee_filter),
      created_at: parse_datetime(work_item["created_at"]),
      updated_at: parse_datetime(work_item["updated_at"])
    }
  end

  defp normalize_work_item(_work_item, _assignee_filter), do: nil

  defp identifier(%{"identifier" => identifier}, _project) when is_binary(identifier), do: identifier

  defp identifier(%{"sequence_id" => sequence_id}, project) do
    key = project["identifier"] || project["key"] || Config.settings!().tracker.project_key

    if is_binary(key) and not is_nil(sequence_id) do
      "#{key}-#{sequence_id}"
    else
      to_string(sequence_id)
    end
  end

  defp identifier(%{"id" => id}, _project), do: id
  defp identifier(_work_item, _project), do: nil

  defp web_url(%{"sequence_id" => sequence_id}, project) do
    tracker = Config.settings!().tracker
    project_identifier = project["identifier"] || project["key"] || tracker.project_key

    if is_binary(tracker.workspace_slug) and is_binary(project_identifier) and not is_nil(sequence_id) do
      "https://app.plane.so/#{tracker.workspace_slug}/projects/#{project_identifier}/issues/#{sequence_id}"
    end
  end

  defp web_url(_work_item, _project), do: nil

  defp page_items(%{"results" => results}) when is_list(results), do: results
  defp page_items(%{"data" => data}) when is_list(data), do: data
  defp page_items(items) when is_list(items), do: items
  defp page_items(_payload), do: []

  defp expanded_map(value) when is_map(value), do: value
  defp expanded_map(_value), do: %{}

  defp labels(labels) when is_list(labels) do
    labels
    |> Enum.map(fn
      %{"name" => name} -> name
      label when is_binary(label) -> label
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp labels(_labels), do: []

  defp first_assignee_id([%{"id" => id} | _]) when is_binary(id), do: id
  defp first_assignee_id([id | _]) when is_binary(id), do: id
  defp first_assignee_id(_assignees), do: nil

  defp assigned_to_worker?(_assignees, nil), do: true

  defp assigned_to_worker?(assignees, assignee_id) when is_list(assignees) do
    Enum.any?(assignees, fn
      %{"id" => id} -> id == assignee_id
      id when is_binary(id) -> id == assignee_id
      _ -> false
    end)
  end

  defp assigned_to_worker?(_assignees, _assignee_id), do: false

  defp priority(priority) when is_binary(priority), do: Map.get(@priority_order, String.downcase(priority))
  defp priority(_priority), do: nil

  defp project_path(suffix) do
    tracker = Config.settings!().tracker
    "/api/v1/workspaces/#{URI.encode_www_form(tracker.workspace_slug)}/projects/#{URI.encode_www_form(tracker.project_id)}#{suffix}"
  end

  defp work_item_path(issue_id), do: project_path("/work-items/#{URI.encode_www_form(issue_id)}/")

  defp build_url(endpoint, path) do
    endpoint
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp api_headers do
    case Config.settings!().tracker.api_key do
      nil -> {:error, :missing_plane_api_token}
      token -> {:ok, [{"x-api-key", token}, {"Content-Type", "application/json"}]}
    end
  end

  defp validate_tracker(tracker) do
    cond do
      is_nil(tracker.api_key) -> {:error, :missing_plane_api_token}
      is_nil(tracker.workspace_slug) -> {:error, :missing_plane_workspace_slug}
      is_nil(tracker.project_id) -> {:error, :missing_plane_project_id}
      true -> :ok
    end
  end

  defp markdownish_to_html(body) do
    escaped = Phoenix.HTML.html_escape(body) |> Phoenix.HTML.safe_to_string()
    "<p>" <> String.replace(escaped, "\n", "<br>") <> "</p>"
  end

  defp normalize_name(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
  defp normalize_name(value), do: value |> to_string() |> normalize_name()

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp plane_status_error(error, status, response) do
    {:error, {error, {:plane_api_status, status, summarize_error_body(response.body)}}}
  end

  defp summarize_error_body(body) when is_binary(body) do
    body
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate_error_body()
    |> inspect()
  end

  defp summarize_error_body(body) do
    body
    |> inspect(limit: 20, printable_limit: @max_error_body_log_bytes)
    |> truncate_error_body()
  end

  defp truncate_error_body(body) when is_binary(body) do
    if byte_size(body) > @max_error_body_log_bytes do
      binary_part(body, 0, @max_error_body_log_bytes) <> "...<truncated>"
    else
      body
    end
  end
end
