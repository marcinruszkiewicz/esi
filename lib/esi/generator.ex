defmodule ESI.Generator do
  @moduledoc false

  alias ESI.Generator.{Endpoint, Function, SwaggerType}

  def run(swagger) do
    info = swagger
    functions_by_module = Map.get(info, "paths", [])
    |> Enum.flat_map(fn {path, requests} ->
      requests
      |> Enum.map(fn {verb, info} ->
        Function.new(path, String.to_atom(verb), info)
      end)
    end)
    |> Enum.group_by(&(&1.module_name))
    functions_by_module |> Enum.each(fn {module_name, functions} ->
      content = write_module(module_name, functions)
      name = Macro.underscore(module_name)
      path = Path.join([File.cwd!, "lib/esi/api", "#{name}.ex"])
      File.write!(path, content, [:write])
      Mix.shell.info(path)
    end)

    content = write_api_module(info, functions_by_module)
    path = Path.join([File.cwd!, "lib/esi/api.ex"])
    File.write!(path, content, [:write])
    Mix.shell.info(path)
  end

  defp write_api_module(info, functions_by_module) do
    version = get_in(info, ~w(info version))
    result_types =
      for {module_name, functions} <- functions_by_module, function <- functions do
        "ESI.API." <> module_name <> "." <> function.name <> "_result"
      end
    result_type = result_types |> Enum.join("\n                | ")
    [
      "defmodule ESI.API do",
      "",
      "  @version #{inspect(version)}",
      "",
      "  def version, do: @version",
      "",
      "  @type result :: #{result_type}",
      "",
      "end"
    ] |> flow
  end

  defp write_module(name, functions) do
    [
      "defmodule ESI.API.#{name} do",
      Enum.map(functions, &write_function/1),
      ["\n", "end"]
    ]
  end

  def write_doc(function) do
    doc = function.doc |> String.split("\n") |> Enum.take(1)
    result_type = function.name <> "_result"
    if doc do
      tag = function.tags |> hd
      [
        ~S(  @doc """),
        ["  ", doc, "."],
        "",
        "  ## Request Result",
        "",
        "  See `ESI.request/2` and `ESI.request!/2`, which can return a [`#{result_type}`](#t:#{result_type}/0) type.",
        "",
        "  ## Swagger Source",
        "",
        "  This function was generated from the following Swagger operation:",
        "",
        "  - `operationId` -- `#{function.operation}`",
        "  - `path` -- `#{function.endpoint.source}`",
        "",
        "  [View on ESI Site](https://esi.tech.ccp.is/latest/#!/#{tag}/#{function.operation})",
        "",
        ~S(  """)
      ] |> flow
    end
  end

  def write_opts_typedoc(function) do
    [
      ~S(  @typedoc """),
      Enum.map(opts_params(function), fn param ->
        "  - `:#{param["name"]}` #{param_req_tag(param)}-- #{param["description"]}"
      end) |> flow,
      ~S(  """)
    ] |> flow
  end

  def write_function(function) do
    write_opts_type_info(function) ++ write_result_type_info(function) ++ [
      "\n",
      write_doc(function),
      "  @spec #{function.name}(#{write_spec_args(function)}) :: ESI.Request.t",
      "  def #{function.name}(#{write_args(function)}) do",
      write_request(function),
      "  end"
    ] |> flow
  end

  def write_opts_type_info(function) do
    case opts_params(function) do
      [] ->
        [""]
      _ ->
        [
          "\n",
          write_opts_typedoc(function),
          write_opts_type(function),
        ]
    end
  end

  defp write_request(function) do
    spaces = "    "
    [
      [spaces, "%ESI.Request{"],
      [spaces, "  ", ~s(verb: :#{function.verb},)],
      [spaces, "  ", ~s(path: #{Endpoint.to_ex(function.endpoint)},)],
      Enum.map(split_opts(function), &[spaces, "  ", &1, ","]) |> flow,
      [spaces, "}"]
    ] |> flow
  end

  @ignore_params_in ~w(path header)
  @ignore_params_named ~w(token user_agent datasource)
  defp opts_params(function) do
    Map.values(function.params)
    |> Enum.filter(fn v ->
      !Enum.member?(@ignore_params_in, v["in"]) && !Enum.member?(@ignore_params_named, v["name"])
    end)
  end

  defp split_opts(function) do
    opts_params(function)
    |> Enum.group_by(fn v -> v["in"] end)
    |> Enum.map(fn {section, params} ->
      contents = Enum.map(params, fn %{"name" => name} -> ":#{name}" end)
      |> Enum.join(", ")
      "#{section}_opts: Keyword.take(opts, [#{contents}])"
    end)
  end

  def write_result_type_info(function) do
    value = case Function.response_schema(function) do
      nil ->
        "any"
      other ->
        SwaggerType.new(other)
        |> Map.put(:force_required, true)
    end
    ["\n  @type #{function.name}_result :: #{value}"]
  end

  defp write_opts_type(function) do
    [
      "  @type #{function.name}_opts :: [",
      Enum.map(opts_params(function), fn param ->
        swagger_type = SwaggerType.new(param)
        ~s<    #{param["name"]}: #{swagger_type},>
      end) |> flow,
      "  ]"
    ] |> flow
  end

  defp write_spec_args(function) do
    function.endpoint
    |> Endpoint.args()
    |> do_write_spec_args(function)
  end
  defp do_write_spec_args([], function) do
    case opts_params(function) do
      [] ->
        nil
      _ ->
        "opts :: #{function.name}_opts"
    end
  end
  defp do_write_spec_args(args, function) do
    list = args
    |> Enum.map(&Macro.underscore/1)
    |> Enum.map(fn param ->
      swagger_type = SwaggerType.new(function.params[param])
      ~s(#{param} :: #{swagger_type})
    end)
    |> Enum.join(", ")
    opts_args = do_write_spec_args([], function)
    [
      list,
      opts_args
    ]
    |> Enum.filter(&(!is_nil(&1)))
    |> Enum.join(", ")
  end

  defp write_args(function) do
    function.endpoint
    |> Endpoint.args
    |> do_write_args(function)
  end
  defp do_write_args([], function) do
    case opts_params(function) do
      [] ->
        nil
      _ ->
        "opts \\\\ []"
    end
  end
  defp do_write_args(args, function) do
    list = args
    |> Enum.map(&Macro.underscore/1)
    |> Enum.join(", ")
    opts_args = do_write_args([], function)
    [
      list,
      opts_args
    ]
    |> Enum.filter(&(!is_nil(&1)))
    |> Enum.join(", ")
  end

  defp flow(block) do
    Enum.intersperse(List.wrap(block), "\n")
  end

  defp param_req_tag(%{"default" => value, "enum" => _}) do
    ~s<(DEFAULT: `#{inspect(String.to_atom(value))}`) >
  end
  defp param_req_tag(%{"default" => value}) do
    ~s<(DEFAULT: `#{inspect(value)}`) >
  end
  defp param_req_tag(%{"required" => true}) do
    "(REQUIRED) "
  end
  defp param_req_tag(_) do
    ""
  end


end