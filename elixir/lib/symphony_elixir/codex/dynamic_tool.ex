defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Executes client-side tool calls requested by Codex app-server turns.
  """

  alias SymphonyElixir.{Config, Linear.Client, Plane}

  @linear_graphql_tool "linear_graphql"
  @linear_graphql_description """
  Execute a raw GraphQL query or mutation against Linear using Symphony's configured auth.
  """
  @linear_graphql_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["query"],
    "properties" => %{
      "query" => %{
        "type" => "string",
        "description" => "GraphQL query or mutation document to execute against Linear."
      },
      "variables" => %{
        "type" => ["object", "null"],
        "description" => "Optional GraphQL variables object.",
        "additionalProperties" => true
      }
    }
  }

  @plane_rest_tool "plane_rest"
  @plane_rest_description """
  Execute a REST request against Plane using Symphony's configured auth. Paths must start with /api/v1/.
  """
  @plane_rest_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => ["GET", "POST", "PATCH", "DELETE"],
        "description" => "HTTP method to use."
      },
      "path" => %{
        "type" => "string",
        "description" => "Plane API path beginning with /api/v1/."
      },
      "query" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "null"],
        "description" => "Optional JSON request body.",
        "additionalProperties" => true
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts \\ []) do
    case tool do
      @linear_graphql_tool ->
        execute_linear_graphql(arguments, opts)

      @plane_rest_tool ->
        execute_plane_rest(arguments, opts)

      other ->
        failure_response(%{
          "error" => %{
            "message" => "Unsupported dynamic tool: #{inspect(other)}.",
            "supportedTools" => supported_tool_names()
          }
        })
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    case Config.settings!().tracker.kind do
      "plane" ->
        [
          %{
            "name" => @plane_rest_tool,
            "description" => @plane_rest_description,
            "inputSchema" => @plane_rest_input_schema
          }
        ]

      _ ->
        [
          %{
            "name" => @linear_graphql_tool,
            "description" => @linear_graphql_description,
            "inputSchema" => @linear_graphql_input_schema
          }
        ]
    end
  end

  defp execute_linear_graphql(arguments, opts) do
    linear_client = Keyword.get(opts, :linear_client, &Client.graphql/3)

    with {:ok, query, variables} <- normalize_linear_graphql_arguments(arguments),
         {:ok, response} <- linear_client.(query, variables, []) do
      graphql_response(response)
    else
      {:error, reason} ->
        failure_response(tool_error_payload(reason))
    end
  end

  defp execute_plane_rest(arguments, opts) do
    plane_request = Keyword.get(opts, :plane_request, &Plane.Client.request/3)

    with {:ok, method, path, query, body} <- normalize_plane_rest_arguments(arguments),
         request_opts <- plane_request_opts(query, body),
         {:ok, response} <- plane_request.(method, path, request_opts) do
      success = response.status in 200..299
      dynamic_tool_response(success, encode_payload(%{"status" => response.status, "body" => response.body}))
    else
      {:error, reason} ->
        failure_response(plane_tool_error_payload(reason))
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_binary(arguments) do
    case String.trim(arguments) do
      "" -> {:error, :missing_query}
      query -> {:ok, query, %{}}
    end
  end

  defp normalize_linear_graphql_arguments(arguments) when is_map(arguments) do
    case normalize_query(arguments) do
      {:ok, query} ->
        case normalize_variables(arguments) do
          {:ok, variables} ->
            {:ok, query, variables}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_linear_graphql_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_plane_rest_arguments(arguments) when is_map(arguments) do
    method = arguments["method"] || arguments[:method]
    path = arguments["path"] || arguments[:path]
    query = arguments["query"] || arguments[:query] || %{}
    body = arguments["body"] || arguments[:body]
    normalized_method = method |> to_string() |> String.upcase()

    cond do
      normalized_method not in ["GET", "POST", "PATCH", "DELETE"] ->
        {:error, :invalid_plane_method}

      not is_binary(path) or not String.starts_with?(path, "/api/v1/") ->
        {:error, :invalid_plane_path}

      not is_map(query) ->
        {:error, :invalid_plane_query}

      not (is_nil(body) or is_map(body)) ->
        {:error, :invalid_plane_body}

      true ->
        {:ok, normalized_method |> String.downcase() |> String.to_atom(), path, query, body}
    end
  end

  defp normalize_plane_rest_arguments(_arguments), do: {:error, :invalid_plane_arguments}

  defp normalize_query(arguments) do
    case Map.get(arguments, "query") || Map.get(arguments, :query) do
      query when is_binary(query) ->
        case String.trim(query) do
          "" -> {:error, :missing_query}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, :missing_query}
    end
  end

  defp normalize_variables(arguments) do
    case Map.get(arguments, "variables") || Map.get(arguments, :variables) || %{} do
      variables when is_map(variables) -> {:ok, variables}
      _ -> {:error, :invalid_variables}
    end
  end

  defp plane_request_opts(query, nil), do: [params: query]
  defp plane_request_opts(query, body), do: [params: query, json: body]

  defp graphql_response(response) do
    success =
      case response do
        %{"errors" => errors} when is_list(errors) and errors != [] -> false
        %{errors: errors} when is_list(errors) and errors != [] -> false
        _ -> true
      end

    dynamic_tool_response(success, encode_payload(response))
  end

  defp failure_response(payload) do
    dynamic_tool_response(false, encode_payload(payload))
  end

  defp dynamic_tool_response(success, output) when is_boolean(success) and is_binary(output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [
        %{
          "type" => "inputText",
          "text" => output
        }
      ]
    }
  end

  defp encode_payload(payload) when is_map(payload) or is_list(payload) do
    Jason.encode!(payload, pretty: true)
  end

  defp encode_payload(payload), do: inspect(payload)

  defp plane_tool_error_payload(:invalid_plane_method),
    do: %{"error" => %{"message" => "`plane_rest.method` must be GET, POST, PATCH, or DELETE."}}

  defp plane_tool_error_payload(:invalid_plane_path),
    do: %{"error" => %{"message" => "`plane_rest.path` must start with /api/v1/."}}

  defp plane_tool_error_payload(:invalid_plane_query),
    do: %{"error" => %{"message" => "`plane_rest.query` must be an object when provided."}}

  defp plane_tool_error_payload(:invalid_plane_body),
    do: %{"error" => %{"message" => "`plane_rest.body` must be an object when provided."}}

  defp plane_tool_error_payload(:invalid_plane_arguments),
    do: %{
      "error" => %{
        "message" => "`plane_rest` expects an object with method, path, optional query, and optional body."
      }
    }

  defp plane_tool_error_payload(:missing_plane_api_token),
    do: %{
      "error" => %{
        "message" => "Symphony is missing Plane auth. Set `tracker.api_key` in `WORKFLOW.md` or export `PLANE_API_KEY`."
      }
    }

  defp plane_tool_error_payload(reason),
    do: %{"error" => %{"message" => "Plane REST tool execution failed.", "reason" => inspect(reason)}}

  defp tool_error_payload(:missing_query) do
    %{
      "error" => %{
        "message" => "`linear_graphql` requires a non-empty `query` string."
      }
    }
  end

  defp tool_error_payload(:invalid_arguments) do
    %{
      "error" => %{
        "message" => "`linear_graphql` expects either a GraphQL query string or an object with `query` and optional `variables`."
      }
    }
  end

  defp tool_error_payload(:invalid_variables) do
    %{
      "error" => %{
        "message" => "`linear_graphql.variables` must be a JSON object when provided."
      }
    }
  end

  defp tool_error_payload(:missing_linear_api_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing Linear auth. Set `linear.api_key` in `WORKFLOW.md` or export `LINEAR_API_KEY`."
      }
    }
  end

  defp tool_error_payload({:linear_api_status, status}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed with HTTP #{status}.",
        "status" => status
      }
    }
  end

  defp tool_error_payload({:linear_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Linear GraphQL request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{
      "error" => %{
        "message" => "Linear GraphQL tool execution failed.",
        "reason" => inspect(reason)
      }
    }
  end

  defp supported_tool_names do
    Enum.map(tool_specs(), & &1["name"])
  end
end
